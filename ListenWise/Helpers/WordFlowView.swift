/*
Abstract:
WordFlowView — tappable/draggable word-level text for vocabulary learning.
*/

import Foundation
import NaturalLanguage
import SwiftUI

// MARK: - Word Flow Layout

/// A SwiftUI Layout that wraps child views like words in a paragraph.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.replacingUnspecifiedDimensions().width
        return computePositions(in: w, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computePositions(in: bounds.width, subviews: subviews)
        for (i, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[i].x,
                            y: bounds.minY + result.positions[i].y),
                proposal: .unspecified
            )
        }
    }

    private func computePositions(in maxWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
        return (positions, CGSize(width: maxWidth, height: y + lineH))
    }
}

// MARK: - Preference Key for drag tracking

private struct WordFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - WordFlowView

/// Displays plain text as individually tappable words for vocabulary learning.
struct WordFlowView: View {
    let text: String
    @Binding var markedWords: Set<String>
    var isActive: Bool = true

    // Drag-to-select state
    @State private var dragStartIndex: Int? = nil
    @State private var dragEndIndex: Int? = nil
    @State private var isDragging = false
    @State private var wordFrames: [Int: CGRect] = [:]

    /// Whether the text uses NL tokenization (CJK) vs whitespace splitting.
    private var usesNLTokenizer: Bool {
        let bySpace = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return bySpace.count <= 2 && text.count > 10
    }

    private var tokens: [String] {
        let bySpace = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if !usesNLTokenizer { return bySpace }
        // CJK text without spaces — use NLTokenizer for word segmentation,
        // preserving punctuation between tokens as separate entries.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        var lastEnd = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Capture any punctuation/gap between the previous token and this one
            if lastEnd < range.lowerBound {
                let gap = String(text[lastEnd..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !gap.isEmpty { result.append(gap) }
            }
            result.append(String(text[range]))
            lastEnd = range.upperBound
            return true
        }
        // Capture trailing punctuation after the last token
        if lastEnd < text.endIndex {
            let trailing = String(text[lastEnd...]).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty { result.append(trailing) }
        }
        return result.isEmpty ? bySpace : result
    }

    private func key(for token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private var dragRange: ClosedRange<Int>? {
        guard let s = dragStartIndex, let e = dragEndIndex, s != e else { return nil }
        return min(s, e)...max(s, e)
    }

    /// Find the token index closest to a point (for drag tracking)
    private func wordIndex(at point: CGPoint) -> Int? {
        // Direct hit
        for (index, frame) in wordFrames {
            if frame.contains(point) { return index }
        }
        // Find closest word on the same line
        let sameLine = wordFrames.filter { abs($0.value.midY - point.y) < $0.value.height }
        return sameLine.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) })?.key
    }

    // MARK: - Segment grouping (phrases rendered as connected units)

    private struct Segment: Identifiable {
        let id: Int
        let tokenIndices: [Int]
        let phrase: String?
    }

    private var segments: [Segment] {
        let keys = tokens.map { key(for: $0) }
        var result: [Segment] = []
        var i = 0
        // Build phrase list: split by space for English, match consecutive keys for CJK
        let multiWordPhrases: [(phrase: String, parts: [String])] = markedWords.compactMap { phrase in
            if phrase.contains(" ") {
                // English-style space-separated phrase
                let parts = phrase.components(separatedBy: " ")
                return parts.count > 1 ? (phrase, parts) : nil
            } else if usesNLTokenizer && phrase.count > 1 {
                // CJK phrase — match by checking if consecutive keys join to form the phrase
                return (phrase, []) // handled differently below
            }
            return nil
        }

        while i < tokens.count {
            var matched: (phrase: String, length: Int)? = nil

            for mp in multiWordPhrases {
                if !mp.parts.isEmpty {
                    // English: match by parts
                    let pw = mp.parts
                    if i + pw.count <= keys.count && Array(keys[i..<i+pw.count]) == pw {
                        if matched == nil || pw.count > matched!.length {
                            matched = (mp.phrase, pw.count)
                        }
                    }
                } else {
                    // CJK: try matching consecutive tokens whose keys concatenate to the phrase
                    let maxLen = min(10, tokens.count - i)
                    guard maxLen >= 2 else { continue }
                    for len in 2...maxLen {
                        let joined = keys[i..<i+len].joined()
                        if joined == mp.phrase {
                            if matched == nil || len > matched!.length {
                                matched = (mp.phrase, len)
                            }
                            break
                        }
                        if !mp.phrase.hasPrefix(joined) { break }
                    }
                }
            }

            if let m = matched {
                result.append(Segment(id: i, tokenIndices: Array(i..<i+m.length), phrase: m.phrase))
                i += m.length
            } else {
                result.append(Segment(id: i, tokenIndices: [i], phrase: nil))
                i += 1
            }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        WordFlowLayout(spacing: usesNLTokenizer ? 0 : 3) {
            ForEach(segments) { segment in
                if segment.phrase != nil {
                    phraseSegmentView(segment: segment)
                } else {
                    singleWordView(index: segment.tokenIndices[0])
                }
            }
        }
        .coordinateSpace(name: "wordflow")
        .onPreferenceChange(WordFrameKey.self) { wordFrames = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("wordflow"))
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartIndex = wordIndex(at: value.startLocation)
                    }
                    dragEndIndex = wordIndex(at: value.location)
                }
                .onEnded { _ in finalizeDrag() }
        )
    }

    // MARK: - Helpers

    /// Split trailing punctuation from a token: "undertaking." -> ("undertaking", ".")
    private func splitTrailing(_ token: String) -> (core: String, trailing: String) {
        let trailing = String(token.reversed().prefix(while: { $0.isPunctuation }).reversed())
        let core = trailing.isEmpty ? token : String(token.dropLast(trailing.count))
        return (core, trailing)
    }

    private var textColor: Color { isActive ? Color.primary : Color.secondary }

    /// Plain text with geometry tracking (no highlight)
    @ViewBuilder
    private func wordTextPlain(index: Int) -> some View {
        Text(tokens[index])
            .foregroundStyle(textColor)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: WordFrameKey.self,
                        value: [index: geo.frame(in: .named("wordflow"))]
                    )
                }
            )
    }

    private let highlightBg = Color(nsColor: NSColor(red: 1, green: 0.8, blue: 0, alpha: 0.22))
    private let highlightLine = Color(nsColor: NSColor(red: 1, green: 0.67, blue: 0, alpha: 0.75))

    // MARK: - Phrase segment (connected highlight, trailing punct excluded)

    @ViewBuilder
    private func phraseSegmentView(segment: Segment) -> some View {
        let lastIdx = segment.tokenIndices.last!
        let (lastCore, lastTrailing) = splitTrailing(tokens[lastIdx])

        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(segment.tokenIndices, id: \.self) { idx in
                    if idx == lastIdx && !lastTrailing.isEmpty {
                        Text(lastCore)
                            .foregroundStyle(Color.primary)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: WordFrameKey.self,
                                        value: [idx: geo.frame(in: .named("wordflow"))]
                                    )
                                }
                            )
                    } else {
                        wordTextPlain(index: idx)
                    }
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(highlightBg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(highlightLine).frame(height: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))

            if !lastTrailing.isEmpty {
                Text(lastTrailing)
                            .foregroundStyle(textColor)
            }
        }
        .onTapGesture {
            if let phrase = segment.phrase { markedWords.remove(phrase) }
        }
    }

    // MARK: - Single word (trailing punct excluded from highlight)

    @ViewBuilder
    private func singleWordView(index: Int) -> some View {
        let token = tokens[index]
        let k = key(for: token)
        let marked = markedWords.contains(k)
        let inDrag = dragRange?.contains(index) == true
        let highlighted = marked || inDrag
        let (core, trailing) = splitTrailing(token)

        HStack(spacing: 0) {
            Text(core)
                .padding(.horizontal, highlighted ? 3 : 1)
                .padding(.vertical, highlighted ? 1 : 0)
                .background(
                    highlighted
                        ? Color(nsColor: NSColor(red: 1, green: 0.8, blue: 0, alpha: inDrag && !marked ? 0.15 : 0.22))
                        : Color.clear
                )
                .overlay(alignment: .bottom) {
                    if highlighted {
                        Rectangle()
                            .fill(Color(nsColor: NSColor(red: 1, green: 0.67, blue: 0, alpha: inDrag && !marked ? 0.4 : 0.75)))
                            .frame(height: 1.5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            if !trailing.isEmpty {
                Text(trailing)
            }
        }
        .foregroundStyle(textColor)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WordFrameKey.self,
                    value: [index: geo.frame(in: .named("wordflow"))]
                )
            }
        )
        .onTapGesture {
            if marked { markedWords.remove(k) }
            else if !k.isEmpty { markedWords.insert(k) }
        }
    }

    // MARK: - Finalize drag selection

    private func finalizeDrag() {
        defer {
            isDragging = false
            dragStartIndex = nil
            dragEndIndex = nil
        }
        guard let range = dragRange, range.count > 1 else { return }
        let separator = usesNLTokenizer ? "" : " "
        let phrase = tokens[range].map { key(for: $0) }.joined(separator: separator)
        guard !phrase.isEmpty else { return }
        // Remove any single words now covered by the phrase
        for idx in range {
            markedWords.remove(key(for: tokens[idx]))
        }
        markedWords.insert(phrase)
    }
}
