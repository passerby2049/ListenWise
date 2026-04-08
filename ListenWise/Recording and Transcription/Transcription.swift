/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
File transcription code
*/

import Foundation
import Speech
import SwiftUI
import AVFoundation

@Observable
final class SpokenWordTranscriber {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var recognizerTask: Task<(), Error>?

    var story: Binding<Story>
    var recognitionLocale: Locale

    var volatileTranscript: AttributedString = ""
    var finalizedTranscript: AttributedString = ""
    var finalizedLineCount: Int = 0

    static let defaultLocale = Locale(components: .init(languageCode: .english, script: nil, languageRegion: .unitedStates))

    init(story: Binding<Story>) {
        self.story = story
        self.recognitionLocale = SupportedLanguages.locale(for: story.wrappedValue.sourceLanguage) ?? Self.defaultLocale
    }

    // MARK: - File Transcription

    func transcribeFile(_ url: URL) async throws {
        try await prepareAnalyzer()
        story.url.wrappedValue = url

        let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv"])
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            try await transcribeVideoFile(url)
        } else {
            let audioFile = try AVAudioFile(forReading: url)
            let lastTime = try await analyzer?.analyzeSequence(from: audioFile)
            if let lastTime {
                try await analyzer?.finalizeAndFinish(through: lastTime)
            } else {
                await analyzer?.cancelAndFinishNow()
            }
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

    private func transcribeVideoFile(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)

        let videoDuration = try? await asset.load(.duration)

        let tempURL = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioFilePathNotFound
        }
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a
        // Ensure full duration is exported
        exportSession.timeRange = CMTimeRange(start: .zero, duration: videoDuration ?? CMTime(seconds: 7200, preferredTimescale: 600))

        await exportSession.export()
        guard exportSession.status == .completed else {
            throw TranscriptionError.audioFilePathNotFound
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let audioFile = try AVAudioFile(forReading: tempURL)
        let lastTime = try await analyzer?.analyzeSequence(from: audioFile)
        if let lastTime {
            try await analyzer?.finalizeAndFinish(through: lastTime)
        } else {
            await analyzer?.cancelAndFinishNow()
        }
    }

    // MARK: - Setup

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
