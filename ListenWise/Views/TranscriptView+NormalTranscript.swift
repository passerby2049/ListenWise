/*
Abstract:
TranscriptView extension — normal mode transcript area (tabs, reorganize, line rendering).
*/

import SwiftUI
import AppKit

extension TranscriptView {

    // MARK: - Normal Transcript Area

    var normalTranscriptArea: some View {
        VStack(spacing: 0) {
            // Control bar: tabs + reorganize + copy
            HStack(spacing: 12) {
                Spacer()

                // Original / Bilingual toggle
                HStack(spacing: 2) {
                    ForEach(TranscriptTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { transcriptTab = tab }
                            if let idx = currentLineIndex {
                                let saved = idx
                                currentLineIndex = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    currentLineIndex = saved
                                }
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: transcriptTab == tab ? .semibold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(
                                    transcriptTab == tab
                                        ? AnyShapeStyle(.background)
                                        : AnyShapeStyle(.clear)
                                )
                                .clipShape(Capsule())
                                .shadow(color: transcriptTab == tab ? Color.black.opacity(0.1) : .clear, radius: 1, y: 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(transcriptTab == tab ? .primary : .secondary)
                        .disabled(tab == .bilingual && !showReorganized)
                        .opacity(tab == .bilingual && !showReorganized ? 0.4 : 1)
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())

                Divider().frame(height: 18)

                // Raw / AI Reorganized toggle
                HStack(spacing: 2) {
                    ForEach([(false, "Raw"), (true, "AI Reorganized")], id: \.0) { value, label in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showReorganized = value
                                if !value && transcriptTab == .bilingual {
                                    transcriptTab = .original
                                }
                                if value && reorganizedCards.isEmpty && !isReorganizing {
                                    fixTask = Task { await reorganizeTranscript() }
                                }
                                if let idx = currentLineIndex {
                                    let saved = idx
                                    currentLineIndex = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        currentLineIndex = saved
                                    }
                                }
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 11, weight: showReorganized == value ? .semibold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(
                                    showReorganized == value
                                        ? AnyShapeStyle(.background)
                                        : AnyShapeStyle(.clear)
                                )
                                .clipShape(Capsule())
                                .shadow(color: showReorganized == value ? Color.black.opacity(0.1) : .clear, radius: 1, y: 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(showReorganized == value ? .primary : .secondary)
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())
                .disabled(!story.isDone)

                // AI Reorganize button
                if isReorganizing {
                    Button {
                        fixTask?.cancel()
                        isReorganizing = false
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Capsule())
                } else {
                    Button {
                        fixTask = Task { await reorganizeTranscript() }
                    } label: {
                        Label("AI Reorganize", systemImage: "wand.and.stars")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(preferences.accentColor)
                    .clipShape(Capsule())
                    .disabled(!story.isDone || cachedSubtitleCards.isEmpty)
                    .help("AI Reorganize — merge fragments into proper sentences")
                }

                // Copy transcript text
                Button {
                    let text: String
                    if showReorganized && !reorganizedCards.isEmpty {
                        text = reorganizedCards.map(\.text).joined(separator: "\n")
                    } else {
                        text = cachedSubtitleCards.map(\.text).joined(separator: "\n")
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())
                .disabled(cachedSubtitleCards.isEmpty)
                .help("Copy transcript text")

                Spacer()
            }
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    if transcriptTab == .original {
                        transcriptTextView(proxy: proxy)
                            .padding(20)
                    } else {
                        translationTextView(proxy: proxy)
                            .padding(20)
                    }
                }
                .clipped()
            }
        }
        .onChange(of: transcriptTab) { _, newTab in
            if newTab == .bilingual && translationPairs.isEmpty && !isTranslatingLines {
                Task { await translateByLines() }
            }
        }
    }

    // MARK: - Translation Text View (Bilingual Tab)

    @ViewBuilder
    func translationTextView(proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if showReorganized && !reorganizedCards.isEmpty {
                let hasTranslation = reorganizedCards.contains { !$0.translation.isEmpty }
                if !hasTranslation {
                    HStack {
                        Text("Reorganize with translation first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            reorganizedCards = []
                            fixTask = Task { await reorganizeTranscript() }
                        } label: {
                            Label("Reorganize", systemImage: "wand.and.stars")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                let active = currentLineIndex
                ForEach(reorganizedCards.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 16) {
                        timestampButton(index: i, isActive: i == active, startTime: reorganizedCards[i].start)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) {
                            WordFlowView(text: reorganizedCards[i].text, markedWords: $markedWords, isActive: i == active)
                                .font(.system(size: 18))
                            if !reorganizedCards[i].translation.isEmpty {
                                Text(reorganizedCards[i].translation)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .opacity(i == active ? 1 : 0.7)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(i == active ? .primary : .secondary)
                    .id("tr_\(i)")
                }
                .onChange(of: active) { _, newIndex in
                    guard let idx = newIndex else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("tr_\(idx)", anchor: .center)
                    }
                }
            } else if isTranslatingLines {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Translating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !translationPairs.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        translationPairs = []
                        translatedText = ""
                        translateTask = Task { await translateByLines() }
                    } label: {
                        Label("Retranslate", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ForEach(translationPairs.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        WordFlowView(text: translationPairs[i].source, markedWords: $markedWords)
                            .font(.body)
                        Text(translationPairs[i].target)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Reorganize first to get translation with timestamps")
                        .foregroundStyle(.tertiary)
                    Button {
                        fixTask = Task { await reorganizeTranscript() }
                        transcriptTab = .original
                    } label: {
                        Label("Reorganize", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            }
        }
    }

    // MARK: - Display Lines & Helpers

    var displayLines: [String] {
        let cards = activeSubtitleCards
        if !cards.isEmpty {
            return cards.map { $0.text }
        }
        return splitIntoSentences(String(story.text.characters))
    }

    func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
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

    @ViewBuilder
    func timestampButton(index: Int, isActive: Bool, startTime: Double) -> some View {
        Button {
            seekToLine(index)
        } label: {
            let m = Int(startTime) / 60
            let s = Int(startTime) % 60
            Text(String(format: "%d:%02d", m, s))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? preferences.accentColor : Color.gray)
                .frame(width: 32, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func transcriptLine(index: Int, text: String, isActive: Bool, hasTimestamp: Bool, startTime: Double) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if hasTimestamp {
                timestampButton(index: index, isActive: isActive, startTime: startTime)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                WordFlowView(text: text, markedWords: $markedWords, isActive: isActive)
                    .font(.system(size: 18))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isActive ? .primary : .secondary)
        .id(index)
    }

    @ViewBuilder
    func transcriptTextView(proxy: ScrollViewProxy) -> some View {
        let lines = displayLines
        let active = currentLineIndex
        let cards = activeSubtitleCards
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { i in
                transcriptLine(
                    index: i,
                    text: lines[i],
                    isActive: i == active,
                    hasTimestamp: i < cards.count,
                    startTime: i < cards.count ? cards[i].start : 0
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: active) { _, newIndex in
            guard let idx = newIndex else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }
}
