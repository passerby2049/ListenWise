/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
File transcription code — supports multiple transcription engines via TranscriptionEngine protocol.
*/

import Foundation
import Speech
import SwiftUI
import AVFoundation

@Observable
final class SpokenWordTranscriber {
    // Legacy Apple Speech references (kept for backward compatibility)
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var recognizerTask: Task<(), Error>?

    /// The active transcription engine.
    private var engine: TranscriptionEngine?

    var story: Binding<Story>
    var recognitionLocale: Locale

    var volatileTranscript: AttributedString = ""
    var finalizedTranscript: AttributedString = ""
    var finalizedLineCount: Int = 0

    /// Download/preparation progress (0.0 - 1.0). Observed by UI.
    var preparationProgress: Double = 0

    /// Whether the engine is currently being prepared (downloading model, etc.)
    var isPreparing: Bool = false

    static let defaultLocale = Locale(components: .init(languageCode: .english, script: nil, languageRegion: .unitedStates))

    init(story: Binding<Story>) {
        self.story = story
        self.recognitionLocale = SupportedLanguages.locale(for: story.wrappedValue.sourceLanguage) ?? Self.defaultLocale
    }

    // MARK: - File Transcription

    func transcribeFile(_ url: URL, engineID: TranscriptionEngineID = .appleSpeech) async throws {
        story.url.wrappedValue = url

        if engineID == .appleSpeech {
            // Use the original Apple Speech path for full AttributedString timing support
            try await transcribeWithAppleSpeech(url)
        } else {
            // Use the pluggable engine
            try await transcribeWithEngine(url, engineID: engineID)
        }

        // Wait for recognizer task to finish processing all results
        _ = try? await recognizerTask?.value
        recognizerTask = nil

        // Give a moment for any remaining @Observable updates to flush
        try? await Task.sleep(for: .milliseconds(500))
        story.isDone.wrappedValue = true

        Task {
            self.story.title.wrappedValue = try await story.wrappedValue.suggestedTitle() ?? story.title.wrappedValue
        }
    }

    // MARK: - Engine-based Transcription

    private func transcribeWithEngine(_ url: URL, engineID: TranscriptionEngineID) async throws {
        let engine = engineID.makeEngine()
        self.engine = engine

        guard engine.isAvailable else {
            throw TranscriptionError.failedToSetupRecognitionStream
        }

        // Prepare (download model if needed)
        isPreparing = true
        preparationProgress = 0
        do {
            try await engine.prepare(locale: recognitionLocale) { [weak self] progress in
                Task { @MainActor in
                    self?.preparationProgress = progress
                }
            }
        } catch {
            isPreparing = false
            throw error
        }
        isPreparing = false

        // Stream transcription results, collecting timing for subtitle cards
        var subtitleCards: [SubtitleCard] = []
        let stream = engine.transcribe(audioFileURL: url, locale: recognitionLocale)
        for try await segment in stream {
            if segment.isFinal {
                finalizedTranscript += segment.text
                volatileTranscript = ""
                updateStoryWithNewText(withFinal: segment.text)
                // Collect timing from engines that provide it (e.g. Whisper)
                if let start = segment.startTime, let end = segment.endTime {
                    let text = String(segment.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        subtitleCards.append(SubtitleCard(text: text, start: start, end: end))
                    }
                }
            } else {
                volatileTranscript = segment.text
                volatileTranscript.foregroundColor = .purple.opacity(0.4)
            }
        }
        // Save subtitle cards from engine timing if available
        if !subtitleCards.isEmpty {
            story.savedSubtitleCards.wrappedValue = subtitleCards
        }
    }

    // MARK: - Apple Speech Transcription (Original Path)

    private func transcribeWithAppleSpeech(_ url: URL) async throws {
        try await prepareAnalyzer()

        let audioURL: URL
        var tempFile: URL?
        if videoFileExtensions.contains(url.pathExtension.lowercased()) {
            audioURL = try await extractAudioFromVideo(url)
            tempFile = audioURL
        } else {
            audioURL = url
        }
        defer { if let tempFile { try? FileManager.default.removeItem(at: tempFile) } }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let lastTime = try await analyzer?.analyzeSequence(from: audioFile)
        if let lastTime {
            try await analyzer?.finalizeAndFinish(through: lastTime)
        } else {
            await analyzer?.cancelAndFinishNow()
        }
    }

    // MARK: - Setup (Apple Speech)

    private func prepareAnalyzer() async throws {
        let locale = await supported(locale: recognitionLocale) ? recognitionLocale : SpokenWordTranscriber.defaultLocale

        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [.audioTimeRange])

        guard let transcriber else {
            throw TranscriptionError.failedToSetupRecognitionStream
        }

        analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            try await ensureModel(transcriber: transcriber, locale: locale)
        } catch let error as TranscriptionError {
            print(error)
            throw error
        }

        recognizerTask = Task {
            do {
                for try await case let result in transcriber.results {
                    let text = result.text
                    if result.isFinal {
                        finalizedTranscript += text
                        volatileTranscript = ""
                        updateStoryWithNewText(withFinal: text)
                    } else {
                        volatileTranscript = text
                        volatileTranscript.foregroundColor = .purple.opacity(0.4)
                    }
                }
            } catch {
                print("speech recognition failed")
            }
        }
    }

    func updateStoryWithNewText(withFinal str: AttributedString) {
        story.text.wrappedValue.append(str)
        finalizedLineCount += 1
    }

    // MARK: - Live Streaming (mic input, same as sample app)

    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    var analyzerFormat: AVAudioFormat?
    var converter = BufferConverter()
    private var liveAudioEngine: AVAudioEngine?

    /// Set up for live streaming (mirrors sample app's setUpTranscriber exactly).
    func setUpForLiveStream() async throws {
        let locale = await supported(locale: recognitionLocale) ? recognitionLocale : SpokenWordTranscriber.defaultLocale

        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [.audioTimeRange])

        guard let transcriber else {
            throw TranscriptionError.failedToSetupRecognitionStream
        }

        analyzer = SpeechAnalyzer(modules: [transcriber])

        try await ensureModel(transcriber: transcriber, locale: locale)

        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        recognizerTask = Task {
            do {
                for try await case let result in transcriber.results {
                    let text = result.text
                    if result.isFinal {
                        finalizedTranscript += text
                        volatileTranscript = ""
                        finalizedLineCount += 1
                    } else {
                        volatileTranscript = text
                        volatileTranscript.foregroundColor = .purple.opacity(0.4)
                    }
                }
            } catch {
                print("speech recognition failed")
            }
        }

        guard let inputSequence else { return }
        try await analyzer?.start(inputSequence: inputSequence)
    }

    /// Feed a single audio buffer (same as sample app's streamAudioToTranscriber).
    func streamAudioToTranscriber(_ buffer: AVAudioPCMBuffer) async throws {
        guard let inputBuilder, let analyzerFormat else {
            throw TranscriptionError.invalidAudioDataType
        }
        let converted = try self.converter.convertBuffer(buffer, to: analyzerFormat)
        let input = AnalyzerInput(buffer: converted)
        inputBuilder.yield(input)
    }

    /// Start mic recording and feed to transcriber (same as sample app's record + audioStream).
    func recordFromMic() async throws {
        try await setUpForLiveStream()

        let engine = AVAudioEngine()
        self.liveAudioEngine = engine

        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        print("[LiveStream] Mic format: \(micFormat), analyzer format: \(String(describing: analyzerFormat))")

        // Same async stream pattern as sample app
        var outputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            outputContinuation?.yield(buffer)
        }

        engine.prepare()
        try engine.start()

        let audioStream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { continuation in
            outputContinuation = continuation
        }

        // Feed audio to transcriber (same loop as sample app)
        for await input in audioStream {
            try await self.streamAudioToTranscriber(input)
        }
    }

    func stopLiveStream() async {
        liveAudioEngine?.inputNode.removeTap(onBus: 0)
        liveAudioEngine?.stop()
        liveAudioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        recognizerTask?.cancel()
        recognizerTask = nil
    }
}

extension SpokenWordTranscriber {
    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw TranscriptionError.localeNotSupported
        }

        if await installed(locale: locale) {
            return
        } else {
            try await downloadIfNeeded(for: transcriber)
        }
    }

    func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }
}
