/*
Abstract:
TranscriptView extension — inspector panel (vocabulary + chat sidebar).
*/

import SwiftUI

extension TranscriptView {

    // MARK: - Inspector Panel (Right Sidebar)

    @ViewBuilder
    var inspectorPanelView: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: vm.inspectorTab == tab ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(vm.inspectorTab == tab ? Color.secondary.opacity(0.3) : Color.clear))
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { vm.inspectorTab = tab }
                        }
                        .foregroundStyle(vm.inspectorTab == tab ? Color.primary : Color.secondary)
                }
            }
            .padding(2)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            if vm.inspectorTab == .vocab {
                vocabHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        vocabCards.padding(20)
                    }
                    .onChange(of: vm.vocabScrollTarget) { _, target in
                        if let target {
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                            vm.vocabScrollTarget = nil
                        }
                    }
                }
            } else {
                ScrollView {
                    chatView.padding(20)
                }
                Divider()
                chatInputBar
                    .padding(12)
                    .background(.regularMaterial)
            }
        }
        .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
    }

    // MARK: - Vocabulary Header

    @ViewBuilder
    var vocabHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.isReorganizing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(vm.reorganizeProgress.isEmpty ? "Waiting for model response..." : "Reorganizing transcript...")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    if !vm.reorganizeProgress.isEmpty {
                        Text(vm.reorganizeProgress)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(5)
                            .padding(10)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider()
            }

            if !vm.markedWords.isEmpty || vm.isLoadingWordHelp || !vm.wordExplanations.isEmpty || !vm.wordLearningResponse.isEmpty {
                HStack(alignment: .center) {
                    Text("\(vm.markedWords.count) ITEMS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).kerning(0.5)
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                vm.clearAllMarkedWords()
                                vm.wordLearningResponse = ""
                                vm.wordExplanations = []
                                vm.sentenceExplanations = []
                                vm.saveLearnProgress()
                            }
                        } label: {
                            Text("Clear").font(.system(size: 12))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(vm.isLoadingWordHelp)

                        if vm.isLoadingWordHelp {
                            Button {
                                vm.wordHelpTask?.cancel()
                                vm.isLoadingWordHelp = false
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.8))
                                    .foregroundStyle(.white).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        } else {
                            let newWords = vm.markedWords.subtracting(vm.queriedWords)
                            Button {
                                vm.startWordHelp()
                            } label: {
                                Label(newWords.isEmpty ? "Ask AI" : "Ask (\(newWords.count) new)", systemImage: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(preferences.accentColor)
                                    .foregroundStyle(.white).clipShape(Capsule())
                            }
                            .buttonStyle(.plain).disabled(newWords.isEmpty)
                        }
                    }
                }

                if !vm.markedWords.isEmpty {
                    ScrollView {
                        WordFlowLayout(spacing: 6) {
                            ForEach(vm.markedWords.sorted(), id: \.self) { word in
                                WordChipView(word: word, onTap: {
                                    vm.vocabScrollTarget = word
                                }, onRemove: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        vm.removeMarkedWord(word)
                                        vm.wordExplanations.removeAll { $0.word.lowercased() == word }
                                        vm.sentenceExplanations.removeAll { $0.sentence.lowercased() == word }
                                        vm.saveLearnProgress()
                                    }
                                })
                            }
                        }
                    }
                    .frame(maxHeight: 150, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    var vocabCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.markedWords.isEmpty && !vm.isLoadingWordHelp && vm.wordExplanations.isEmpty && vm.sentenceExplanations.isEmpty && vm.wordLearningResponse.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "text.word.spacing")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text("Click a word to add it.\nDrag across words to select a phrase.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if vm.isLoadingWordHelp && !vm.wordLearningResponse.isEmpty {
                Text(vm.wordLearningResponse)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12).background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !vm.wordExplanations.isEmpty || !vm.sentenceExplanations.isEmpty {
                WordCardListView(
                    explanations: vm.wordExplanations,
                    sentenceExplanations: vm.sentenceExplanations,
                    globalOnlyWords: vm.globalOnlyWords,
                    onDeleteWord: { word in
                        vm.wordExplanations.removeAll { $0.word.lowercased() == word }
                        vm.removeMarkedWord(word)
                        vm.rebuildWordLearningResponse()
                        vm.saveLearnProgress()
                    },
                    onDeleteSentence: { sentence in
                        vm.sentenceExplanations.removeAll { $0.sentence.lowercased() == sentence }
                        vm.removeMarkedWord(sentence)
                        vm.rebuildSentenceLearningResponse()
                        vm.saveLearnProgress()
                    },
                    onRefreshWord: { word in
                        vm.refreshWord(word)
                    }
                )
            } else if !vm.wordLearningResponse.isEmpty && !vm.isLoadingWordHelp {
                MarkdownView(markdown: vm.wordLearningResponse)
                    .padding(16).background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Chat View

    @ViewBuilder
    var chatView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHAT").font(.caption.bold()).foregroundStyle(.secondary)
            if !vm.chatMessages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.chatMessages.indices, id: \.self) { i in
                        let msg = vm.chatMessages[i]
                        HStack(alignment: .top, spacing: 8) {
                            if msg.role == "user" {
                                Spacer(minLength: 40)
                                Text(msg.content).font(.callout)
                                    .padding(10)
                                    .background(preferences.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    MarkdownView(markdown: msg.content)
                                }
                                .padding(10).background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .textSelection(.enabled)
                                Spacer(minLength: 40)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var chatInputBar: some View {
        @Bindable var vm = vm
        HStack(spacing: 12) {
            TextField("Ask anything about this content...", text: $vm.chatInput, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).font(.body)
                .onSubmit {
                    if !vm.chatInput.isEmpty && !vm.isChatting {
                        vm.startChat()
                    }
                }
            if vm.isChatting {
                Button {
                    vm.chatTask?.cancel()
                    vm.isChatting = false
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
                }.buttonStyle(.plain)
            } else {
                Button {
                    vm.startChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                        .foregroundStyle(
                            vm.chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.gray.opacity(0.4) : preferences.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        )
    }
}
