/*
Abstract:
Shared tokenization/key logic used by both WordFlowView (for rendering
highlighted word cells) and GlobalVocabulary (for deciding whether a
previously-marked word actually occurs in a story). Keeping these on one
helper guarantees the Inspector's "auto-marked from global vocab" rule
matches what WordFlowView would visually highlight — no more and no less.
*/

import Foundation
import NaturalLanguage

enum WordTokenizer {

    /// Strip edge punctuation and lowercase. This IS the key WordFlowView
    /// uses to decide whether a rendered token is "marked".
    static func key(for token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    /// Matches WordFlowView's `usesNLTokenizer` heuristic: CJK text has few
    /// whitespace chunks but many characters, so we fall back to NLTokenizer.
    static func usesNLTokenizer(_ text: String) -> Bool {
        let bySpace = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return bySpace.count <= 2 && text.count > 10
    }

    /// Tokenize a line the same way WordFlowView does. Note: WordFlowView
    /// also keeps inter-token punctuation as separate entries for its
    /// segment layout, but that's a render-only concern; for matching we
    /// only need the real words.
    static func tokens(in text: String) -> [String] {
        let bySpace = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard usesNLTokenizer(text) else { return bySpace }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]))
            return true
        }
        return result.isEmpty ? bySpace : result
    }

    /// Return true if `markedKey` would be highlighted by WordFlowView
    /// when rendering `line`. The three cases mirror WordFlowView's
    /// `segments` logic exactly:
    ///
    /// 1. `markedKey` contains a space → English-style multi-word phrase;
    ///    match consecutive token keys against the space-separated parts.
    /// 2. `markedKey` is a single token → some token key equals it.
    /// 3. `markedKey` is a multi-character CJK phrase with no spaces →
    ///    consecutive token keys concatenated (no separator) equal it.
    static func contains(_ markedKey: String, in line: String) -> Bool {
        let keys = tokens(in: line).map { key(for: $0) }
        guard !keys.isEmpty else { return false }

        if markedKey.contains(" ") {
            let parts = markedKey.components(separatedBy: " ")
            guard !parts.isEmpty, keys.count >= parts.count else { return false }
            for start in 0...(keys.count - parts.count) {
                if Array(keys[start..<start + parts.count]) == parts { return true }
            }
            return false
        }

        if keys.contains(markedKey) { return true }

        // Possible CJK multi-token phrase (no space separator).
        guard markedKey.count > 1 else { return false }
        let maxLen = min(10, keys.count)
        for i in 0..<keys.count {
            guard maxLen >= 2, i + 2 <= keys.count else { continue }
            for len in 2...maxLen where i + len <= keys.count {
                let joined = keys[i..<i + len].joined()
                if joined == markedKey { return true }
                if !markedKey.hasPrefix(joined) { break }
            }
        }
        return false
    }

    /// Return true if `markedKey` occurs in any of the given lines.
    static func containsAny(_ markedKey: String, in lines: [String]) -> Bool {
        lines.contains { contains(markedKey, in: $0) }
    }
}
