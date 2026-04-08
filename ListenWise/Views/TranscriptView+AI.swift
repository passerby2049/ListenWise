/*
Abstract:
TranscriptView extension — AI operations (translate, reorganize, word learning, chat).
*/

import Foundation
import SwiftUI

// MARK: - Translation

extension TranscriptView {

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
            if let parsed = parseTranslationJSON(rawResponse) {
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

    func parseTranslationJSON(_ raw: String) -> [TranslationPair]? {
        parseLLMJSON(raw)
    }
}

// MARK: - Reorganize Transcript

extension TranscriptView {

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

        // Split cards into batches by 10-minute intervals
        let batches = splitIntoBatches(cards: cards, intervalSeconds: 600)

        var allResults: [(text: String, translation: String, start: Double, end: Double)] = []
        var previousContext: [String] = [] // merged sentences from prior batches

        for (batchIndex, batch) in batches.enumerated() {
            guard !Task.isCancelled else { break }

            reorganizeProgress = "Processing batch \(batchIndex + 1)/\(batches.count)..."

            let numberedCards = batch.cards.enumerated().map { i, card in
                "[\(i)] \(card.text)"
            }.joined(separator: "\n")

            let contextSection: String
            if previousContext.isEmpty {
                contextSection = ""
            } else {
                // Only include last ~20 sentences to keep prompt manageable
                let recentContext = previousContext.suffix(20)
                contextSection = """

                Previously processed text for context (do not include in output, do not re-process):
                \(recentContext.joined(separator: "\n"))

                """
            }

            let prompt = """
            Task: Merge these numbered \(srcLang) speech fragments into proper sentences. Fix typos. One sentence per entry. Keep it short.

            Rules:
            - Output JSON array ONLY. No explanation, no markdown.
            - Format: [{"cards": [0,1], "text": "Merged sentence.", "target": "\(tgtLang) translation."}]
            - Each entry must be exactly ONE complete sentence. Split at every sentence-ending punctuation (. ? ! 。？！ etc.).
            - Every index must appear exactly once, in order. Indices are 0-based for this batch only.
            - Do NOT summarize. Keep the original meaning word-for-word.
            - "target" is the \(tgtLang) translation of the "text" field.

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
            \(contextSection)
            Input:
            \(numberedCards)
            """

            var rawResponse = ""
            do {
                for try await token in AIProvider.stream(prompt: prompt, model: selectedModel) {
                    try Task.checkCancellation()
                    rawResponse += token
                    reorganizeProgress = "Batch \(batchIndex + 1)/\(batches.count): " + String(rawResponse.suffix(150))
                }

                if let sentences = parseReorganizeJSON(rawResponse) {
                    for sentence in sentences {
                        guard !sentence.cards.isEmpty else { continue }
                        let validIndices = sentence.cards.filter { $0 >= 0 && $0 < batch.cards.count }
                        guard !validIndices.isEmpty else { continue }
                        // Map local indices back to global card positions
                        let globalFirst = batch.offset + validIndices.first!
                        let globalLast = batch.offset + validIndices.last!
                        guard globalFirst < cards.count && globalLast < cards.count else { continue }
                        let start = cards[globalFirst].start
                        let end = cards[globalLast].end
                        allResults.append((text: sentence.text, translation: sentence.target ?? "", start: start, end: end))
                        previousContext.append(sentence.text)
                    }
                    // Update UI progressively
                    reorganizedCards = allResults
                    showReorganized = true
                }
            } catch is CancellationError {
                break
            } catch {
                reorganizeProgress = "Batch \(batchIndex + 1) failed: \(error.localizedDescription)"
                break
            }
        }

        if !allResults.isEmpty {
            reorganizedCards = allResults
            showReorganized = true
            story.savedReorganizedCards = reorganizedCards
            StoryStore.shared.save(story)
        }
        isReorganizing = false
    }

    private struct CardBatch {
        let offset: Int // global index of first card in this batch
        let cards: [(text: String, start: Double, end: Double)]
    }

    /// Split cards into batches at ~10-minute intervals, cutting at the first sentence-ending card past the boundary.
    private func splitIntoBatches(cards: [(text: String, start: Double, end: Double)], intervalSeconds: Double) -> [CardBatch] {
        guard !cards.isEmpty else { return [] }

        let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var batches: [CardBatch] = []
        var batchStart = 0
        var nextBoundary = intervalSeconds

        var i = 0
        while i < cards.count {
            let card = cards[i]
            if card.end >= nextBoundary {
                // Look for first sentence-ending card at or after this point
                var cutIndex = i
                let trimmed = card.text.trimmingCharacters(in: .whitespaces)
                if let last = trimmed.last, sentenceEnders.contains(last) {
                    cutIndex = i
                } else {
                    // Search forward for nearest sentence-ending card
                    var found = false
                    for j in (i + 1)..<min(i + 20, cards.count) {
                        let t = cards[j].text.trimmingCharacters(in: .whitespaces)
                        if let last = t.last, sentenceEnders.contains(last) {
                            cutIndex = j
                            found = true
                            break
                        }
                    }
                    if !found { cutIndex = i }
                }

                let batch = CardBatch(offset: batchStart, cards: Array(cards[batchStart...cutIndex]))
                batches.append(batch)
                batchStart = cutIndex + 1
                nextBoundary = cards[min(batchStart, cards.count - 1)].start + intervalSeconds
                i = batchStart
            } else {
                i += 1
            }
        }

        // Remaining cards
        if batchStart < cards.count {
            batches.append(CardBatch(offset: batchStart, cards: Array(cards[batchStart...])))
        }

        return batches
    }

    func parseReorganizeJSON(_ raw: String) -> [ReorganizedSentence]? {
        parseLLMJSON(raw)
    }
}

// MARK: - Word Learning

extension TranscriptView {

    func queryWordHelp() async {
        let newItems = markedWords.subtracting(queriedWords)
        guard !newItems.isEmpty, !selectedModel.isEmpty else { return }
        isLoadingWordHelp = true
        wordLearningResponse = ""

        let srcLang = story.sourceLanguage
        let tgtLang = story.targetLanguage

        // Gather context lines for word lookups
        let lines = displayLines
        var contextLines: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if newItems.contains(where: { lower.contains($0) }) && !contextLines.contains(line) {
                contextLines.append(line)
            }
        }

        let itemList = newItems.sorted().joined(separator: "\n- ")
        let context = contextLines.isEmpty ? "" :
            "Context from transcript (for reference only — do NOT analyze these sentences as items):\n" + contextLines.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        I'm learning \(srcLang). Below are items I selected from a transcript. Each item may be a single word, a short phrase, or a full sentence/clause. You decide which type each one is.

        IMPORTANT: Each item must appear in exactly ONE category. Do NOT break an item into sub-words. For example, if the item is "he is not bluffing", put it in "sentences" only — do NOT also add "bluffing" to "words".

        Items:
        - \(itemList)

        \(context)

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

    private func parseMixedResponse(_ raw: String, items: Set<String>) {
        if let response: LearningResponse = parseLLMJSONObject(raw) {
            if let words = response.words, !words.isEmpty {
                wordExplanations.insert(contentsOf: words, at: 0)
            }
            if let sentences = response.sentences, !sentences.isEmpty {
                sentenceExplanations.insert(contentsOf: sentences, at: 0)
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
            queriedWords = Set(parsed.map { $0.word.lowercased() })
        }
    }

    func rebuildWordLearningResponse() {
        if let data = try? JSONEncoder().encode(wordExplanations),
           let str = String(data: data, encoding: .utf8) {
            wordLearningResponse = str
        }
    }

    func rebuildSentenceLearningResponse() {
        if let data = try? JSONEncoder().encode(sentenceExplanations),
           let str = String(data: data, encoding: .utf8) {
            story.savedSentenceLearningResponse = str
        }
    }
}

// MARK: - Chat

extension TranscriptView {

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

// MARK: - Helpers

extension TranscriptView {

    var transcriptContext: String {
        let text = displayLines.joined(separator: "\n")
        let maxLen = 3000
        if text.count > maxLen {
            return String(text.prefix(maxLen)) + "..."
        }
        return text
    }

    func exportStory() {
        do {
            let url = try StoryStore.shared.exportToMarkdown(story)
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        } catch {
            print("Export failed: \(error)")
        }
    }

    func saveLearnProgress() {
        story.savedMarkedWords = markedWords
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
}
