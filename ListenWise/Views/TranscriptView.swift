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
    @State var isImporting = false
    @State var isTranscribingFile = false
    @State var isShowingYouTubeDownload = false
    @State var youtubeDownloadedURL: URL?
    @State var speechTranscriber: SpokenWordTranscriber

    // Playback (unified AVPlayer for both audio and video)
    @State var player: AVPlayer?
    @State var isPlaying = false
    @State var currentPlaybackTime = 0.0
    @State var currentLineIndex: Int? = nil
    @State var videoHeight: CGFloat = 350
    @State private var dragStartHeight: CGFloat = 0
    @State var currentSubtitleText: String = ""
    @State var currentSubtitleTranslation: String = ""
    @State var duration = 0.0
    @State var cachedSubtitleCards: [(text: String, start: Double, end: Double)] = []
    @State private var timeObserver: Any?
    @State private var securityScopedURL: URL?

    // Translation
    @State var translatedText: String = ""

    var selectedModel: String {
        UserDefaults.standard.string(forKey: "defaultModel") ?? "google/gemini-2.5-flash"
    }

    // Reorganized transcript (LLM-merged sentence boundaries)
    @State var reorganizedCards: [(text: String, translation: String, start: Double, end: Double)] = []
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
    @State private var wordHelpTask: Task<Void, Never>?
    @State private var fixTask: Task<Void, Never>?
    @State private var translateTask: Task<Void, Never>?

    // Chat
    @State var chatMessages: [ChatMessage] = []
    @State var chatInput: String = ""
    @State var vocabScrollTarget: String? = nil
    @State var isChatting: Bool = false
    @State private var chatTask: Task<Void, Never>?

    // Inspector (right panel)
    @State var showingInspector: Bool = true
    enum InspectorTab: String, CaseIterable { case vocab = "Vocabulary", chat = "Chat" }
    @State var inspectorTab: InspectorTab = .vocab

    init(story: Binding<Story>) {
        self._story = story
        self.speechTranscriber = SpokenWordTranscriber(story: story)
    }

    var sourceIsVideo: Bool {
        guard let url = story.url else { return false }
        return Set(["mp4", "mov", "m4v", "avi", "mkv"]).contains(url.pathExtension.lowercased())
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
        }
        .onDisappear {
            player?.pause()
            if let token = timeObserver {
                player?.removeTimeObserver(token)
                timeObserver = nil
            }
            player = nil
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
                    do { try await speechTranscriber.transcribeFile(url) }
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
            YouTubeDownloadView(downloadedURL: $youtubeDownloadedURL, youtubeSourceURL: $story.youtubeURL)
        }
        .onChange(of: youtubeDownloadedURL) { _, newURL in
            guard let url = newURL else { return }
            story.title = url.deletingPathExtension().lastPathComponent
            isTranscribingFile = true
            speechTranscriber.recognitionLocale = SupportedLanguages.locale(for: story.sourceLanguage) ?? SpokenWordTranscriber.defaultLocale
            Task {
                do { try await speechTranscriber.transcribeFile(url) }
                catch { print("could not transcribe file: \(error)") }
                let originalCards = SubtitleExporter.subtitleCards(from: story.text)
                if !originalCards.isEmpty {
                    cachedSubtitleCards = originalCards
                    story.savedSubtitleCards = originalCards
                }
                isTranscribingFile = false
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

    // MARK: - Player Setup

    func setupPlayer() {
        guard story.isDone, let url = story.url, player == nil else { return }
        // Re-acquire security-scoped access for restored URLs
        if securityScopedURL == nil {
            let accessing = url.startAccessingSecurityScopedResource()
            if accessing { securityScopedURL = url }
        }
        let p = AVPlayer(url: url)
        player = p
        // Use timing-based cards if available, otherwise fall back to saved cards
        // Prefer saved cards first to avoid blocking the main thread from slow AttributedString parsing
        if !story.savedSubtitleCards.isEmpty {
            cachedSubtitleCards = story.savedSubtitleCards
        } else {
            let cards = SubtitleExporter.subtitleCards(from: story.text)
            cachedSubtitleCards = cards.isEmpty ? story.savedSubtitleCards : cards
            if !cachedSubtitleCards.isEmpty {
                story.savedSubtitleCards = cachedSubtitleCards
            }
        }

        // Get duration
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration) {
                duration = CMTimeGetSeconds(d)
            }
        }

        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        let isVideo = sourceIsVideo
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            let t = time.seconds

            // Only update currentPlaybackTime for audio mode (slider/time display).
            // In video mode the native player has its own controls, so skip to avoid
            // unnecessary re-renders that cause scroll lag in the learning panel.
            if !isVideo {
                currentPlaybackTime = t
            }

            let cards = activeSubtitleCards
            let newIndex = cards.firstIndex { $0.start <= t && t < $0.end }
            if newIndex != currentLineIndex {
                currentLineIndex = newIndex
                // Auto-scroll vocab panel to first marked word in current subtitle
                if let idx = newIndex, inspectorTab == .vocab, !markedWords.isEmpty {
                    let lineText = cards[idx].text.lowercased()
                    if let firstMatch = markedWords.sorted().first(where: { lineText.contains($0) }) {
                        vocabScrollTarget = firstMatch
                    }
                }
            }

            if isVideo {
                currentSubtitleText = newIndex.map { cards[$0].text } ?? ""
                // Get translation from reorganized cards if available
                if showReorganized && !reorganizedCards.isEmpty, let idx = newIndex, idx < reorganizedCards.count {
                    currentSubtitleTranslation = reorganizedCards[idx].translation
                } else {
                    currentSubtitleTranslation = ""
                }
            }
        }
    }

    /// Active subtitle cards — prefer reorganized, then cached original.
    var activeSubtitleCards: [(text: String, start: Double, end: Double)] {
        if showReorganized && !reorganizedCards.isEmpty {
            return reorganizedCards.map { (text: $0.text, start: $0.start, end: $0.end) }
        }
        return cachedSubtitleCards
    }

    func togglePlayback() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
        } else {
            p.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var timeString: String {
        let fmt: (Double) -> String = { t in
            let m = Int(t) / 60
            let s = Int(t) % 60
            return String(format: "%d:%02d", m, s)
        }
        return "\(fmt(currentPlaybackTime)) / \(fmt(duration))"
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcribing View

    @ViewBuilder
    var transcribingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Transcribing file...")
                .font(.title3.bold())
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
            if let p = player {
                NativeVideoPlayer(player: p)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }

            // Subtitle overlay
            if showSubtitle {
                let subtitleContent: String? = {
                    switch subtitleMode {
                    case .source:
                        return currentSubtitleText.isEmpty ? nil : currentSubtitleText
                    case .target:
                        return currentSubtitleTranslation.isEmpty ? nil : currentSubtitleTranslation
                    case .both:
                        if currentSubtitleText.isEmpty { return nil }
                        if currentSubtitleTranslation.isEmpty { return currentSubtitleText }
                        return currentSubtitleText + "\n" + currentSubtitleTranslation
                    }
                }()

                if let content = subtitleContent {
                    VStack {
                        Spacer()
                        Text(content)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 48)
                            .padding(.horizontal, 90)
                    }
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
                            .foregroundStyle(showSubtitle ? Color.accentColor : Color.white.opacity(0.9))
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
                        DragGesture()
                            .onChanged { value in
                                if dragStartHeight == 0 { dragStartHeight = videoHeight }
                                videoHeight = min(max(dragStartHeight + value.translation.height, 150), 600)
                            }
                            .onEnded { _ in dragStartHeight = 0 }
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

            // Transcript area
            transcriptTabView
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

    /// The lines to display — must match activeSubtitleCards 1:1 for correct timestamp mapping.
    // MARK: - Transcript Tab View

    @ViewBuilder
    var transcriptTabView: some View {
        VStack(spacing: 0) {
            // Control bar — transcript tabs + reorganize controls
            HStack(spacing: 12) {
                Spacer()

                // Original / Bilingual toggle
                HStack(spacing: 2) {
                    ForEach(TranscriptTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { transcriptTab = tab }
                            // Re-trigger scroll to current line after tab switch
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

                // Raw / AI Reorganized toggle (pill style)
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
                                // Re-trigger scroll to current line
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

                // AI Reorganize button (pill style)
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
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .disabled(!story.isDone || cachedSubtitleCards.isEmpty)
                    .help("AI Reorganize — merge fragments into proper sentences")
                }

                Spacer()
            }
            .padding(.vertical, 8)

            ScrollView {
                if transcriptTab == .original {
                    transcriptTextView
                        .padding(20)
                } else {
                    translationTextView
                        .padding(20)
                }
            }
            .clipped()
        }
        .onChange(of: transcriptTab) { _, newTab in
            if newTab == .bilingual && translationPairs.isEmpty && !isTranslatingLines {
                Task { await translateByLines() }
            }
        }
    }

    @ViewBuilder
    var translationTextView: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            // Use reorganized cards if available (they have zh translations)
            if showReorganized && !reorganizedCards.isEmpty {
                let hasTranslation = reorganizedCards.contains { !$0.translation.isEmpty }
                if !hasTranslation {
                    HStack {
                        Text("Reorganize with translation first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            // Re-reorganize to get translations
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
                ScrollViewReader { proxy in
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
                }
            } else if isTranslatingLines {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Translating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !translationPairs.isEmpty {
                // Fallback: old-style translation pairs (no timestamps)
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
                        Text(translationPairs[i].source)
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
        .textSelection(.enabled)
    }

    var displayLines: [String] {
        // Use active subtitle cards (reorganized or original) as display source
        let cards = activeSubtitleCards
        if !cards.isEmpty {
            return cards.map { $0.text }
        }

        // Fallback: split plain text into sentences
        return splitIntoSentences(String(story.text.characters))
    }

    /// Split text into sentences by punctuation (. ? !) while keeping the punctuation attached.
    private func splitIntoSentences(_ text: String) -> [String] {
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

    /// Seek to the start time of a transcript line.
    func seekToLine(_ index: Int) {
        let cards = activeSubtitleCards
        guard index < cards.count else { return }
        seek(to: cards[index].start)
        if !isPlaying { togglePlayback() }
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
                .foregroundStyle(isActive ? Color.accentColor : Color.gray)
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
    var transcriptTextView: some View {
        let lines = displayLines
        let active = currentLineIndex
        let cards = activeSubtitleCards
        ScrollViewReader { proxy in
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
                                    .background(Color.accentColor)
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
                                    sentenceExplanations.removeAll { $0.sentence.lowercased().contains(word) }
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
                                    .background(Color.accentColor.opacity(0.12))
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
                                : Color.accentColor
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
