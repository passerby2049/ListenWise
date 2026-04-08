/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Helper code for UI and transcription.
*/

import Foundation
import AVFoundation
import NaturalLanguage
import SwiftUI

extension Story: Equatable {
    static func == (lhs: Story, rhs: Story) -> Bool {
        lhs.id == rhs.id
    }
}

extension Story: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum TranscriptionError: Error {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound

    var descriptionString: String {
        switch self {
        case .couldNotDownloadModel:
            return "Could not download the model."
        case .failedToSetupRecognitionStream:
            return "Could not set up the speech recognition stream."
        case .invalidAudioDataType:
            return "Unsupported audio format."
        case .localeNotSupported:
            return "This locale is not yet supported by SpeechAnalyzer."
        case .noInternetForModelDownload:
            return "The model could not be downloaded because the user is not connected to internet."
        case .audioFilePathNotFound:
            return "Couldn't find the audio file."
        }
    }
}

// MARK: - Subtitle Export

struct SubtitleExporter {
    /// Pre-compute subtitle cards for real-time playback overlay.
    static func subtitleCards(from text: AttributedString) -> [(text: String, start: Double, end: Double)] {
        var groups: [(text: String, start: Double, end: Double)] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double?
        var lastEnd: Double = 0 // Track the last known end time for runs without timing
        var hasTimedRun = false

        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            if let timeRange = run.audioTimeRange {
                hasTimedRun = true
                let start = CMTimeGetSeconds(timeRange.start)
                let end = CMTimeGetSeconds(timeRange.end)
                if currentStart == nil { currentStart = start }
                currentEnd = end
                lastEnd = end
                currentText += runText
            } else {
                // Run without timing — use last known end time as fallback only when
                // the transcript contains real timing somewhere. If there is no timing
                // at all (e.g. restored plain text), return [] so callers can fall back
                // to saved subtitle cards instead of collapsing into one huge block.
                if currentStart == nil { currentStart = lastEnd }
                currentText += runText
            }

            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
            let sentenceEnd = trimmed.last.map { sentenceEnders.contains($0) } ?? false
            if sentenceEnd || trimmed.count > 60 {
                let s = currentStart ?? lastEnd
                let e = currentEnd ?? (lastEnd + 3) // Estimate 3s if no end time
                groups.append((trimmed, s, e))
                lastEnd = e
                currentText = ""
                currentStart = nil
                currentEnd = nil
            }
        }

        // Flush remaining text
        let remaining = currentText.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            let s = currentStart ?? lastEnd
            let e = currentEnd ?? (lastEnd + 3)
            groups.append((remaining, s, e))
        }

        // If the transcript has no timing metadata at all, these synthesized groups are
        // not trustworthy for subtitle/timestamp restoration. Let callers fall back to
        // persisted original subtitle cards instead.
        return hasTimedRun ? groups : []
    }

    /// Return the subtitle text active at the given playback position.
    static func subtitle(at time: Double, in cards: [(text: String, start: Double, end: Double)]) -> String {
        cards.first { $0.start <= time && time < $0.end }?.text ?? ""
    }
}

// MARK: - JSON Parsing Utility

/// Extract and decode a JSON array from an LLM response that may be wrapped in markdown fences.
func parseLLMJSON<T: Decodable>(_ raw: String) -> [T]? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "["), let e = jsonStr.lastIndex(of: "]") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([T].self, from: data)
}

/// Extract and decode a JSON object from an LLM response that may be wrapped in markdown fences.
func parseLLMJSONObject<T: Decodable>(_ raw: String) -> T? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "{"), let e = jsonStr.lastIndex(of: "}") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

// MARK: - Word Chip View (hover to reveal ×)

struct WordChipView: View {
    let word: String
    var onTap: () -> Void
    var onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Invisible sizer — always text + × to fix chip width
            HStack(spacing: 4) {
                Text(word).font(.callout)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .opacity(0)

            // Visible: text centered, or text + × when hovered
            if isHovered {
                HStack(spacing: 4) {
                    Text(word).font(.callout)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .onTapGesture(perform: onRemove)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            } else {
                Text(word)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .background(Color.yellow.opacity(0.15))
        .overlay(Capsule().stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Word Flow Layout & Views

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

// MARK: - Markdown Renderer

struct MarkdownView: View {
    let markdown: String

    private enum Block: Identifiable {
        case h1(String), h2(String), h3(String)
        case bullet(String)
        case rule
        case body(String)

        var id: String {
            switch self {
            case .h1(let s): return "h1:\(s)"
            case .h2(let s): return "h2:\(s)"
            case .h3(let s): return "h3:\(s)"
            case .bullet(let s): return "bullet:\(s)"
            case .rule: return "rule:\(UUID().uuidString)"
            case .body(let s): return "body:\(s)"
            }
        }
    }

    private func parseBlocks() -> [Block] {
        markdown.components(separatedBy: "\n").compactMap { raw in
            let line = raw
            if line.hasPrefix("### ") { return .h3(String(line.dropFirst(4))) }
            if line.hasPrefix("## ") { return .h2(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .h1(String(line.dropFirst(2))) }
            if line == "***" || line == "---" { return .rule }
            if line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return .body(trimmed)
        }
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .h1(let s): inlineText(s).font(.title2.bold())
        case .h2(let s): inlineText(s).font(.title3.bold())
        case .h3(let s): inlineText(s).font(.headline)
        case .rule: Divider()
        case .bullet(let s):
            HStack(alignment: .top, spacing: 6) {
                Text("\u{2022}").font(.body)
                inlineText(s).font(.body)
            }
        case .body(let s): inlineText(s).font(.body)
        }
    }

    var body: some View {
        let blocks = parseBlocks()
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks.indices, id: \.self) { i in
                renderBlock(blocks[i])
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Word Learning Card

struct WordExplanation: Codable, Identifiable {
    var id: String { word }
    let word: String
    let phonetic: String?
    let pos: String
    let definition_source: String
    let definition_target: String
    let context_usage: String
    let sentence_source: String?
    let sentence_target: String
    let example_source: String
    let example_target: String
    let collocations: [String]
}

struct LearningResponse: Codable {
    let words: [WordExplanation]?
    let sentences: [SentenceExplanation]?
}

struct SentenceExplanation: Codable, Identifiable {
    var id: String { sentence }
    let sentence: String
    let translation: String
    let structure: String
    let grammar_points: [String]
    let key_phrases: [KeyPhrase]
    let summary: String

    struct KeyPhrase: Codable {
        let phrase: String
        let meaning: String
    }
}

struct WordCardListView: View {
    let explanations: [WordExplanation]
    var sentenceExplanations: [SentenceExplanation] = []
    var onDeleteWord: ((String) -> Void)? = nil
    var onDeleteSentence: ((String) -> Void)? = nil

    private var sortedExplanations: [WordExplanation] {
        explanations.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sentenceExplanations) { item in
                SentenceCardView(explanation: item, onDelete: onDeleteSentence)
                    .id(item.sentence.lowercased())
                    .transition(.opacity)
            }
            ForEach(Array(sortedExplanations.enumerated()), id: \.offset) { index, item in
                WordCardView(explanation: item, onDelete: onDeleteWord)
                    .id(item.word.lowercased())
                    .transition(.opacity)
            }
        }
    }
}

private let sharedSpeechSynthesizer = NSSpeechSynthesizer()

struct WordCardView: View {
    let explanation: WordExplanation
    var onDelete: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Word + Phonetic + POS + Speak + Delete
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(width: 4, height: 22)
                Text(explanation.word)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.orange)
                if let phonetic = explanation.phonetic, !phonetic.isEmpty {
                    Text(phonetic)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(explanation.pos.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button {
                    sharedSpeechSynthesizer.stopSpeaking()
                    sharedSpeechSynthesizer.startSpeaking(explanation.word)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
                Spacer()
                if let onDelete {
                    Button { onDelete(explanation.word.lowercased()) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)

            // Definitions
            Text(explanation.definition_source)
                .font(.system(size: 14))
                .lineSpacing(2)

            Text(explanation.definition_target)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Context block
            if !explanation.context_usage.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("IN CONTEXT")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.orange)
                        .textCase(.uppercase)

                    Text(explanation.context_usage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .italic()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Original sentence from transcript + translation
            if !explanation.sentence_target.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        if let en = explanation.sentence_source, !en.isEmpty {
                            Text(en)
                                .font(.system(size: 13))
                        }
                        Text(explanation.sentence_target)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // Example block
            if !explanation.example_source.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .padding(.vertical, 4)

                    Text(explanation.example_source)
                        .font(.system(size: 13))
                        .lineSpacing(1.5)

                    Text(explanation.example_target)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            // Collocations (optional)
            if !explanation.collocations.isEmpty {
                WordFlowLayout(spacing: 6) {
                    ForEach(explanation.collocations.prefix(5), id: \.self) { col in
                        Text(col)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

struct SentenceCardView: View {
    let explanation: SentenceExplanation
    var onDelete: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue)
                    .frame(width: 4, height: 22)
                Text("SENTENCE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
                if let onDelete {
                    Button { onDelete(explanation.sentence.lowercased()) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)

            // Original sentence
            Text(explanation.sentence)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(2)

            // Translation
            Text(explanation.translation)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            // Structure analysis
            if !explanation.structure.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STRUCTURE")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.blue)
                    Text(explanation.structure)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Grammar points
            if !explanation.grammar_points.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GRAMMAR")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.blue)
                    ForEach(explanation.grammar_points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(point)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Key phrases
            if !explanation.key_phrases.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(explanation.key_phrases, id: \.phrase) { kp in
                    HStack(alignment: .top, spacing: 8) {
                        Text(kp.phrase)
                            .font(.system(size: 13, weight: .medium))
                        Text(kp.meaning)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Summary
            if !explanation.summary.isEmpty {
                Text(explanation.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

/// Displays plain text as individually tappable words for vocabulary learning.
// Preference key for tracking word positions during drag
private struct WordFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

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
        WordFlowLayout(spacing: usesNLTokenizer ? 0 : 4) {
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

    /// Split trailing punctuation from a token: "undertaking." → ("undertaking", ".")
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
        .font(.title3)
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
