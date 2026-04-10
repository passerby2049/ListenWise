/*
Abstract:
Global vocabulary store — words/phrases and their explanations shared across all stories.
*/

import Foundation

@MainActor @Observable
class GlobalVocabulary {
    static let shared = GlobalVocabulary()

    private(set) var words: Set<String> = []
    private(set) var wordExplanations: [String: WordExplanation] = [:]
    private(set) var sentenceExplanations: [String: SentenceExplanation] = [:]
    private(set) var reviewStates: [String: ReviewState] = [:]
    /// A single observed occurrence of a word in some story's subtitles.
    struct SourceSentence: Codable, Equatable {
        let source: String
        let target: String
        var storyID: UUID?
        var start: Double?
        var end: Double?
    }

    /// All source sentences observed for a given word key, in insertion order, deduped by source text.
    private(set) var sourceSentences: [String: [SourceSentence]] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("global-vocabulary.json")
    }()

    private init() {
        load()
    }

    // MARK: - Mutating

    func add(_ word: String) {
        let key = word.lowercased()
        guard !key.isEmpty else { return }
        if words.insert(key).inserted {
            ensureReviewState(for: key)
            save()
        }
    }

    func addAll(_ newWords: Set<String>) {
        let lowered = Set(newWords.map { $0.lowercased() }.filter { !$0.isEmpty })
        let before = words.count
        words.formUnion(lowered)
        for key in lowered { ensureReviewState(for: key) }
        if words.count != before { save() }
    }

    func remove(_ word: String) {
        let key = word.lowercased()
        if words.remove(key) != nil {
            wordExplanations.removeValue(forKey: key)
            sentenceExplanations.removeValue(forKey: key)
            reviewStates.removeValue(forKey: key)
            sourceSentences.removeValue(forKey: key)
            save()
        }
    }

    func saveExplanation(_ exp: WordExplanation, storyID: UUID? = nil, cards: [SubtitleCard] = []) {
        let key = exp.word.lowercased()
        wordExplanations[key] = exp
        ensureReviewState(for: key)
        appendSourceSentence(for: key, source: exp.sentence_source, target: exp.sentence_target, storyID: storyID, cards: cards)
        save()
    }

    func saveExplanations(_ exps: [WordExplanation], storyID: UUID? = nil, cards: [SubtitleCard] = []) {
        for exp in exps {
            let key = exp.word.lowercased()
            wordExplanations[key] = exp
            ensureReviewState(for: key)
            appendSourceSentence(for: key, source: exp.sentence_source, target: exp.sentence_target, storyID: storyID, cards: cards)
        }
        save()
    }

    private func appendSourceSentence(for key: String, source: String?, target: String, storyID: UUID?, cards: [SubtitleCard]) {
        guard let src = source?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty else { return }
        let tgt = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let timing = matchTiming(for: src, in: cards)
        var list = sourceSentences[key] ?? []
        if let existingIdx = list.firstIndex(where: { $0.source == src }) {
            var updated = list[existingIdx]
            if updated.target.isEmpty && !tgt.isEmpty { updated = SourceSentence(source: src, target: tgt, storyID: updated.storyID, start: updated.start, end: updated.end) }
            if updated.start == nil, let t = timing {
                updated = SourceSentence(source: src, target: updated.target, storyID: storyID, start: t.start, end: t.end)
            }
            list[existingIdx] = updated
            sourceSentences[key] = list
            return
        }
        list.append(SourceSentence(source: src, target: tgt, storyID: storyID, start: timing?.start, end: timing?.end))
        sourceSentences[key] = list
    }

    /// Find the subtitle card whose text most closely contains the given sentence.
    /// Falls back to nil if nothing matches.
    private func matchTiming(for sentence: String, in cards: [SubtitleCard]) -> (start: Double, end: Double)? {
        guard !cards.isEmpty else { return nil }
        let needle = sentence.lowercased()
        // Exact containment first
        for card in cards {
            let hay = card.text.lowercased()
            if hay == needle || hay.contains(needle) || needle.contains(hay) {
                return (card.start, card.end)
            }
        }
        return nil
    }

    /// All source sentences observed for a given key, most recent last.
    func sources(for key: String) -> [SourceSentence] {
        sourceSentences[key] ?? []
    }

    /// Flat list of every stored source sentence. Used by the audio-clipper batch.
    func allSourceSentences() -> [SourceSentence] {
        sourceSentences.values.flatMap { $0 }
    }

    /// For every stored source sentence missing timing info, search saved stories
    /// on disk for a matching subtitle card and backfill. Persists once if anything changed.
    func resolveMissingTimings(for keys: [String]? = nil) {
        let targetKeys = keys ?? Array(sourceSentences.keys)
        var dirty = false
        for key in targetKeys {
            guard var list = sourceSentences[key] else { continue }
            for i in list.indices where list[i].start == nil {
                if let loc = StoryStore.shared.findSourceLocation(for: list[i].source) {
                    list[i] = SourceSentence(source: list[i].source, target: list[i].target,
                                             storyID: loc.storyID, start: loc.start, end: loc.end)
                    dirty = true
                }
            }
            if dirty { sourceSentences[key] = list }
        }
        if dirty { save() }
    }

    func saveSentenceExplanation(_ exp: SentenceExplanation) {
        let key = exp.sentence.lowercased()
        sentenceExplanations[key] = exp
        ensureReviewState(for: key)
        save()
    }

    func saveSentenceExplanations(_ exps: [SentenceExplanation]) {
        for exp in exps {
            let key = exp.sentence.lowercased()
            sentenceExplanations[key] = exp
            ensureReviewState(for: key)
        }
        save()
    }

    // MARK: - Review state

    private func ensureReviewState(for key: String) {
        if reviewStates[key] == nil {
            reviewStates[key] = ReviewState()
        }
    }

    /// Apply a review rating to the given item and persist.
    func recordReview(for key: String, rating: ReviewRating) {
        let current = reviewStates[key] ?? ReviewState()
        reviewStates[key] = SM2.schedule(current, rating: rating)
        save()
    }

    /// Items whose dueDate is on or before `now`. Sorted by dueDate ascending.
    /// Only returns items that have an explanation (word or sentence).
    func dueItems(now: Date = Date(), newLimit: Int = 20) -> [ReviewItem] {
        var all: [ReviewItem] = []
        for (key, state) in reviewStates where state.dueDate <= now {
            if let word = wordExplanations[key] {
                all.append(ReviewItem(key: key, kind: .word(word), state: state))
            } else if let sentence = sentenceExplanations[key] {
                all.append(ReviewItem(key: key, kind: .sentence(sentence), state: state))
            }
        }
        // Separate brand-new items (no reviews yet) and cap them
        let seen = all.filter { $0.state.totalReviews > 0 }
        let fresh = all.filter { $0.state.totalReviews == 0 }
            .prefix(newLimit)
        return (seen + fresh).sorted { $0.state.dueDate < $1.state.dueDate }
    }

    /// Count of items due now (capped new items).
    func dueCount(now: Date = Date(), newLimit: Int = 20) -> Int {
        dueItems(now: now, newLimit: newLimit).count
    }

    /// All reviewable items regardless of due date — used for free practice / cram mode.
    /// Sorted by dueDate ascending so the "most stale" items come first.
    func allPracticeItems() -> [ReviewItem] {
        var all: [ReviewItem] = []
        for (key, state) in reviewStates {
            if let word = wordExplanations[key] {
                all.append(ReviewItem(key: key, kind: .word(word), state: state))
            } else if let sentence = sentenceExplanations[key] {
                all.append(ReviewItem(key: key, kind: .sentence(sentence), state: state))
            }
        }
        return all.sorted { $0.state.dueDate < $1.state.dueDate }
    }

    /// Returns global words that appear in the given text lines.
    /// Uses the same token/phrase matching rules as WordFlowView's highlighting,
    /// so the inspector list can never contain a word the rendered transcript
    /// wouldn't also visually mark.
    func matchingWords(in lines: [String]) -> Set<String> {
        guard !words.isEmpty, !lines.isEmpty else { return [] }
        return words.filter { WordTokenizer.containsAny($0, in: lines) }
    }

    // MARK: - Persistence

    private struct VocabData: Codable {
        let words: [String]
        let wordExplanations: [WordExplanation]?
        let sentenceExplanations: [SentenceExplanation]?
        let reviewStates: [String: ReviewState]?
        let sourceSentences: [String: [SourceSentence]]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Try new format first
        if let vocab = try? JSONDecoder().decode(VocabData.self, from: data) {
            words = Set(vocab.words)
            for exp in vocab.wordExplanations ?? [] {
                let key = exp.word.lowercased()
                wordExplanations[key] = exp
            }
            for exp in vocab.sentenceExplanations ?? [] {
                sentenceExplanations[exp.sentence.lowercased()] = exp
            }
            reviewStates = vocab.reviewStates ?? [:]
            sourceSentences = vocab.sourceSentences ?? [:]
            // Initialize review state and backfill source sentences for words that
            // predate the review feature.
            for key in words where reviewStates[key] == nil {
                reviewStates[key] = ReviewState()
            }
            for (key, exp) in wordExplanations {
                if sourceSentences[key] == nil,
                   let s = exp.sentence_source?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty {
                    sourceSentences[key] = [SourceSentence(source: s, target: exp.sentence_target)]
                }
            }
            return
        }
        // Fallback: old format was just [String]
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            words = Set(list)
            for key in words { reviewStates[key] = ReviewState() }
        }
    }

    private func save() {
        let vocab = VocabData(
            words: words.sorted(),
            wordExplanations: wordExplanations.values.sorted { $0.word < $1.word },
            sentenceExplanations: sentenceExplanations.values.sorted { $0.sentence < $1.sentence },
            reviewStates: reviewStates,
            sourceSentences: sourceSentences
        )
        DispatchQueue.global(qos: .utility).async { [vocab, fileURL] in
            if let data = try? JSONEncoder().encode(vocab) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
