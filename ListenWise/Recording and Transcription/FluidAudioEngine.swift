/*
Abstract:
FluidAudio transcription engine — uses Parakeet TDT v3/v2 via FluidAudio SDK for
high-speed on-device speech recognition on Apple Silicon.
*/

import Foundation
import AVFoundation
import FluidAudio

// MARK: - Parakeet Model Variant

enum ParakeetModelVariant: String {
    case v3 = "parakeet-tdt-v3"
    case v2 = "parakeet-tdt-v2"

    var displayName: String {
        switch self {
        case .v3: return "Parakeet TDT v3 (Multilingual)"
        case .v2: return "Parakeet TDT v2 (English Only)"
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .v2: return .v2
        }
    }
}

// MARK: - FluidAudio Engine

final class FluidAudioEngine: TranscriptionEngine {
    let modelVariant: ParakeetModelVariant

    var displayName: String { modelVariant.displayName }
    var id: String { modelVariant.rawValue }

    var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private var asrManager: AsrManager?

    init(modelVariant: ParakeetModelVariant = .v3) {
        self.modelVariant = modelVariant
    }

    func prepare(locale: Locale, progressHandler: ((Double) -> Void)?) async throws {
        guard isAvailable else {
            throw TranscriptionError.failedToSetupRecognitionStream
        }

        progressHandler?(0.05)

        // Download and load CoreML models from HuggingFace (cached after first download)
        // Pass through download progress from FluidAudio SDK (0.05 → 0.85 range)
        let models = try await AsrModels.downloadAndLoad(version: modelVariant.asrVersion) { downloadProgress in
            let mapped = 0.05 + downloadProgress.fractionCompleted * 0.80
            progressHandler?(min(mapped, 0.85))
        }
        progressHandler?(0.90)

        // Initialize the ASR manager and load models
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        progressHandler?(1.0)
    }

    func transcribe(audioFileURL url: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if self.asrManager == nil {
                        try await self.prepare(locale: locale, progressHandler: nil)
                    }
                    guard let manager = self.asrManager else {
                        continuation.finish(throwing: TranscriptionError.failedToSetupRecognitionStream)
                        return
                    }

                    // Extract audio from video if needed
                    let audioURL: URL
                    var tempFile: URL?
                    if videoFileExtensions.contains(url.pathExtension.lowercased()) {
                        audioURL = try await extractAudioFromVideo(url)
                        tempFile = audioURL
                    } else {
                        audioURL = url
                    }
                    defer { if let tempFile { try? FileManager.default.removeItem(at: tempFile) } }

                    // Transcribe the file using FluidAudio
                    let result = try await manager.transcribe(audioURL)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !text.isEmpty else {
                        continuation.finish()
                        return
                    }

                    // Group token timings into sentences with proper timing
                    let timings = result.tokenTimings ?? []
                    let sentences = Self.groupTimingsIntoSentences(timings)

                    for sentence in sentences {
                        var attributed = AttributedString(sentence.text + " ")
                        // Set audioTimeRange so SubtitleExporter can read timing from the AttributedString
                        let startCM = CMTime(seconds: sentence.start, preferredTimescale: 600)
                        let endCM = CMTime(seconds: sentence.end, preferredTimescale: 600)
                        attributed.audioTimeRange = CMTimeRange(start: startCM, end: endCM)
                        continuation.yield(TranscriptionSegment(
                            text: attributed, isFinal: true,
                            startTime: sentence.start, endTime: sentence.end
                        ))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Group token timings into sentence-level segments, splitting at sentence-ending punctuation.
    /// Each sentence carries the start time of its first token and end time of its last token.
    private static func groupTimingsIntoSentences(_ timings: [TokenTiming]) -> [SubtitleCard] {
        guard !timings.isEmpty else { return [] }

        var sentences: [SubtitleCard] = []
        let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var currentText = ""
        var startTime: Double?
        var endTime: Double = 0

        for timing in timings {
            currentText += timing.token
            if startTime == nil { startTime = timing.startTime }
            endTime = timing.endTime

            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastChar = trimmed.last, sentenceEnders.contains(lastChar) {
                if !trimmed.isEmpty {
                    sentences.append(SubtitleCard(text: trimmed, start: startTime ?? 0, end: endTime))
                }
                currentText = ""
                startTime = nil
            }
        }

        // Remaining text
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sentences.append(SubtitleCard(text: trimmed, start: startTime ?? 0, end: endTime))
        }

        return sentences
    }

}
