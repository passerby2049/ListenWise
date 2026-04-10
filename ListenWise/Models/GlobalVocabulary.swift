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
        if words.insert(key).inserted { save() }
    }

    func addAll(_ newWords: Set<String>) {
        let lowered = Set(newWords.map { $0.lowercased() }.filter { !$0.isEmpty })
        let before = words.count
        words.formUnion(lowered)
        if words.count != before { save() }
    }

    func remove(_ word: String) {
        let key = word.lowercased()
        if words.remove(key) != nil {
            wordExplanations.removeValue(forKey: key)
            sentenceExplanations.removeValue(forKey: key)
            save()
        }
    }

    func saveExplanation(_ exp: WordExplanation) {
        wordExplanations[exp.word.lowercased()] = exp
        save()
    }

    func saveExplanations(_ exps: [WordExplanation]) {
        for exp in exps { wordExplanations[exp.word.lowercased()] = exp }
        save()
    }

    func saveSentenceExplanation(_ exp: SentenceExplanation) {
        sentenceExplanations[exp.sentence.lowercased()] = exp
        save()
    }

    func saveSentenceExplanations(_ exps: [SentenceExplanation]) {
        for exp in exps { sentenceExplanations[exp.sentence.lowercased()] = exp }
        save()
    }

    /// Returns global words that appear in the given text lines.
    func matchingWords(in lines: [String]) -> Set<String> {
        guard !words.isEmpty, !lines.isEmpty else { return [] }
        let fullText = lines.joined(separator: " ").lowercased()
        return words.filter { fullText.contains($0) }
    }

    // MARK: - Persistence

    private struct VocabData: Codable {
        let words: [String]
        let wordExplanations: [WordExplanation]?
        let sentenceExplanations: [SentenceExplanation]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Try new format first
        if let vocab = try? JSONDecoder().decode(VocabData.self, from: data) {
            words = Set(vocab.words)
            for exp in vocab.wordExplanations ?? [] {
                wordExplanations[exp.word.lowercased()] = exp
            }
            for exp in vocab.sentenceExplanations ?? [] {
                sentenceExplanations[exp.sentence.lowercased()] = exp
            }
            return
        }
        // Fallback: old format was just [String]
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            words = Set(list)
        }
    }

    private func save() {
        let vocab = VocabData(
            words: words.sorted(),
            wordExplanations: wordExplanations.values.sorted { $0.word < $1.word },
            sentenceExplanations: sentenceExplanations.values.sorted { $0.sentence < $1.sentence }
        )
        DispatchQueue.global(qos: .utility).async { [vocab, fileURL] in
            if let data = try? JSONEncoder().encode(vocab) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
