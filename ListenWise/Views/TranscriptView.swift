/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The transcript view — learning interface.
*/

import Foundation
import SwiftUI
import Speech
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import WebKit


// MARK: - YouTube Embed Player (WKWebView)

struct YouTubeEmbedPlayer: NSViewRepresentable {
    let videoID: String
    var onTimeUpdate: ((Double) -> Void)?
    var onWebViewReady: ((WKWebView) -> Void)?

    class Coordinator: NSObject, WKNavigationDelegate {
        var onTimeUpdate: ((Double) -> Void)?
        var timer: Timer?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Start polling YouTube player currentTime for subtitle sync
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                webView.evaluateJavaScript("document.querySelector('video')?.currentTime ?? -1") { result, _ in
                    if let time = result as? Double, time >= 0 {
                        self?.onTimeUpdate?(time)
                    }
                }
            }
        }

        deinit { timer?.invalidate() }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onTimeUpdate = onTimeUpdate
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        // Minimal CSS: hide YouTube chrome, force #movie_player to fill the viewport
        let jsSource = """
        (function() {
            // Force dark theme attribute
            document.documentElement.setAttribute('dark', '');
            var css = `
                html, body, ytd-app, #content, #page-manager, ytd-watch-flexy,
                #columns, #primary, #primary-inner {
                    margin:0!important; padding:0!important; overflow:hidden!important;
                    background:#000!important; background-color:#000!important;
                }
                #masthead-container, #secondary, #below, #comments, #related,
                ytd-masthead, #guide, tp-yt-app-drawer, ytd-mini-guide-renderer,
                ytd-popup-container, #clarify-box, #panels, #ticker,
                .ytp-paid-content-overlay, .ytp-chrome-top,
                .ytp-cards-button, .ytp-ce-element { display:none!important; }
                #movie_player, .html5-video-player {
                    position:fixed!important; top:0!important; left:0!important;
                    width:100vw!important; height:100vh!important;
                    z-index:99999!important; background:#000!important;
                }
                .html5-video-container, video {
                    position:absolute!important; left:0!important; top:0!important;
                    width:100%!important; height:100%!important;
                }
                video { object-fit:contain!important; }
                .ytp-chrome-bottom { opacity:0!important; transition:opacity .3s!important; }
                .html5-video-player:hover .ytp-chrome-bottom { opacity:1!important; }
            `;
            function apply() {
                if (!document.getElementById('yt-clean')) {
                    var s = document.createElement('style');
                    s.id = 'yt-clean';
                    s.textContent = css;
                    (document.head || document.documentElement).appendChild(s);
                }
            }
            apply();
            new MutationObserver(apply).observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: jsSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .black
        webView.setValue(false, forKey: "drawsBackground")  // Prevent white flash in light mode
        webView.navigationDelegate = context.coordinator

        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        webView.load(URLRequest(url: watchURL))
        DispatchQueue.main.async { onWebViewReady?(webView) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Native AVPlayerView with fullscreen button

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct TranscriptView: View {
    @Binding var story: Story
    @Environment(AppPreferences.self) var preferences
    @State var isImporting = false
    @State var isTranscribingFile = false
    @State var isShowingYouTubeDownload = false
    @State var isShowingLiveStreamInput = false
    @State var liveStreamURLText = ""
    @State var youtubeDownloadedURL: URL?
    @State var speechTranscriber: SpokenWordTranscriber

    // Live transcription (ScreenCaptureKit + Apple Speech)
    @StateObject var liveTranscriber = LiveTranscriber()
    @State var liveTranslateEnabled = true

    // Playback (unified AVPlayer for both audio and video)
    @State var player: AVPlayer?
    @State var youtubeWebView: WKWebView?  // WKWebView reference for YouTube seek
    @State var isPlaying = false
    @State var currentPlaybackTime = 0.0
    @State var currentLineIndex: Int? = nil
    @State var videoHeight: CGFloat = 350
    @State var isDraggingVideo = false
    @State var dragStartY: CGFloat = 0
    @State var dragStartHeight: CGFloat = 0
    @State var currentSubtitleText: String = ""
    @State var currentSubtitleTranslation: String = ""
    @State var duration = 0.0
    @State var cachedSubtitleCards: [SubtitleCard] = []
    @State var timeObserver: Any?
    @State var securityScopedURL: URL?

    // Translation
    @State var translatedText: String = ""

    var selectedModel: String {
        UserDefaults.standard.string(forKey: "defaultModel") ?? "google/gemini-2.5-flash"
    }

    // Reorganized transcript (LLM-merged sentence boundaries)
    @State var reorganizedCards: [ReorganizedCard] = []
    @State var isReorganizing: Bool = false
    @State var reorganizeProgress: String = ""
    @State var showReorganized: Bool = false

    // Subtitle display
    @State var showSubtitle: Bool = true
    enum SubtitleMode: String, CaseIterable { case source, target, both }
    @State var subtitleMode: SubtitleMode = .source

    // Transcript tab
    enum TranscriptTab: String, CaseIterable { case original = "Original", bilingual = "Bilingual" }
    @State var transcriptTab: TranscriptTab = .original
    @State var translationPairs: [TranslationPair] = []
    @State var isTranslatingLines: Bool = false

    // Word learning
    @State var markedWords: Set<String> = []
    @State var wordLearningResponse: String = ""
    @State var wordExplanations: [WordExplanation] = []
    @State var sentenceExplanations: [SentenceExplanation] = []
    @State var queriedWords: Set<String> = []  // Words already queried
    @State var isLoadingWordHelp: Bool = false
    @State var wordHelpTask: Task<Void, Never>?
    @State var fixTask: Task<Void, Never>?
    @State var translateTask: Task<Void, Never>?

    // Chat
    @State var chatMessages: [ChatMessage] = []
    @State var chatInput: String = ""
    @State var vocabScrollTarget: String? = nil
    @State var isChatting: Bool = false
    @State var chatTask: Task<Void, Never>?

    // Inspector (right panel)
    @State var showingInspector: Bool = true
    enum InspectorTab: String, CaseIterable { case vocab = "Vocabulary", chat = "Chat" }
    @State var inspectorTab: InspectorTab = .vocab

    init(story: Binding<Story>) {
        self._story = story
        self.speechTranscriber = SpokenWordTranscriber(story: story)
    }

    var sourceIsVideo: Bool {
        if !story.youtubeURL.isEmpty { return true }
        guard let url = story.url else { return false }
        return Set(["mp4", "mov", "m4v", "avi", "mkv"]).contains(url.pathExtension.lowercased())
    }

    var youtubeVideoID: String? {
        YouTubeHelper.extractVideoID(story.youtubeURL)
    }

    var body: some View {
        Group {
            if isTranscribingFile {
                transcribingView
            } else if story.isDone {
                mainLearningStage
            } else {
                importPromptView
            }
        }
        .inspector(isPresented: $showingInspector) {
            inspectorPanelView
                .inspectorColumnWidth(min: 420, ideal: 450, max: 600)
        }
        .navigationTitle(story.title)
        .toolbar { toolbarContent }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: story.isDone) { _, isDone in
            if isDone {
                setupPlayer()
                // Save original subtitle cards immediately after transcription
                if !cachedSubtitleCards.isEmpty {
                    story.savedSubtitleCards = cachedSubtitleCards
                }
            }
        }
        .onAppear {
            setupPlayer()
            // Ensure original subtitle cards are always loaded
            if cachedSubtitleCards.isEmpty {
                if !story.savedSubtitleCards.isEmpty {
                    cachedSubtitleCards = story.savedSubtitleCards
                } else {
                    let fromText = SubtitleExporter.subtitleCards(from: story.text)
                    if !fromText.isEmpty {
                        cachedSubtitleCards = fromText
                    }
                }
            }
            // Restore saved data
            if !story.savedReorganizedCards.isEmpty {
                reorganizedCards = story.savedReorganizedCards
                showReorganized = true
            }
            if !story.savedMarkedWords.isEmpty {
                markedWords = story.savedMarkedWords
            }
            wordLearningResponse = story.savedWordLearningResponse
            if !wordLearningResponse.isEmpty { parseWordExplanations() }
            if !story.savedSentenceLearningResponse.isEmpty { parseSentenceExplanations(story.savedSentenceLearningResponse) }
            translatedText = story.savedTranslation
            if !translatedText.isEmpty {
                // Try parsing saved translation as JSON pairs
                if let data = translatedText.data(using: .utf8),
                   let pairs = try? JSONDecoder().decode([TranslationPair].self, from: data) {
                    translationPairs = pairs
                }
            }
            chatMessages = story.savedChatMessages
            // Restore live segments
            if story.isLiveStream && !story.savedLiveSegments.isEmpty {
                liveTranscriber.segments = story.savedLiveSegments
                liveTranscriber.confirmedText = story.savedLiveSegments.map(\.source).joined(separator: "\n")
            }
        }
        .onDisappear {
            // Save live transcription
            saveLiveSegments()
            player?.pause()
            if let token = timeObserver {
                player?.removeTimeObserver(token)
                timeObserver = nil
            }
            player = nil
            youtubeWebView?.evaluateJavaScript("document.querySelector('video')?.pause()")
            youtubeWebView = nil
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Use filename as initial title
                story.title = url.deletingPathExtension().lastPathComponent
                isTranscribingFile = true
                let accessing = url.startAccessingSecurityScopedResource()
                if accessing { securityScopedURL = url }
                // Update transcriber locale based on selected source language
                speechTranscriber.recognitionLocale = SupportedLanguages.locale(for: story.sourceLanguage) ?? SpokenWordTranscriber.defaultLocale
                Task {
                    do { try await speechTranscriber.transcribeFile(url, engineID: preferences.selectedTranscriptionEngine) }
                    catch { print("could not transcribe file: \(error)") }
                    let originalCards = SubtitleExporter.subtitleCards(from: story.text)
                    if !originalCards.isEmpty {
                        cachedSubtitleCards = originalCards
                        story.savedSubtitleCards = originalCards
                    }
                    isTranscribingFile = false
                    StoryStore.shared.save(story)
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
            story.title = url.deletingPathExtension().lastPathComponent
            isTranscribingFile = true
            speechTranscriber.recognitionLocale = SupportedLanguages.locale(for: story.sourceLanguage) ?? SpokenWordTranscriber.defaultLocale
            Task {
                do { try await speechTranscriber.transcribeFile(url, engineID: preferences.selectedTranscriptionEngine) }
                catch { print("could not transcribe file: \(error)") }
                let originalCards = SubtitleExporter.subtitleCards(from: story.text)
                if !originalCards.isEmpty {
                    cachedSubtitleCards = originalCards
                    story.savedSubtitleCards = originalCards
                }
                isTranscribingFile = false
                // Delete YouTube audio file after transcription — playback uses embedded web player
                if !story.youtubeURL.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                    print("[YouTube] Deleted transcribed audio: \(url.lastPathComponent)")
                }
                StoryStore.shared.save(story)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {

        ToolbarItem(placement: .primaryAction) {
            Button {
                exportStory()
            } label: {
                Label("Export Notes", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(!story.isDone)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(showingInspector ? "Hide Inspector" : "Show Inspector")
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

            // Language selection
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source Language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $story.sourceLanguage) {
                        ForEach(SupportedLanguages.source) { lang in
                            Text(lang.displayName).tag(lang.id)
                        }
                    }
                    .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target Language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $story.targetLanguage) {
                        ForEach(SupportedLanguages.target) { lang in
                            Text(lang.displayName).tag(lang.id)
                        }
                    }
                    .frame(width: 180)
                }
            }

            HStack(spacing: 12) {
                Button { isImporting = true } label: {
                    Label("Import File", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { isShowingYouTubeDownload = true } label: {
                    Label("YouTube", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button { isShowingLiveStreamInput = true } label: {
                    Label("Live", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
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
                // Model download / preparation phase
                ProgressView(value: speechTranscriber.preparationProgress) {
                    Text("Preparing model...")
                        .font(.title3.bold())
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)
                Text("\(Int(speechTranscriber.preparationProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Transcribing file...")
                    .font(.title3.bold())
            }
            Text("Engine: \(preferences.selectedTranscriptionEngine.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = story.url {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if speechTranscriber.finalizedLineCount > 0 {
                Text("\(speechTranscriber.finalizedLineCount) segments transcribed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Show only the current volatile (in-progress) text — lightweight
            if !speechTranscriber.volatileTranscript.characters.isEmpty {
                Text(speechTranscriber.volatileTranscript)
                    .font(.body)
                    .foregroundStyle(.secondary)
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
        ZStack {
            if let vid = youtubeVideoID {
                // YouTube: use embedded web player (HD, no codec/throttle issues)
                YouTubeEmbedPlayer(videoID: vid, onTimeUpdate: { time in
                    updateSubtitleFromYouTube(time: time)
                }, onWebViewReady: { webView in
                    youtubeWebView = webView
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            } else if let p = player {
                NativeVideoPlayer(player: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Subtitle overlay — unified for both live and normal modes
            if liveTranscriber.isRunning, let last = liveTranscriber.segments.last {
                SubtitleOverlay(source: last.source, translation: last.translation)
            } else if showSubtitle {
                let src: String = {
                    switch subtitleMode {
                    case .source, .both: return currentSubtitleText
                    case .target: return ""
                    }
                }()
                let tgt: String = {
                    switch subtitleMode {
                    case .source: return ""
                    case .target, .both: return currentSubtitleTranslation
                    }
                }()
                if !src.isEmpty || !tgt.isEmpty {
                    SubtitleOverlay(source: src, translation: tgt)
                }
            }

            // Subtitle controls — bottom right of video
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        // Mode cycle: source → target → both → off → source ...
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if !showSubtitle {
                                    showSubtitle = true
                                    subtitleMode = .source
                                } else {
                                    switch subtitleMode {
                                    case .source: subtitleMode = .target
                                    case .target: subtitleMode = .both
                                    case .both: showSubtitle = false
                                    }
                                }
                            }
                        } label: {
                            let modeLabel: String = {
                                guard showSubtitle else { return "OFF" }
                                switch subtitleMode {
                                case .source: return story.sourceLanguage.prefix(2).uppercased()
                                case .target:
                                    return story.targetLanguage == "中文" ? "ZH" : story.targetLanguage.prefix(2).uppercased()
                                case .both: return "2x"
                                }
                            }()
                            HStack(spacing: 4) {
                                Image(systemName: showSubtitle ? "captions.bubble.fill" : "captions.bubble")
                                    .font(.system(size: 16, weight: .medium))
                                Text(modeLabel)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(showSubtitle ? preferences.accentColor : Color.white.opacity(0.9))
                            .frame(height: 36)
                            .padding(.horizontal, 12)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.3))
                                    .background(.ultraThinMaterial)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 48)
                }
            }
        }
    }

    // The manual HStack wrapper was removed in favor of the native .inspector modifier.

    // MARK: - Unified Main Learning Stage

    @ViewBuilder
    var mainLearningStage: some View {
        VStack(spacing: 0) {
            // Media player (video or audio)
            if sourceIsVideo {
                videoPlayerWithSubtitle
                    .frame(height: videoHeight)
                    .clipped()

                // Drag handle to resize video
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
                                if !isDraggingVideo {
                                    isDraggingVideo = true
                                    dragStartY = value.startLocation.y
                                    dragStartHeight = videoHeight
                                }
                                let delta = value.location.y - dragStartY
                                videoHeight = min(max(dragStartHeight + delta, 150), 600)
                            }
                            .onEnded { _ in
                                isDraggingVideo = false
                            }
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

            // Transcript area — live mode vs normal mode
            if isLiveMode {
                liveTranscriptArea
            } else {
                normalTranscriptArea
            }
        }
    }

    // MARK: - Inspector Panel (Right Sidebar)

    @ViewBuilder
    var inspectorPanelView: some View {
        VStack(spacing: 0) {
            // Toolbar-style custom pill selector
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: inspectorTab == tab ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(inspectorTab == tab ? Color.secondary.opacity(0.3) : Color.clear)
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorTab = tab
                            }
                        }
                        .foregroundStyle(inspectorTab == tab ? Color.primary : Color.secondary)
                }
            }
            .padding(2)
            .background(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // Tab content
            if inspectorTab == .vocab {
                vocabHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        vocabCards
                            .padding(20)
                    }
                    .onChange(of: vocabScrollTarget) { _, target in
                        if let target {
                            withAnimation {
                                proxy.scrollTo(target, anchor: .top)
                            }
                            vocabScrollTarget = nil
                        }
                    }
                }
            } else {
                ScrollView {
                    chatView
                        .padding(20)
                }
                Divider()
                chatInputBar
                    .padding(12)
                    .background(.regularMaterial)
            }
        }
        .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
    }

    // MARK: - Audio Player Bar

    @ViewBuilder
    var audioPlayerBar: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Slider(value: $currentPlaybackTime, in: 0...max(duration, 1)) { editing in
                if !editing { seek(to: currentPlaybackTime) }
            }

            Text(timeString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Transcript Text (shared between video & audio)

    // MARK: - Learning Panel (shared between video & audio)

    @ViewBuilder
    var vocabHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Fix progress
            if isReorganizing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(reorganizeProgress.isEmpty ? "Waiting for model response..." : "Reorganizing transcript...")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    if !reorganizeProgress.isEmpty {
                        Text(reorganizeProgress)
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

            // Marked words header + chips
            if !markedWords.isEmpty || isLoadingWordHelp || !wordExplanations.isEmpty || !wordLearningResponse.isEmpty {
                HStack(alignment: .center) {
                    Text("\(markedWords.count) ITEMS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            markedWords.removeAll()
                            wordLearningResponse = ""
                            wordExplanations = []
                            sentenceExplanations = []
                            queriedWords = []
                            saveLearnProgress()
                        } label: {
                            Text("Clear")
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isLoadingWordHelp)

                        if isLoadingWordHelp {
                            Button {
                                wordHelpTask?.cancel()
                                isLoadingWordHelp = false
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.8))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            let newWords = markedWords.subtracting(queriedWords)
                            Button {
                                wordHelpTask = Task { await queryWordHelp() }
                            } label: {
                                Label(newWords.isEmpty ? "Ask AI" : "Ask (\(newWords.count) new)", systemImage: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(preferences.accentColor)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(newWords.isEmpty)
                        }
                    }
                }

                // Word chips — click to scroll to card
                if !markedWords.isEmpty {
                    ScrollView {
                        WordFlowLayout(spacing: 6) {
                            ForEach(markedWords.sorted(), id: \.self) { word in
                                WordChipView(word: word, onTap: {
                                    vocabScrollTarget = word
                                }, onRemove: {
                                    markedWords.remove(word)
                                    queriedWords.remove(word)
                                    wordExplanations.removeAll { $0.word.lowercased() == word }
                                    sentenceExplanations.removeAll { $0.sentence.lowercased() == word }
                                    saveLearnProgress()
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
            // Empty state — no words selected
            if markedWords.isEmpty && !isLoadingWordHelp && wordExplanations.isEmpty && sentenceExplanations.isEmpty && wordLearningResponse.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "text.word.spacing")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Click a word to add it.\nDrag across words to select a phrase.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Streaming progress
            if isLoadingWordHelp && !wordLearningResponse.isEmpty {
                Text(wordLearningResponse)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // AI word explanation cards
            if !wordExplanations.isEmpty || !sentenceExplanations.isEmpty {
                WordCardListView(
                    explanations: wordExplanations,
                    sentenceExplanations: sentenceExplanations,
                    onDeleteWord: { word in
                        wordExplanations.removeAll { $0.word.lowercased() == word }
                        if markedWords.contains(word) {
                            markedWords.remove(word)
                            queriedWords.remove(word)
                        }
                        rebuildWordLearningResponse()
                        saveLearnProgress()
                    },
                    onDeleteSentence: { sentence in
                        sentenceExplanations.removeAll { $0.sentence.lowercased() == sentence }
                        if markedWords.contains(sentence) {
                            markedWords.remove(sentence)
                            queriedWords.remove(sentence)
                        }
                        rebuildSentenceLearningResponse()
                        saveLearnProgress()
                    }
                )
            } else if !wordLearningResponse.isEmpty && !isLoadingWordHelp {
                MarkdownView(markdown: wordLearningResponse)
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
    }

    var learningPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            vocabHeader
            vocabCards
        }
    }

    // MARK: - Chat View

    /// Chat messages (scrollable, inside learningPanel)
    @ViewBuilder
    var chatView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHAT")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if !chatMessages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chatMessages.indices, id: \.self) { i in
                        let msg = chatMessages[i]
                        HStack(alignment: .top, spacing: 8) {
                            if msg.role == "user" {
                                Spacer(minLength: 40)
                                Text(msg.content)
                                    .font(.callout)
                                    .padding(10)
                                    .background(preferences.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    MarkdownView(markdown: msg.content)
                                }
                                .padding(10)
                                .background(.regularMaterial)
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

    /// Chat input bar (fixed at bottom, ChatGPT-style)
    @ViewBuilder
    var chatInputBar: some View {
        HStack(spacing: 12) {
            TextField("Ask anything about this content...", text: $chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.body)
                .onSubmit {
                    if !chatInput.isEmpty && !isChatting {
                        chatTask = Task { await sendChatMessage() }
                    }
                }

            if isChatting {
                Button {
                    chatTask?.cancel()
                    isChatting = false
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    chatTask = Task { await sendChatMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.gray.opacity(0.4)
                                : preferences.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }

}
