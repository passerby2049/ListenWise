/*
Abstract:
ViewModel for TranscriptView — consolidates state and business logic.
*/

import Foundation
import SwiftUI
import AVFoundation
import AVKit
import WebKit

// MARK: - Enums (shared between ViewModel and View)

enum SubtitleMode: String, CaseIterable { case source, target, both }
enum TranscriptTab: String, CaseIterable { case original = "Original", bilingual = "Bilingual" }
enum InspectorTab: String, CaseIterable { case vocab = "Vocabulary", chat = "Chat" }

// MARK: - ViewModel

@MainActor @Observable
class TranscriptViewModel {

    // MARK: - Core

    var story: Story

    // MARK: - Playback

    var player: AVPlayer?
    var youtubeWebView: WKWebView?
    var isPlaying = false
    var currentPlaybackTime = 0.0
    var currentLineIndex: Int?
    var videoHeight: CGFloat = 350
    var isDraggingVideo = false
    var dragStartY: CGFloat = 0
    var dragStartHeight: CGFloat = 0
    var currentSubtitleText = ""
    var currentSubtitleTranslation = ""
    var duration = 0.0
    var cachedSubtitleCards: [SubtitleCard] = []
    var timeObserver: Any?
    var securityScopedURL: URL?

    // MARK: - Reorganization

    var reorganizedCards: [ReorganizedCard] = []
    var isReorganizing = false
    var reorganizeProgress = ""
    var showReorganized = false {
        didSet { invalidateDisplayLines() }
    }

    // MARK: - Translation

    var translatedText = ""
    var translationPairs: [TranslationPair] = []
    var isTranslatingLines = false

    // MARK: - Subtitle Display

    var showSubtitle = true
    var subtitleMode: SubtitleMode = .source
    var transcriptTab: TranscriptTab = .original

    // MARK: - Learning

    var markedWords: Set<String> = []
    /// Source sentence from which each marked word/phrase was selected.
    /// Keyed by the same lowercased key WordFlowView uses for markedWords.
    /// Transient — used only to anchor LLM context to the click site.
    var markedWordOrigins: [String: String] = [:]
    /// Words whose explanations came from global vocab (not queried in this story).
    var globalOnlyWords: Set<String> = []
    var wordLearningResponse = ""
    var wordExplanations: [WordExplanation] = []
    var sentenceExplanations: [SentenceExplanation] = []
    var queriedWords: Set<String> = []
    var isLoadingWordHelp = false

    // MARK: - Chat

    var chatMessages: [ChatMessage] = []
    var chatInput = ""
    var vocabScrollTarget: String?
    var isChatting = false

    // MARK: - UI

    var showingInspector = true
    var inspectorTab: InspectorTab = .vocab
    var liveTranslateEnabled = true

    // MARK: - Tasks

    var wordHelpTask: Task<Void, Never>?
    var reorganizeTask: Task<Void, Never>?
    var translateTask: Task<Void, Never>?
    var chatTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var selectedModel: String {
        UserDefaults.standard.string(forKey: "defaultModel") ?? "google/gemini-2.5-flash"
    }

    var sourceIsVideo: Bool {
        if !story.youtubeURL.isEmpty { return true }
        guard let url = story.url else { return false }
        return Set(["mp4", "mov", "m4v", "avi", "mkv"]).contains(url.pathExtension.lowercased())
    }

    var youtubeVideoID: String? {
        YouTubeHelper.extractVideoID(story.youtubeURL)
    }

    var isLiveMode: Bool {
        story.isLiveStream
    }

    var activeSubtitleCards: [SubtitleCard] {
        if showReorganized && !reorganizedCards.isEmpty {
            return reorganizedCards.map { SubtitleCard(text: $0.text, start: $0.start, end: $0.end) }
        }
        return cachedSubtitleCards
    }

    private var _displayLinesVersion = 0

    var displayLines: [String] {
        // Access the version counter so @Observable tracks this dependency
        _ = _displayLinesVersion
        let cards = activeSubtitleCards
        if !cards.isEmpty { return cards.map { $0.text } }
        return splitIntoSentences(String(story.text.characters))
    }

    func invalidateDisplayLines() {
        _displayLinesVersion += 1
    }

    var transcriptContext: String {
        let text = displayLines.joined(separator: "\n")
        return text.count > 3000 ? String(text.prefix(3000)) + "..." : text
    }

    var timeString: String {
        let fmt: (Double) -> String = { t in
            let m = Int(t) / 60; let s = Int(t) % 60
            return String(format: "%d:%02d", m, s)
        }
        return "\(fmt(currentPlaybackTime)) / \(fmt(duration))"
    }

    init(story: Story) {
        self.story = story
    }

    /// Cancel all running tasks and release player resources.
    func cleanup() {
        wordHelpTask?.cancel()
        reorganizeTask?.cancel()
        translateTask?.cancel()
        chatTask?.cancel()
        player?.pause()
        if let token = timeObserver {
            player?.removeTimeObserver(token)
            timeObserver = nil
        }
        player = nil
        youtubeWebView?.evaluateJavaScript("document.querySelector('video')?.pause()")
        youtubeWebView = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Subtitle Card Loading (consolidated)

    func loadSubtitleCards() {
        if !story.savedSubtitleCards.isEmpty {
            cachedSubtitleCards = story.savedSubtitleCards
        } else {
            let fromText = SubtitleExporter.subtitleCards(from: story.text)
            if !fromText.isEmpty {
                cachedSubtitleCards = fromText
                story.savedSubtitleCards = fromText
            }
        }
    }

    // MARK: - Task Launchers (cancel-before-reassign)

    func startReorganize() {
        reorganizeTask?.cancel()
        reorganizeTask = Task { await reorganizeTranscript() }
    }

    func startWordHelp() {
        wordHelpTask?.cancel()
        wordHelpTask = Task { await queryWordHelp() }
    }

    func startTranslate() {
        translateTask?.cancel()
        translateTask = Task { await translateByLines() }
    }

    func startChat() {
        chatTask?.cancel()
        chatTask = Task { await sendChatMessage() }
    }

    // MARK: - Restore / Transcription Complete

    func restoreSavedState() {
        if !story.savedReorganizedCards.isEmpty {
            reorganizedCards = story.savedReorganizedCards
            showReorganized = true
            invalidateDisplayLines()
        }
        // Restore per-story words, then merge global vocab words that appear in this transcript
        markedWords = story.savedMarkedWords
        wordLearningResponse = story.savedWordLearningResponse
        // Normalize stale empty-array JSON from older saves
        if wordLearningResponse.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" {
            wordLearningResponse = ""
        }
        if !wordLearningResponse.isEmpty { parseWordExplanations() }
        if !story.savedSentenceLearningResponse.isEmpty { parseSentenceExplanations(story.savedSentenceLearningResponse) }

        // Auto-mark global vocab words found in this transcript
        let globalMatches = GlobalVocabulary.shared.matchingWords(in: displayLines)
        let newFromGlobal = globalMatches.subtracting(markedWords)
        if !newFromGlobal.isEmpty {
            markedWords.formUnion(newFromGlobal)
            let global = GlobalVocabulary.shared
            for word in newFromGlobal {
                if let exp = global.wordExplanations[word] {
                    if !wordExplanations.contains(where: { $0.word.lowercased() == word }) {
                        wordExplanations.append(exp)
                        globalOnlyWords.insert(word)
                        queriedWords.insert(word)
                    }
                } else if let exp = global.sentenceExplanations[word] {
                    if !sentenceExplanations.contains(where: { $0.sentence.lowercased() == word }) {
                        sentenceExplanations.append(exp)
                        globalOnlyWords.insert(word)
                        queriedWords.insert(word)
                    }
                }
            }
        }
        // Drop any cards whose word is no longer marked — old builds of
        // `removeMarkedWord` left `wordExplanations` in place, so stories
        // saved before the fix can still carry orphaned cards.
        let markedLower = Set(markedWords.map { $0.lowercased() })
        let beforeWords = wordExplanations.count
        wordExplanations.removeAll { !markedLower.contains($0.word.lowercased()) }
        let beforeSentences = sentenceExplanations.count
        sentenceExplanations.removeAll { !markedLower.contains($0.sentence.lowercased()) }
        if wordExplanations.count != beforeWords { rebuildWordLearningResponse() }
        if sentenceExplanations.count != beforeSentences { rebuildSentenceLearningResponse() }

        translatedText = story.savedTranslation
        if !translatedText.isEmpty {
            if let data = translatedText.data(using: .utf8),
               let pairs = try? JSONDecoder().decode([TranslationPair].self, from: data) {
                translationPairs = pairs
            }
        }
        chatMessages = story.savedChatMessages
    }

    func handleTranscriptionComplete() {
        let originalCards = SubtitleExporter.subtitleCards(from: story.text)
        if !originalCards.isEmpty {
            cachedSubtitleCards = originalCards
            story.savedSubtitleCards = originalCards
            invalidateDisplayLines()
        }
        StoryStore.shared.save(story)
    }

    // MARK: - Player Setup

    func setupPlayer() {
        guard story.isDone, let url = story.url, player == nil else { return }
        if securityScopedURL == nil {
            let accessing = url.startAccessingSecurityScopedResource()
            if accessing { securityScopedURL = url }
        }
        loadSubtitleCards()
        if !story.youtubeURL.isEmpty {
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    duration = CMTimeGetSeconds(d)
                }
            }
            return
        }
        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        player = p
        finishPlayerSetup(player: p, localURL: url)
    }

    func finishPlayerSetup(player p: AVPlayer, localURL url: URL) {
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration) {
                duration = CMTimeGetSeconds(d)
            }
        }
        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        let isVideo = sourceIsVideo
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // queue: .main guarantees this runs on the main thread, so we can
            // safely re-enter the MainActor-isolated context without a hop.
            guard let self else { return }
            MainActor.assumeIsolated {
                let t = time.seconds
                if !isVideo { self.currentPlaybackTime = t }
                let cards = self.activeSubtitleCards
                let newIndex = cards.firstIndex { $0.start <= t && t < $0.end }
                if newIndex != self.currentLineIndex {
                    self.currentLineIndex = newIndex
                    if let idx = newIndex, self.inspectorTab == .vocab, !self.markedWords.isEmpty {
                        let lineText = cards[idx].text.lowercased()
                        if let firstMatch = self.markedWords.sorted().first(where: { lineText.contains($0) }) {
                            self.vocabScrollTarget = firstMatch
                        }
                    }
                }
                if isVideo {
                    self.currentSubtitleText = newIndex.map { cards[$0].text } ?? ""
                    if self.showReorganized && !self.reorganizedCards.isEmpty, let idx = newIndex, idx < self.reorganizedCards.count {
                        self.currentSubtitleTranslation = self.reorganizedCards[idx].translation
                    } else {
                        self.currentSubtitleTranslation = ""
                    }
                }
            }
        }
    }

    func updateSubtitleFromYouTube(time t: Double) {
        let cards = activeSubtitleCards
        let newIndex = cards.firstIndex { $0.start <= t && t < $0.end }
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            if let idx = newIndex, inspectorTab == .vocab, !markedWords.isEmpty {
                let lineText = cards[idx].text.lowercased()
                if let firstMatch = markedWords.sorted().first(where: { lineText.contains($0) }) {
                    vocabScrollTarget = firstMatch
                }
            }
        }
        currentSubtitleText = newIndex.map { cards[$0].text } ?? ""
        if showReorganized && !reorganizedCards.isEmpty, let idx = newIndex, idx < reorganizedCards.count {
            currentSubtitleTranslation = reorganizedCards[idx].translation
        } else {
            currentSubtitleTranslation = ""
        }
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        if youtubeWebView != nil {
            youtubeWebView?.evaluateJavaScript("var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}")
            isPlaying.toggle()
            return
        }
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
    }

    func seek(to time: Double) {
        if let webView = youtubeWebView {
            webView.evaluateJavaScript("var v=document.querySelector('video');if(v){v.currentTime=\(time);v.play()}")
        } else {
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func seekToLine(_ index: Int) {
        let cards = activeSubtitleCards
        guard index < cards.count else { return }
        seek(to: cards[index].start)
        if youtubeWebView != nil {
            isPlaying = true
        } else if !isPlaying {
            togglePlayback()
        }
    }

    // MARK: - Live

    func configureLiveStream(url: String, videoID: String) {
        story.youtubeURL = url
        story.isLiveStream = true
        story.title = "Live Stream"
        story.isDone = true
        StoryStore.shared.save(story)
        Task {
            if let title = await YouTubeHelper.fetchTitle(videoID: videoID) {
                story.title = title
                StoryStore.shared.save(story)
            }
        }
    }

    func saveLiveSegments(liveTranscriber: LiveTranscriber) {
        guard !liveTranscriber.segments.isEmpty else { return }
        story.savedLiveSegments = liveTranscriber.segments
        story.text = AttributedString(liveTranscriber.confirmedText)
        story.savedTranslation = liveTranscriber.segments
            .filter { !$0.translation.isEmpty }
            .map { "\($0.source)\n\($0.translation)" }
            .joined(separator: "\n\n")
        StoryStore.shared.save(story)
    }

    // MARK: - Helpers

    func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        for char in text {
            current.append(char)
            if sentenceEnders.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { sentences.append(remaining) }
        return sentences
    }

    func exportStory() {
        guard let url = try? StoryStore.shared.exportToMarkdown(story) else { return }
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    func refreshWord(_ word: String) {
        // Remove from queried so queryWordHelp will re-query it
        queriedWords.remove(word)
        globalOnlyWords.remove(word)
        wordExplanations.removeAll { $0.word.lowercased() == word }
        sentenceExplanations.removeAll { $0.sentence.lowercased() == word }
        startWordHelp()
    }

    func removeMarkedWord(_ word: String) {
        markedWords.remove(word)
        queriedWords.remove(word)
        globalOnlyWords.remove(word)
        wordExplanations.removeAll { $0.word.lowercased() == word }
        sentenceExplanations.removeAll { $0.sentence.lowercased() == word }
        rebuildWordLearningResponse()
        rebuildSentenceLearningResponse()
        GlobalVocabulary.shared.remove(word)
    }

    func clearAllMarkedWords() {
        for word in markedWords {
            GlobalVocabulary.shared.remove(word)
        }
        markedWords.removeAll()
        queriedWords.removeAll()
        globalOnlyWords.removeAll()
        wordExplanations.removeAll()
        sentenceExplanations.removeAll()
        rebuildWordLearningResponse()
        rebuildSentenceLearningResponse()
    }

    func saveLearnProgress() {
        story.savedMarkedWords = markedWords
        GlobalVocabulary.shared.addAll(markedWords)
        story.savedWordLearningResponse = wordLearningResponse
        rebuildSentenceLearningResponse()
        if !translationPairs.isEmpty, let data = try? JSONEncoder().encode(translationPairs),
           let str = String(data: data, encoding: .utf8) {
            story.savedTranslation = str
        } else {
            story.savedTranslation = translatedText
        }
        story.savedChatMessages = chatMessages
        StoryStore.shared.save(story)
    }

    // MARK: - Translation

    func translateByLines() async {
        let sourceText = displayLines.joined(separator: "\n")
        guard !sourceText.isEmpty, !selectedModel.isEmpty else { return }
        isTranslatingLines = true
        translationPairs = []
        let srcLang = story.sourceLanguage
        let tgtLang = story.targetLanguage
        let prompt = """
        Below is a \(srcLang) transcript. Please:
        1. First reorganize it into complete, natural sentences (fix any fragmentation from speech-to-text)
        2. Then translate each sentence into \(tgtLang)

        Return a JSON array ONLY (no markdown, no ```json```, no explanation). Each element:
        {"source": "the complete \(srcLang) sentence", "target": "the \(tgtLang) translation"}

        Transcript:
        \(sourceText)
        """
        var rawResponse = ""
        do {
            for try await token in AIProvider.stream(prompt: prompt, model: selectedModel) {
                rawResponse += token
            }
            if let parsed: [TranslationPair] = parseLLMJSON(rawResponse) {
                translationPairs = parsed
                translatedText = parsed.map { "\($0.source)\n\($0.target)" }.joined(separator: "\n\n")
            } else {
                translatedText = rawResponse
            }
        } catch {
            translatedText = "Translation failed: \(error.localizedDescription)"
        }
        isTranslatingLines = false
        saveLearnProgress()
    }

    // MARK: - Reorganize Transcript

    func reorganizeTranscript() async {
        guard !selectedModel.isEmpty else { return }
        var cards = cachedSubtitleCards
        if cards.isEmpty { cards = story.savedSubtitleCards }
        guard !cards.isEmpty else { return }
        reorganizedCards = []
        reorganizeProgress = ""
        isReorganizing = true
        let srcLang = story.sourceLanguage
        let tgtLang = story.targetLanguage
        let batchInterval: Double = 600
        var allResults: [ReorganizedCard] = []
        var cursor = 0
        var batchIndex = 0
        while cursor < cards.count {
            guard !Task.isCancelled else { break }
            batchIndex += 1
            let batchStartTime = cards[cursor].start
            var batchEnd = cursor
            while batchEnd < cards.count && cards[batchEnd].start < batchStartTime + batchInterval { batchEnd += 1 }
            batchEnd = max(batchEnd, cursor + 1)
            batchEnd = min(batchEnd, cards.count)
            let batchCards = Array(cards[cursor..<batchEnd])
            let remainingDuration = (cards.last?.end ?? cards[cursor].start) - cards[cursor].start
            let totalBatchesEstimate = max(batchIndex, Int(ceil(remainingDuration / batchInterval)) + batchIndex - 1)
            reorganizeProgress = "Processing batch \(batchIndex)/~\(totalBatchesEstimate)..."
            let numberedCards = batchCards.enumerated().map { i, card in "[\(i)] \(card.text)" }.joined(separator: "\n")
            let prompt = """
            Task: Merge these numbered \(srcLang) speech fragments into proper sentences. Fix typos. One sentence per entry. Keep it short.

            Rules:
            - Output JSON array ONLY. No explanation, no markdown.
            - Format: [{"cards": [0,1], "text": "Merged sentence.", "target": "\(tgtLang) translation."}]
            - Each entry must be exactly ONE complete sentence. Split at every sentence-ending punctuation (. ? ! 。？！ etc.).
            - Every index must appear exactly once, in order. Indices are 0-based for this batch only.
            - Do NOT summarize. Keep the original meaning word-for-word.
            - Fix proper nouns and names that were misrecognized by speech-to-text. Use context to infer the correct spelling (e.g. "Bideen" → "Biden", "Ukrane" → "Ukraine").
            - "target" is the \(tgtLang) translation of the "text" field.
            - IMPORTANT: If the last few cards don't form a complete sentence, do NOT include them. Only output complete sentences. Leave trailing incomplete fragments out.

            Example:
            Input:
            [0] Sandra,
            [1] I can tell you that I phoned President Trump to ask him,
            [2] once these reports started coming out,
            [3] that the Attorney General had been told that her time,
            [4] it was nearing the end of her time at the Justice Department,
            [5] and the president said,
            [6] he was preparing some remarks,
            [7] we think that it is going to be the official announcement about the Attorney General,
            [8] Bondi,
            [9] leaving the Justice Department.
            Output:
            [{"cards":[0,1,2],"text":"Sandra, I can tell you that I phoned President Trump to ask him, once these reports started coming out,","target":"Sandra，我可以告诉你，当这些报道开始出来后，我打电话给特朗普总统询问，"},{"cards":[3,4],"text":"that the Attorney General had been told it was nearing the end of her time at the Justice Department.","target":"司法部长已被告知她在司法部的任期即将结束。"},{"cards":[5,6],"text":"And the president said he was preparing some remarks.","target":"总统说他正在准备一些讲话。"},{"cards":[7,8,9],"text":"We think that it is going to be the official announcement about Attorney General Bondi leaving the Justice Department.","target":"我们认为这将是关于司法部长Bondi离开司法部的正式公告。"}]
            Input:
            \(numberedCards)
            """
            var rawResponse = ""
            do {
                for try await token in AIProvider.stream(prompt: prompt, model: selectedModel) {
                    try Task.checkCancellation()
                    rawResponse += token
                    reorganizeProgress = "Batch \(batchIndex): " + String(rawResponse.suffix(150))
                }
                if let sentences: [ReorganizedSentence] = parseLLMJSON(rawResponse), !sentences.isEmpty {
                    let isLastBatch = batchEnd >= cards.count
                    let trusted = isLastBatch ? sentences : Array(sentences.dropLast())
                    var maxUsedIndex = -1
                    for sentence in trusted {
                        guard !sentence.cards.isEmpty else { continue }
                        let validIndices = sentence.cards.filter { $0 >= 0 && $0 < batchCards.count }
                        guard !validIndices.isEmpty else { continue }
                        let globalFirst = cursor + validIndices.first!
                        let globalLast = cursor + validIndices.last!
                        guard globalFirst < cards.count && globalLast < cards.count else { continue }
                        let start = cards[globalFirst].start
                        let end = cards[globalLast].end
                        allResults.append(ReorganizedCard(text: sentence.text, translation: sentence.target ?? "", start: start, end: end))
                        maxUsedIndex = max(maxUsedIndex, validIndices.last!)
                    }
                    if maxUsedIndex >= 0 { cursor += maxUsedIndex + 1 } else { cursor = batchEnd }
                    reorganizedCards = allResults
                    showReorganized = true
                } else {
                    cursor = batchEnd
                }
            } catch is CancellationError { break }
            catch {
                reorganizeProgress = "Batch \(batchIndex) failed: \(error.localizedDescription)"
                break
            }
        }
        if !allResults.isEmpty {
            reorganizedCards = allResults
            showReorganized = true
            invalidateDisplayLines()
            story.savedReorganizedCards = reorganizedCards
            StoryStore.shared.save(story)
        }
        isReorganizing = false
    }

    // MARK: - Word Learning

    func queryWordHelp() async {
        let newItems = markedWords.subtracting(queriedWords)
        guard !newItems.isEmpty, !selectedModel.isEmpty else { return }
        isLoadingWordHelp = true
        wordLearningResponse = ""
        let srcLang = story.sourceLanguage
        let tgtLang = story.targetLanguage
        let lines = displayLines
        func fallbackSentence(for item: String) -> String? {
            lines.first(where: { $0.lowercased().contains(item) })
        }
        let sortedItems = newItems.sorted()
        let itemBlocks = sortedItems.map { item -> String in
            let origin = markedWordOrigins[item] ?? fallbackSentence(for: item) ?? ""
            return "- item: \"\(item)\"\n  source_sentence: \"\(origin)\""
        }.joined(separator: "\n")
        let prompt = """
        I'm learning \(srcLang). Below are items I selected from a transcript. Each item may be a single word, a short phrase, or a full sentence/clause. You decide which type each one is.

        IMPORTANT: Each item must appear in exactly ONE category. Do NOT break an item into sub-words. For example, if the item is "he is not bluffing", put it in "sentences" only — do NOT also add "bluffing" to "words". Return exactly ONE entry per item.

        Each item below is paired with the EXACT source sentence it was selected from. When you return `sentence_source`, you MUST use that paired sentence verbatim — do NOT substitute a different sentence, even if the item appears elsewhere in the transcript.

        Items:
        \(itemBlocks)

        Return a JSON object ONLY (no markdown, no ```json```, no explanation). The object has two arrays:
        {
          "words": [ ... ],
          "sentences": [ ... ]
        }

        For single words or short phrases (1-2 words), put them in "words" with this format:
        {
          "word": "the word/phrase",
          "phonetic": "IPA pronunciation (e.g. /ˈdɪŋɡi/)",
          "pos": "part of speech (e.g. n./v./adj.)",
          "definition_source": "\(srcLang) definition",
          "definition_target": "\(tgtLang) definition",
          "context_usage": "explain how it is used in the context above (in \(tgtLang))",
          "sentence_source": "the full original \(srcLang) sentence containing this word from the context",
          "sentence_target": "translate that sentence into \(tgtLang)",
          "example_source": "an extra example sentence in \(srcLang)",
          "example_target": "\(tgtLang) translation",
          "collocations": ["common collocation 1", "collocation 2"]
        }

        For longer phrases, clauses, or full sentences (3+ words), put them in "sentences" with this format:
        {
          "sentence": "the original \(srcLang) text",
          "translation": "\(tgtLang) translation",
          "structure": "explain the sentence structure in \(tgtLang) (subject, verb, object, clause types, etc.)",
          "grammar_points": ["grammar point 1 in \(tgtLang)", "grammar point 2"],
          "key_phrases": [{"phrase": "important phrase", "meaning": "\(tgtLang) meaning"}],
          "summary": "one-line \(tgtLang) summary"
        }
        """
        var batchResponse = ""
        do {
            for try await token in AIProvider.stream(prompt: prompt, model: selectedModel) {
                try Task.checkCancellation()
                batchResponse += token
                wordLearningResponse = batchResponse
            }
            parseMixedResponse(batchResponse, items: newItems)
        } catch is CancellationError {
            parseMixedResponse(batchResponse, items: newItems)
        } catch {
            wordLearningResponse = "Query failed: \(error.localizedDescription)"
        }
        isLoadingWordHelp = false
        saveLearnProgress()
    }

    func parseMixedResponse(_ raw: String, items: Set<String>) {
        if let response: LearningResponse = parseLLMJSONObject(raw) {
            if let words = response.words, !words.isEmpty {
                wordExplanations.insert(contentsOf: words, at: 0)
                GlobalVocabulary.shared.saveExplanations(words, storyID: story.id, cards: activeSubtitleCards)
                for w in words { globalOnlyWords.remove(w.word.lowercased()) }
            }
            if let sentences = response.sentences, !sentences.isEmpty {
                sentenceExplanations.insert(contentsOf: sentences, at: 0)
                GlobalVocabulary.shared.saveSentenceExplanations(sentences)
                for s in sentences { globalOnlyWords.remove(s.sentence.lowercased()) }
            }
            queriedWords.formUnion(items)
            rebuildWordLearningResponse()
            rebuildSentenceLearningResponse()
        } else if !raw.isEmpty {
            wordLearningResponse = raw
        }
    }

    func parseSentenceExplanations(_ raw: String) {
        if let parsed: [SentenceExplanation] = parseLLMJSON(raw) {
            sentenceExplanations = parsed
            queriedWords.formUnion(parsed.map { $0.sentence.lowercased() })
        }
    }

    func parseWordExplanations() {
        if let parsed: [WordExplanation] = parseLLMJSON(wordLearningResponse) {
            wordExplanations = parsed
            queriedWords.formUnion(parsed.map { $0.word.lowercased() })
        }
    }

    func rebuildWordLearningResponse() {
        if wordExplanations.isEmpty {
            wordLearningResponse = ""
        } else if let data = try? JSONEncoder().encode(wordExplanations),
           let str = String(data: data, encoding: .utf8) {
            wordLearningResponse = str
        }
    }

    func rebuildSentenceLearningResponse() {
        if sentenceExplanations.isEmpty {
            story.savedSentenceLearningResponse = ""
        } else if let data = try? JSONEncoder().encode(sentenceExplanations),
           let str = String(data: data, encoding: .utf8) {
            story.savedSentenceLearningResponse = str
        }
    }

    // MARK: - Chat

    func sendChatMessage() async {
        let userMessage = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty, !selectedModel.isEmpty else { return }
        chatMessages.append(ChatMessage(role: "user", content: userMessage))
        chatInput = ""
        isChatting = true
        let srcLang = story.sourceLanguage
        let tgtLang = story.targetLanguage
        let systemPrompt = """
        You are a helpful \(srcLang) learning assistant. The user is studying a \(srcLang) transcript.
        Answer in \(tgtLang) unless asked otherwise. Be concise and helpful.

        Transcript content:
        \(transcriptContext)
        """
        var fullPrompt = systemPrompt + "\n\n"
        for msg in chatMessages {
            fullPrompt += msg.role == "user" ? "User: \(msg.content)\n" : "Assistant: \(msg.content)\n"
        }
        chatMessages.append(ChatMessage(role: "assistant", content: ""))
        let lastIdx = chatMessages.count - 1
        do {
            for try await token in AIProvider.stream(prompt: fullPrompt, model: selectedModel) {
                try Task.checkCancellation()
                chatMessages[lastIdx].content += token
            }
        } catch is CancellationError {
            // Keep partial response
        } catch {
            if chatMessages[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chatMessages[lastIdx].content = "Request failed: \(error.localizedDescription)"
            }
        }
        isChatting = false
        saveLearnProgress()
    }
}
