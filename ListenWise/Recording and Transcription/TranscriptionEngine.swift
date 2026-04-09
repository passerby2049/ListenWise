/*
Abstract:
Transcription engine protocol and engine registry.
All speech-to-text backends conform to this protocol.
*/

import Foundation
import AVFoundation

// MARK: - Transcription Result

/// A single transcription result segment with optional timing.
struct TranscriptionSegment {
    let text: AttributedString
    let isFinal: Bool
    /// Optional timing for subtitle card generation (seconds).
    var startTime: Double?
    var endTime: Double?
}

// MARK: - Transcription Engine Protocol

/// Unified interface for all speech-to-text backends.
///
/// Engines receive an audio file URL and deliver results via an AsyncStream.
/// The stream emits partial (volatile) results and final results, matching
/// the existing SpokenWordTranscriber consumption pattern.
protocol TranscriptionEngine {
    /// Human-readable name for display in settings.
    var displayName: String { get }

    /// Unique identifier for persistence.
    var id: String { get }

    /// Whether this engine is available on the current system.
    var isAvailable: Bool { get }

    /// Prepare the engine (download models if needed).
    /// - Parameter progressHandler: Optional callback for download progress (0.0 - 1.0).
    func prepare(locale: Locale, progressHandler: ((Double) -> Void)?) async throws

    /// Transcribe an audio file, returning an async stream of segments.
    /// The stream should emit volatile (partial) results followed by final results.
    func transcribe(audioFileURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

// MARK: - Engine Identifier

enum TranscriptionEngineID: String, CaseIterable, Identifiable {
    case appleSpeech = "apple-speech"
    case parakeetV3 = "parakeet-tdt-v3"
    case parakeetV2 = "parakeet-tdt-v2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (Built-in)"
        case .parakeetV3: return "Parakeet TDT v3 — Multilingual"
        case .parakeetV2: return "Parakeet TDT v2 — English Only"
        }
    }

    var description: String {
        switch self {
        case .appleSpeech:
            return "macOS built-in speech recognition. No download required."
        case .parakeetV3:
            return "NVIDIA Parakeet via FluidAudio. 25 languages, ~190x real-time on Apple Silicon."
        case .parakeetV2:
            return "NVIDIA Parakeet English-only. Highest accuracy for English content."
        }
    }

    var requiresDownload: Bool {
        switch self {
        case .appleSpeech: return false
        case .parakeetV3, .parakeetV2: return true
        }
    }

    var downloadSize: String {
        switch self {
        case .appleSpeech: return "Built-in"
        case .parakeetV3, .parakeetV2: return "~500 MB"
        }
    }

    var requiresAppleSilicon: Bool {
        switch self {
        case .appleSpeech: return false
        case .parakeetV3, .parakeetV2: return true
        }
    }

    var iconName: String {
        switch self {
        case .appleSpeech: return "apple.logo"
        case .parakeetV3: return "globe"
        case .parakeetV2: return "bolt.fill"
        }
    }

    /// Relative speed label (based on real-time factor)
    var speedLabel: String {
        switch self {
        case .appleSpeech: return "Speed 80%"
        case .parakeetV3: return "Speed 100%"
        case .parakeetV2: return "Speed 100%"
        }
    }

    /// Accuracy label (based on published WER benchmarks)
    var accuracyLabel: String {
        switch self {
        case .appleSpeech: return "Acc 85%"
        case .parakeetV3: return "Acc 92%"
        case .parakeetV2: return "Acc 96%"
        }
    }

    /// Create the corresponding engine instance.
    func makeEngine() -> TranscriptionEngine {
        switch self {
        case .appleSpeech:
            return AppleSpeechEngine()
        case .parakeetV3:
            return FluidAudioEngine(modelVariant: .v3)
        case .parakeetV2:
            return FluidAudioEngine(modelVariant: .v2)
        }
    }
}
