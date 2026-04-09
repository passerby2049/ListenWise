/*
Abstract:
Apple Speech engine — wraps SpeechTranscriber/SpeechAnalyzer into TranscriptionEngine protocol.
This is the original transcription backend extracted from SpokenWordTranscriber.
*/

import Foundation
import Speech
import AVFoundation

final class AppleSpeechEngine: TranscriptionEngine {
    let displayName = "Apple Speech"
    let id = "apple-speech"

    var isAvailable: Bool { true }

    func prepare(locale: Locale, progressHandler: ((Double) -> Void)?) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIDs = supported.map { $0.identifier(.bcp47) }
        guard supportedIDs.contains(locale.identifier(.bcp47)) else {
            throw TranscriptionError.localeNotSupported
        }

        let installed = await Set(SpeechTranscriber.installedLocales)
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        if installedIDs.contains(locale.identifier(.bcp47)) {
            progressHandler?(1.0)
            return
        }

        // Need to download model
        progressHandler?(0.1)
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
        progressHandler?(1.0)
    }

    func transcribe(audioFileURL url: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let transcriber = SpeechTranscriber(locale: locale,
                                                        transcriptionOptions: [],
                                                        reportingOptions: [.volatileResults],
                                                        attributeOptions: [.audioTimeRange])

                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    // Start result streaming task
                    let resultTask = Task {
                        for try await case let result in transcriber.results {
                            let segment = TranscriptionSegment(
                                text: result.text,
                                isFinal: result.isFinal
                            )
                            continuation.yield(segment)
                        }
                    }

                    // Process audio
                    let audioURL: URL
                    if videoFileExtensions.contains(url.pathExtension.lowercased()) {
                        audioURL = try await extractAudioFromVideo(url)
                    } else {
                        audioURL = url
                    }

                    let audioFile = try AVAudioFile(forReading: audioURL)
                    let lastTime = try await analyzer.analyzeSequence(from: audioFile)
                    if let lastTime {
                        try await analyzer.finalizeAndFinish(through: lastTime)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }

                    // Clean up temp file if we extracted audio
                    if audioURL != url {
                        try? FileManager.default.removeItem(at: audioURL)
                    }

                    // Wait for all results
                    _ = try? await resultTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

}
