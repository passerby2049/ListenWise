/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The transcript view — learning interface.
*/

import Foundation
import SwiftUI
import AVFoundation


struct TranscriptView: View {
    @Binding var story: Story
    @Environment(AppPreferences.self) var preferences
    @State var vm: TranscriptViewModel
    @State var speechTranscriber: SpokenWordTranscriber
    @StateObject var liveTranscriber = LiveTranscriber()

    // Sheet presentation states (must stay on View for SwiftUI modifiers)
    @State var isImporting = false
    @State var isTranscribingFile = false
    @State var isShowingYouTubeDownload = false
    @State var isShowingLiveStreamInput = false
    @State var liveStreamURLText = ""
    @State var youtubeDownloadedURL: URL?

    init(story: Binding<Story>) {
        self._story = story
        self._vm = State(initialValue: TranscriptViewModel(story: story.wrappedValue))
        self.speechTranscriber = SpokenWordTranscriber(story: story)
    }

    var body: some View {
        @Bindable var vm = vm
        Group {
            if isTranscribingFile {
                transcribingView
            } else if story.isDone {
                mainLearningStage
            } else {
                importPromptView
            }
        }
        .inspector(isPresented: $vm.showingInspector) {
            inspectorPanelView
                .inspectorColumnWidth(min: 420, ideal: 450, max: 600)
        }
        .navigationTitle(story.title)
        .toolbar { toolbarContent }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: story.isDone) { _, isDone in
            if isDone {
                vm.setupPlayer()
            }
        }
        .onAppear {
            vm.setupPlayer()
            vm.loadSubtitleCards()
            vm.restoreSavedState()
            if story.isLiveStream && !story.savedLiveSegments.isEmpty {
                liveTranscriber.segments = story.savedLiveSegments
                liveTranscriber.confirmedText = story.savedLiveSegments.map(\.source).joined(separator: "\n")
            }
        }
        .onDisappear {
            vm.saveLiveSegments(liveTranscriber: liveTranscriber)
            vm.cleanup()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                vm.story.title = url.deletingPathExtension().lastPathComponent
                isTranscribingFile = true
                let accessing = url.startAccessingSecurityScopedResource()
                if accessing { vm.securityScopedURL = url }
                speechTranscriber.recognitionLocale = SupportedLanguages.locale(for: story.sourceLanguage) ?? SpokenWordTranscriber.defaultLocale
                Task {
                    do { try await speechTranscriber.transcribeFile(url, engineID: preferences.selectedTranscriptionEngine) }
                    catch { print("could not transcribe file: \(error)") }
                    vm.handleTranscriptionComplete()
                    isTranscribingFile = false
                }
            case .failure(let error):
                print("file import failed: \(error)")
            }
        }
        .sheet(isPresented: $isShowingYouTubeDownload) {
            YouTubeDownloadView(downloadedURL: $youtubeDownloadedURL, youtubeSourceURL: $story.youtubeURL, youtubeStreamingURL: $story.youtubeStreamingURL)
        }
        .onChange(of: youtubeDownloadedURL) { _, newURL in
            guard let url = newURL else { return }
            vm.story.title = url.deletingPathExtension().lastPathComponent
            isTranscribingFile = true
            speechTranscriber.recognitionLocale = SupportedLanguages.locale(for: story.sourceLanguage) ?? SpokenWordTranscriber.defaultLocale
            Task {
                do { try await speechTranscriber.transcribeFile(url, engineID: preferences.selectedTranscriptionEngine) }
                catch { print("could not transcribe file: \(error)") }
                vm.handleTranscriptionComplete()
                isTranscribingFile = false
                if !story.youtubeURL.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { vm.exportStory() } label: {
                Label("Export Notes", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(!story.isDone)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { vm.showingInspector.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(vm.showingInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    // MARK: - Import Prompt (no file yet)

    @ViewBuilder
    var importPromptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Import an audio or video file")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source Language").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $story.sourceLanguage) {
                        ForEach(SupportedLanguages.source) { lang in Text(lang.displayName).tag(lang.id) }
                    }.frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target Language").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $story.targetLanguage) {
                        ForEach(SupportedLanguages.target) { lang in Text(lang.displayName).tag(lang.id) }
                    }.frame(width: 180)
                }
            }

            HStack(spacing: 12) {
                Button { isImporting = true } label: {
                    Label("Import File", systemImage: "folder")
                }.buttonStyle(.borderedProminent).controlSize(.large)

                Button { isShowingYouTubeDownload = true } label: {
                    Label("YouTube", systemImage: "play.rectangle")
                }.buttonStyle(.bordered).controlSize(.large)

                Button { isShowingLiveStreamInput = true } label: {
                    Label("Live", systemImage: "antenna.radiowaves.left.and.right")
                }.buttonStyle(.bordered).controlSize(.large).tint(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingLiveStreamInput) {
            liveStreamInputSheet
        }
    }

    // MARK: - Transcribing View

    @ViewBuilder
    var transcribingView: some View {
        VStack(spacing: 20) {
            Spacer()
            if speechTranscriber.isPreparing {
                ProgressView(value: speechTranscriber.preparationProgress) {
                    Text("Preparing model...").font(.title3.bold())
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)
                Text("\(Int(speechTranscriber.preparationProgress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().scaleEffect(1.5)
                Text("Transcribing file...").font(.title3.bold())
            }
            Text("Engine: \(preferences.selectedTranscriptionEngine.displayName)")
                .font(.caption).foregroundStyle(.secondary)
            if let url = story.url {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            if speechTranscriber.finalizedLineCount > 0 {
                Text("\(speechTranscriber.finalizedLineCount) segments transcribed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !speechTranscriber.volatileTranscript.characters.isEmpty {
                Text(speechTranscriber.volatileTranscript)
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video Learning View (Left-Right Split)

    @ViewBuilder
    var videoPlayerWithSubtitle: some View {
        @Bindable var vm = vm
        ZStack {
            if let vid = vm.youtubeVideoID {
                YouTubeEmbedPlayer(videoID: vid, onTimeUpdate: { time in
                    vm.updateSubtitleFromYouTube(time: time)
                }, onWebViewReady: { webView in
                    vm.youtubeWebView = webView
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            } else if let p = vm.player {
                NativeVideoPlayer(player: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Subtitle text
            if liveTranscriber.isRunning, let last = liveTranscriber.segments.last {
                SubtitleOverlay(source: last.source, translation: last.translation)
            } else if vm.showSubtitle {
                let src: String = {
                    switch vm.subtitleMode {
                    case .source, .both: return vm.currentSubtitleText
                    case .target: return ""
                    }
                }()
                let tgt: String = {
                    switch vm.subtitleMode {
                    case .source: return ""
                    case .target, .both: return vm.currentSubtitleTranslation
                    }
                }()
                if !src.isEmpty || !tgt.isEmpty {
                    SubtitleOverlay(source: src, translation: tgt)
                }
            }

            // Subtitle mode button — top-right corner
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if !vm.showSubtitle {
                                vm.showSubtitle = true
                                vm.subtitleMode = .source
                            } else {
                                switch vm.subtitleMode {
                                case .source: vm.subtitleMode = .target
                                case .target: vm.subtitleMode = .both
                                case .both: vm.showSubtitle = false
                                }
                            }
                        }
                    } label: {
                        let modeLabel: String = {
                            guard vm.showSubtitle else { return "OFF" }
                            switch vm.subtitleMode {
                            case .source: return story.sourceLanguage.prefix(2).uppercased()
                            case .target:
                                return story.targetLanguage == "中文" ? "ZH" : story.targetLanguage.prefix(2).uppercased()
                            case .both: return "2x"
                            }
                        }()
                        HStack(spacing: 4) {
                            Image(systemName: vm.showSubtitle ? "captions.bubble.fill" : "captions.bubble")
                                .font(.system(size: 16, weight: .medium))
                            Text(modeLabel)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(vm.showSubtitle ? preferences.accentColor : Color.white.opacity(0.9))
                        .frame(height: 36)
                        .padding(.horizontal, 12)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.3))
                                .background(.ultraThinMaterial)
                        )
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .padding(.top, 12)
                }
                Spacer()
            }
        }
    }

    // MARK: - Unified Main Learning Stage

    @ViewBuilder
    var mainLearningStage: some View {
        VStack(spacing: 0) {
            if vm.sourceIsVideo {
                videoPlayerWithSubtitle
                    .frame(height: vm.videoHeight)
                    .clipped()

                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                if !vm.isDraggingVideo {
                                    vm.isDraggingVideo = true
                                    vm.dragStartY = value.startLocation.y
                                    vm.dragStartHeight = vm.videoHeight
                                }
                                let delta = value.location.y - vm.dragStartY
                                vm.videoHeight = min(max(vm.dragStartHeight + delta, 150), 600)
                            }
                            .onEnded { _ in vm.isDraggingVideo = false }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 36, height: 3)
                    )
            } else {
                audioPlayerBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
            }

            if vm.isLiveMode {
                liveTranscriptArea
            } else {
                normalTranscriptArea
            }
        }
    }

    // MARK: - Audio Player Bar

    @ViewBuilder
    var audioPlayerBar: some View {
        @Bindable var vm = vm
        HStack(spacing: 12) {
            Button(action: { vm.togglePlayback() }) {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Slider(value: $vm.currentPlaybackTime, in: 0...max(vm.duration, 1)) { editing in
                if !editing { vm.seek(to: vm.currentPlaybackTime) }
            }

            Text(vm.timeString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

}
