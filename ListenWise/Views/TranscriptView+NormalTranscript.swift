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
                            withAnimation(.easeInOut(duration: 0.2)) { vm.transcriptTab = tab }
                            refreshCurrentLineIndex()
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: vm.transcriptTab == tab ? .semibold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(
                                    vm.transcriptTab == tab
                                        ? AnyShapeStyle(.background)
                                        : AnyShapeStyle(.clear)
                                )
                                .clipShape(Capsule())
                                .shadow(color: vm.transcriptTab == tab ? Color.black.opacity(0.1) : .clear, radius: 1, y: 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(vm.transcriptTab == tab ? .primary : .secondary)
                        .disabled(tab == .bilingual && !vm.showReorganized)
                        .opacity(tab == .bilingual && !vm.showReorganized ? 0.4 : 1)
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
                                vm.showReorganized = value
                                if !value && vm.transcriptTab == .bilingual {
                                    vm.transcriptTab = .original
                                }
                                if value && vm.reorganizedCards.isEmpty && !vm.isReorganizing {
                                    vm.startReorganize()
                                }
                                refreshCurrentLineIndex()
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 11, weight: vm.showReorganized == value ? .semibold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(
                                    vm.showReorganized == value
                                        ? AnyShapeStyle(.background)
                                        : AnyShapeStyle(.clear)
                                )
                                .clipShape(Capsule())
                                .shadow(color: vm.showReorganized == value ? Color.black.opacity(0.1) : .clear, radius: 1, y: 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(vm.showReorganized == value ? .primary : .secondary)
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())
                .disabled(!story.isDone)

                // AI Reorganize button
                if vm.isReorganizing {
                    Button {
                        vm.reorganizeTask?.cancel()
                        vm.isReorganizing = false
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
                        vm.startReorganize()
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
                    .disabled(!story.isDone || vm.cachedSubtitleCards.isEmpty)
                    .help("AI Reorganize — merge fragments into proper sentences")
                }

                // Copy transcript text
                Button {
                    let text: String
                    if vm.showReorganized && !vm.reorganizedCards.isEmpty {
                        text = vm.reorganizedCards.map(\.text).joined(separator: "\n")
                    } else {
                        text = vm.cachedSubtitleCards.map(\.text).joined(separator: "\n")
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
                .disabled(vm.cachedSubtitleCards.isEmpty)
                .help("Copy transcript text")

                Spacer()
            }
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    if vm.transcriptTab == .original {
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
        .onChange(of: vm.transcriptTab) { _, newTab in
            if newTab == .bilingual && vm.translationPairs.isEmpty && !vm.isTranslatingLines {
                vm.startTranslate()
            }
        }
    }

    // Nudge the highlighted line so dependent views re-render after a tab switch.
    private func refreshCurrentLineIndex() {
        guard let idx = vm.currentLineIndex else { return }
        vm.currentLineIndex = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            vm.currentLineIndex = idx
        }
    }

    // MARK: - Translation Text View (Bilingual Tab)

    @ViewBuilder
    func translationTextView(proxy: ScrollViewProxy) -> some View {
        @Bindable var vm = vm
        LazyVStack(alignment: .leading, spacing: 16) {
            if vm.showReorganized && !vm.reorganizedCards.isEmpty {
                let hasTranslation = vm.reorganizedCards.contains { !$0.translation.isEmpty }
                if !hasTranslation {
                    HStack {
                        Text("Reorganize with translation first")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            vm.reorganizedCards = []
                            vm.startReorganize()
                        } label: {
                            Label("Reorganize", systemImage: "wand.and.stars").font(.caption)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }

                let active = vm.currentLineIndex
                ForEach(vm.reorganizedCards.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 16) {
                        timestampButton(index: i, isActive: i == active, startTime: vm.reorganizedCards[i].start)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) {
                            WordFlowView(
                                text: vm.reorganizedCards[i].text,
                                markedWords: $vm.markedWords,
                                isActive: i == active,
                                onMark: { [vm, text = vm.reorganizedCards[i].text] key in
                                    vm.markedWordOrigins[key] = text
                                }
                            )
                                .font(.system(size: 18))
                            if !vm.reorganizedCards[i].translation.isEmpty {
                                Text(vm.reorganizedCards[i].translation)
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
            } else if vm.isTranslatingLines {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Translating...").font(.caption).foregroundStyle(.secondary)
                }
            } else if !vm.translationPairs.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        vm.translationPairs = []
                        vm.translatedText = ""
                        vm.startTranslate()
                    } label: {
                        Label("Retranslate", systemImage: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                ForEach(vm.translationPairs.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        WordFlowView(
                            text: vm.translationPairs[i].source,
                            markedWords: $vm.markedWords,
                            onMark: { [vm, text = vm.translationPairs[i].source] key in
                                vm.markedWordOrigins[key] = text
                            }
                        )
                            .font(.body)
                        Text(vm.translationPairs[i].target)
                            .font(.body).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Reorganize first to get translation with timestamps")
                        .foregroundStyle(.tertiary)
                    Button {
                        vm.startReorganize()
                        vm.transcriptTab = .original
                    } label: {
                        Label("Reorganize", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    func timestampButton(index: Int, isActive: Bool, startTime: Double) -> some View {
        Button {
            vm.seekToLine(index)
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
        @Bindable var vm = vm
        HStack(alignment: .top, spacing: 16) {
            if hasTimestamp {
                timestampButton(index: index, isActive: isActive, startTime: startTime)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                WordFlowView(
                    text: text,
                    markedWords: $vm.markedWords,
                    isActive: isActive,
                    onMark: { [vm] key in vm.markedWordOrigins[key] = text }
                )
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
        let lines = vm.displayLines
        let active = vm.currentLineIndex
        let cards = vm.activeSubtitleCards
        LazyVStack(alignment: .leading, spacing: 4) {
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
