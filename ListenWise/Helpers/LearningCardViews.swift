/*
Abstract:
UI components for vocabulary learning — word cards, sentence cards, chips, markdown renderer.
*/

import SwiftUI

// MARK: - Word Chip View (hover to reveal x)

struct WordChipView: View {
    let word: String
    var onTap: () -> Void
    var onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Invisible sizer — always text + x to fix chip width
            HStack(spacing: 4) {
                Text(word).font(.callout)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .opacity(0)

            // Visible: text centered, or text + x when hovered
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

// MARK: - Learning Data Models

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

// MARK: - Word Card List

struct WordCardListView: View {
    let explanations: [WordExplanation]
    var sentenceExplanations: [SentenceExplanation] = []
    var globalOnlyWords: Set<String> = []
    var onDeleteWord: ((String) -> Void)? = nil
    var onDeleteSentence: ((String) -> Void)? = nil
    var onRefreshWord: ((String) -> Void)? = nil

    private var sortedExplanations: [WordExplanation] {
        explanations.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sentenceExplanations) { item in
                SentenceCardView(
                    explanation: item,
                    isGlobal: globalOnlyWords.contains(item.sentence.lowercased()),
                    onDelete: { word in
                        withAnimation(.easeInOut(duration: 0.25)) { onDeleteSentence?(word) }
                    },
                    onRefresh: { word in
                        withAnimation(.easeInOut(duration: 0.25)) { onRefreshWord?(word) }
                    }
                )
                .id(item.sentence.lowercased())
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            }
            ForEach(sortedExplanations) { item in
                WordCardView(
                    explanation: item,
                    isGlobal: globalOnlyWords.contains(item.word.lowercased()),
                    onDelete: { word in
                        withAnimation(.easeInOut(duration: 0.25)) { onDeleteWord?(word) }
                    },
                    onRefresh: { word in
                        withAnimation(.easeInOut(duration: 0.25)) { onRefreshWord?(word) }
                    }
                )
                .id(item.word.lowercased())
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: explanations.map(\.word))
        .animation(.easeInOut(duration: 0.25), value: sentenceExplanations.map(\.sentence))
    }
}

// MARK: - Card Action Button (hover effect)

struct CardActionButton: View {
    let icon: String
    let hoverColor: Color
    let action: () -> Void
    var help: String = ""
    var rotationAngle: Double = 0

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? hoverColor : .secondary)
                .rotationEffect(.degrees(isHovered ? rotationAngle : 0))
                .frame(width: 24, height: 24)
                .background(isHovered ? hoverColor.opacity(0.12) : .clear)
                .clipShape(Circle())
                .scaleEffect(isHovered ? 1.15 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
        }
        .help(help)
    }
}

// MARK: - Word Card

struct WordCardView: View {
    let explanation: WordExplanation
    var isGlobal: Bool = false
    var onDelete: ((String) -> Void)? = nil
    var onRefresh: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Word + Phonetic + POS + Speak + Refresh + Delete
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
                SpeakerButton(text: explanation.word, size: 12)
                Spacer()
                if let onRefresh {
                    CardActionButton(icon: "arrow.clockwise", hoverColor: .orange, action: { onRefresh(explanation.word.lowercased()) }, help: "Refresh with current context", rotationAngle: 360)
                }
                if let onDelete {
                    CardActionButton(icon: "xmark", hoverColor: .red, action: { onDelete(explanation.word.lowercased()) }, help: "Remove", rotationAngle: 90)
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

            // Context block — hide when from global vocab
            if !isGlobal && !explanation.context_usage.isEmpty {
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

            // Original sentence from transcript — hide when from global vocab
            if !isGlobal && !explanation.sentence_target.isEmpty {
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

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(explanation.example_source)
                            .font(.system(size: 13))
                            .lineSpacing(1.5)
                        SpeakerButton(text: explanation.example_source)
                    }

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
                .stroke(isGlobal ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

// MARK: - Sentence Card

struct SentenceCardView: View {
    let explanation: SentenceExplanation
    var isGlobal: Bool = false
    var onDelete: ((String) -> Void)? = nil
    var onRefresh: ((String) -> Void)? = nil

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
                if let onRefresh {
                    CardActionButton(icon: "arrow.clockwise", hoverColor: .blue, action: { onRefresh(explanation.sentence.lowercased()) }, help: "Refresh with current context", rotationAngle: 360)
                }
                if let onDelete {
                    CardActionButton(icon: "xmark", hoverColor: .red, action: { onDelete(explanation.sentence.lowercased()) }, help: "Remove", rotationAngle: 90)
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
