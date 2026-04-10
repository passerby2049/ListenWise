/*
Abstract:
Spaced repetition review session — SM-2 flashcards over the global vocabulary.
*/

import SwiftUI
import AppKit
import AVFoundation

private let reviewSpeechSynthesizer = AVSpeechSynthesizer()

/// Box around AVAudioPlayer so it can live in @State without triggering SwiftUI diffing on the player itself.
@MainActor
final class ReviewAudioPlayerBox {
    var player: AVAudioPlayer?
    func stop() {
        player?.stop()
        player = nil
    }
}

struct ReviewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppPreferences.self) private var preferences

    @State private var queue: [ReviewItem] = []
    @State private var index: Int = 0
    @State private var showAnswer: Bool = false
    @State private var reviewedCount: Int = 0
    @State private var correctCount: Int = 0
    @State private var isComplete: Bool = false
    @State private var isPracticeMode: Bool = false
    @State private var audioPrepTask: Task<Void, Never>? = nil
    @State private var audioPrepProgress: (done: Int, total: Int)? = nil
    @State private var audioPrepError: String? = nil
    @State private var audioPrepTick: Int = 0
    @State private var audioBox = ReviewAudioPlayerBox()

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if isComplete || queue.isEmpty {
                    completionView
                } else if let current = currentItem {
                    cardView(for: current)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear(perform: loadQueue)
        .onDisappear {
            audioPrepTask?.cancel()
            audioPrepTask = nil
            if reviewSpeechSynthesizer.isSpeaking {
                reviewSpeechSynthesizer.stopSpeaking(at: .immediate)
            }
            audioBox.stop()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if isPracticeMode && !isComplete {
                Text("PRACTICE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(preferences.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(preferences.accentColor.opacity(0.15)))
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(preferences.accentColor)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Queue

    private var currentItem: ReviewItem? {
        guard index < queue.count else { return nil }
        return queue[index]
    }

    private var progress: Double {
        guard !queue.isEmpty else { return 0 }
        return Double(reviewedCount) / Double(queue.count)
    }

    private func loadQueue() {
        // Don't run resolveMissingTimings here — it does full-store disk IO on the
        // main actor. It's only needed before audio prep, which calls it itself.
        queue = GlobalVocabulary.shared.dueItems()
        index = 0
        reviewedCount = 0
        correctCount = 0
        showAnswer = false
        isPracticeMode = false
        isComplete = queue.isEmpty
        if let first = queue.first {
            playPrimary(for: first)
        }
    }

    private func startPractice() {
        let items = GlobalVocabulary.shared.allPracticeItems()
        guard !items.isEmpty else { return }
        queue = items.shuffled()
        index = 0
        reviewedCount = 0
        correctCount = 0
        showAnswer = false
        isPracticeMode = true
        isComplete = false
        if let first = queue.first {
            playPrimary(for: first)
        }
    }

    private func speak(_ text: String) {
        if reviewSpeechSynthesizer.isSpeaking {
            reviewSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        reviewSpeechSynthesizer.speak(utterance)
    }

    /// Picks the first cached source clip for a word-type item, if any.
    /// Sentence items don't have per-source clips, so this always returns nil for them.
    private func primaryClipURL(for item: ReviewItem) -> URL? {
        guard case .word(let w) = item.kind else { return nil }
        for pair in GlobalVocabulary.shared.sources(for: w.word.lowercased()) {
            if let url = SourceAudioClipper.shared.cachedClipURL(for: pair) {
                return url
            }
        }
        return nil
    }

    /// Core of Phase 2: listen in the original context first. If a source clip
    /// is cached for this item, play it; otherwise fall back to TTS of the word.
    private func playPrimary(for item: ReviewItem) {
        if let url = primaryClipURL(for: item) {
            playClip(at: url)
        } else {
            speak(item.displayText)
        }
    }

    private func rate(_ rating: ReviewRating) {
        guard let current = currentItem else { return }
        GlobalVocabulary.shared.recordReview(for: current.key, rating: rating)
        reviewedCount += 1
        if rating != .again { correctCount += 1 }
        withAnimation(.easeInOut(duration: 0.2)) {
            if index + 1 < queue.count {
                index += 1
                showAnswer = false
            } else {
                isComplete = true
            }
        }
        if !isComplete, let next = currentItem {
            playPrimary(for: next)
        }
    }

    // MARK: - Card View

    @ViewBuilder
    private func cardView(for item: ReviewItem) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Front — the word/sentence
            VStack(spacing: 12) {
                Text(item.displayText)
                    .font(.system(size: cardFontSize(for: item), weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    if case .word(let w) = item.kind, let phonetic = w.phonetic, !phonetic.isEmpty {
                        Text(phonetic)
                            .font(.system(size: 18, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                speak(item.displayText)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(preferences.accentColor)
                                    .frame(width: 20, height: 20)
                                    .padding(10)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .keyboardShortcut("w", modifiers: [])
                            .help("Play word (W)")

                            if let url = primaryClipURL(for: item) {
                                Button {
                                    playClip(at: url)
                                } label: {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(preferences.accentColor)
                                        .frame(width: 20, height: 20)
                                        .padding(10)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .keyboardShortcut(.space, modifiers: [])
                                .help("Replay original sentence (Space)")
                            }
                        }
                    }
                }

                if case .word = item.kind, primaryClipURL(for: item) == nil {
                    Text("Original audio unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            // Back — definitions, appears after "Show Answer"
            if showAnswer {
                answerView(for: item)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAnswer = true }
                } label: {
                    Text("Show Answer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(preferences.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.bottom, 40)
            }
        }
    }

    private func cardFontSize(for item: ReviewItem) -> CGFloat {
        let count = item.displayText.count
        if count > 80 { return 20 }
        if count > 40 { return 26 }
        if count > 20 { return 34 }
        return 44
    }

    // MARK: - Answer View

    @ViewBuilder
    private func answerView(for item: ReviewItem) -> some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch item.kind {
                    case .word(let w):
                        wordAnswer(w)
                    case .sentence(let s):
                        sentenceAnswer(s)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 48)
            }
            .frame(maxHeight: 260)

            ratingButtons(for: item)
                .padding(.horizontal, 48)
                .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private func wordAnswer(_ w: WordExplanation) -> some View {
        if !w.pos.isEmpty {
            Text(w.pos)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(preferences.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(preferences.accentColor.opacity(0.12)))
        }
        if !w.definition_target.isEmpty {
            Text(w.definition_target)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
        }
        if !w.definition_source.isEmpty {
            Text(w.definition_source)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        let sources = GlobalVocabulary.shared.sources(for: w.word.lowercased())
        if !sources.isEmpty {
            Divider().padding(.vertical, 4)
            Text(sources.count > 1 ? "Seen in \(sources.count) contexts" : "In context")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(preferences.accentColor.opacity(0.4))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(highlightWord(w.word, in: pair.source))
                                    .font(.system(size: 14, design: .serif))
                                    .italic()
                                    .fixedSize(horizontal: false, vertical: true)
                                sourcePlayButton(for: pair)
                            }
                            if !pair.target.isEmpty {
                                Text(pair.target)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        if !w.example_source.isEmpty {
            Divider().padding(.vertical, 4)
            Text("Example")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(w.example_source)
                .font(.system(size: 14, design: .serif))
                .italic()
            if !w.example_target.isEmpty {
                Text(w.example_target)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sourcePlayButton(for pair: GlobalVocabulary.SourceSentence) -> some View {
        if let url = SourceAudioClipper.shared.cachedClipURL(for: pair) {
            Button {
                playClip(at: url)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(preferences.accentColor)
            }
            .buttonStyle(.plain)
            .help("Play original audio")
        } else if pair.storyID != nil && pair.start != nil {
            Image(systemName: "waveform.slash")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .help("Original audio not prepared — use Prepare Original Audio on the finish screen")
        }
    }

    private func playClip(at url: URL) {
        if reviewSpeechSynthesizer.isSpeaking {
            reviewSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
        audioBox.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            audioBox.player = p
        } catch {
            // Fall through silently — the caller can re-trigger TTS if desired
        }
    }

    /// Bolds occurrences of `word` (case-insensitive) inside `sentence`.
    private func highlightWord(_ word: String, in sentence: String) -> AttributedString {
        var attr = AttributedString(sentence)
        let lowerSentence = sentence.lowercased()
        let lowerWord = word.lowercased()
        guard !lowerWord.isEmpty else { return attr }
        var searchStart = lowerSentence.startIndex
        while let range = lowerSentence.range(of: lowerWord, range: searchStart..<lowerSentence.endIndex) {
            let nsRange = NSRange(range, in: lowerSentence)
            if let attrRange = Range(nsRange, in: attr) {
                attr[attrRange].font = .system(size: 14, weight: .bold, design: .serif)
                attr[attrRange].foregroundColor = preferences.accentColor
            }
            searchStart = range.upperBound
        }
        return attr
    }

    @ViewBuilder
    private func sentenceAnswer(_ s: SentenceExplanation) -> some View {
        if !s.translation.isEmpty {
            Text(s.translation)
                .font(.system(size: 16))
        }
        if !s.summary.isEmpty {
            Text(s.summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        if !s.structure.isEmpty {
            Divider().padding(.vertical, 4)
            Text(s.structure)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rating Buttons

    @ViewBuilder
    private func ratingButtons(for item: ReviewItem) -> some View {
        let previews = SM2.previewIntervals(item.state)
        HStack(spacing: 10) {
            ForEach(ReviewRating.allCases, id: \.rawValue) { rating in
                ratingButton(rating, days: previews[rating] ?? 1)
            }
        }
    }

    @ViewBuilder
    private func ratingButton(_ rating: ReviewRating, days: Int) -> some View {
        let color = ratingColor(rating)
        Button {
            rate(rating)
        } label: {
            VStack(spacing: 4) {
                Text(rating.label)
                    .font(.system(size: 14, weight: .semibold))
                Text(intervalLabel(days: days))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(color.opacity(0.5), lineWidth: 1)
                    )
            )
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(rating.shortcutKey)), modifiers: [])
        .disabled(!showAnswer)
        .opacity(showAnswer ? 1 : 0.4)
    }

    private func ratingColor(_ rating: ReviewRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard:  return .orange
        case .good:  return preferences.accentColor
        case .easy:  return .green
        }
    }

    private func intervalLabel(days: Int) -> String {
        if days < 1 { return "<1d" }
        if days == 1 { return "1d" }
        if days < 30 { return "\(days)d" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    // MARK: - Completion View

    @ViewBuilder
    private var completionView: some View {
        let hasAnyVocab = !GlobalVocabulary.shared.reviewStates.isEmpty
        VStack(spacing: 20) {
            Image(systemName: queue.isEmpty ? "sparkles" : "checkmark.seal.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(preferences.accentColor)
            Text(queue.isEmpty ? "Nothing to Review" : "Session Complete")
                .font(.system(size: 24, weight: .bold))
            if !queue.isEmpty {
                Text("\(reviewedCount) reviewed · \(correctCount)/\(reviewedCount) recalled")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Text("Come back later — new words will be scheduled automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            audioPrepSection

            HStack(spacing: 12) {
                if hasAnyVocab {
                    Button {
                        startPractice()
                    } label: {
                        Label("Practice All", systemImage: "repeat")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Drill every word regardless of due date")
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var audioPrepSection: some View {
        let _ = audioPrepTick // force redraw on cache-change ticks
        let pending = SourceAudioClipper.shared.pendingCount(in: GlobalVocabulary.shared.allSourceSentences())

        if let progress = audioPrepProgress {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing original audio  \(progress.done)/\(progress.total)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    audioPrepTask?.cancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        } else if let err = audioPrepError {
            Text(err)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        } else if pending > 0 {
            Button {
                startAudioPrep()
            } label: {
                Label("Prepare Original Audio (\(pending))", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Download and clip the original audio for every saved sentence so you can hear it during review")
        } else if !GlobalVocabulary.shared.allSourceSentences().isEmpty {
            Label("Original audio ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        }
    }

    private func startAudioPrep() {
        audioPrepError = nil
        GlobalVocabulary.shared.resolveMissingTimings()
        let all = GlobalVocabulary.shared.allSourceSentences()
        let resolvable = all.filter { $0.storyID != nil && $0.start != nil }
        let skipped = all.count - resolvable.count
        let sentences = resolvable.filter { SourceAudioClipper.shared.cachedClipURL(for: $0) == nil }
        guard !sentences.isEmpty else {
            if skipped > 0 {
                audioPrepError = "\(skipped) sentence(s) have no matching source in any stored story and were skipped."
            }
            return
        }

        // Group by storyID so each video's full audio is downloaded once and released
        // before moving on to the next video.
        var groups: [(UUID, [GlobalVocabulary.SourceSentence])] = []
        var indexByStory: [UUID: Int] = [:]
        for s in sentences {
            guard let sid = s.storyID else { continue }
            if let i = indexByStory[sid] {
                groups[i].1.append(s)
            } else {
                indexByStory[sid] = groups.count
                groups.append((sid, [s]))
            }
        }

        audioPrepProgress = (0, sentences.count)
        audioPrepTask = Task { @MainActor in
            defer {
                audioPrepProgress = nil
                SourceAudioClipper.shared.clearSessionDownloads()
                audioPrepTick &+= 1
            }
            var done = 0
            var failures = 0
            for (storyID, group) in groups {
                if Task.isCancelled { break }
                for sentence in group {
                    if Task.isCancelled { break }
                    do {
                        _ = try await SourceAudioClipper.shared.prepareClip(for: sentence)
                    } catch {
                        failures += 1
                    }
                    done += 1
                    audioPrepProgress = (done, sentences.count)
                }
                SourceAudioClipper.shared.releaseFullAudio(for: storyID)
            }
            if failures > 0 && !Task.isCancelled {
                audioPrepError = "Prepared \(done - failures) of \(done). \(failures) failed (source video unavailable)."
            }
        }
    }
}
