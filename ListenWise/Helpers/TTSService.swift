/*
Abstract:
Central text-to-speech service. Prefers PocketTTS with a user-cloned voice
when both the model and an active `ClonedVoiceEntry` are present; otherwise
falls back to `AVSpeechSynthesizer` so the speaker button always works.
*/

import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

@MainActor
@Observable
final class TTSService: NSObject {
    static let shared = TTSService()

    // MARK: - Observable state

    /// True if the PocketTTS model has been downloaded in this install.
    var isModelDownloaded: Bool = false

    var isDownloadingModel: Bool = false
    var downloadProgress: Double = 0
    var downloadError: String = ""

    var isCloning: Bool = false
    var cloneError: String = ""

    /// The example-sentence currently being spoken, used by the speaker
    /// button to switch between idle and "playing" icons.
    var currentSpeakingText: String?

    /// Observable mirror of `AppPreferences.activeClonedVoiceID` so that
    /// SwiftUI views driven off `TTSService.shared` re-render on switch.
    /// `AppPreferences`' computed properties aren't observable themselves.
    var activeVoiceID: UUID?

    /// Observable mirror of `AppPreferences.clonedVoices` for the same
    /// reason — the UserDefaults-backed computed property on
    /// `AppPreferences` doesn't participate in `@Observable` tracking, so
    /// SwiftUI wouldn't re-render the voice list after a clone/delete.
    var voices: [ClonedVoiceEntry] = []

    // MARK: - Private state

    private let prefs = AppPreferences()
    private var pocketManager: PocketTtsManager?
    private var activeVoiceData: PocketTtsVoiceData?
    private var loadedVoiceID: UUID?
    private var player: AVAudioPlayer?
    private let speechSynth = AVSpeechSynthesizer()

    // MARK: - Init

    override init() {
        super.init()
        isModelDownloaded = prefs.pocketTTSDownloaded
        activeVoiceID = prefs.activeClonedVoiceID
        voices = prefs.clonedVoices
        speechSynth.delegate = self
    }

    // MARK: - Voices directory

    private var voicesDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise", isDirectory: true)
            .appendingPathComponent("Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func voiceBinURL(for id: UUID) -> URL {
        voicesDir.appendingPathComponent("\(id.uuidString).bin")
    }

    // MARK: - Model download

    func downloadModel() async {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        downloadProgress = 0
        downloadError = ""
        defer { isDownloadingModel = false }

        do {
            _ = try await PocketTtsResourceDownloader.ensureModels(progressHandler: { progress in
                Task { @MainActor in
                    TTSService.shared.downloadProgress = progress.fractionCompleted
                }
            })
            // Mimi encoder is required for voice cloning; pull it now so the
            // first clone attempt doesn't trigger a second silent download.
            _ = try await PocketTtsResourceDownloader.ensureMimiEncoder()
            prefs.pocketTTSDownloaded = true
            isModelDownloaded = true
        } catch {
            downloadError = error.localizedDescription
        }
    }

    /// Clear the flag and drop in-memory state. We can't easily find
    /// FluidAudio's cache directory from outside the package, so this only
    /// disables the feature — the on-disk model stays cached and can be
    /// re-used after toggling the download button again.
    func forgetModel() {
        prefs.pocketTTSDownloaded = false
        isModelDownloaded = false
        pocketManager = nil
        activeVoiceData = nil
        loadedVoiceID = nil
    }

    // MARK: - Manager lifecycle

    private func ensureManager() async throws -> PocketTtsManager {
        if let mgr = pocketManager {
            return mgr
        }
        let mgr = PocketTtsManager()
        try await mgr.initialize()
        pocketManager = mgr
        return mgr
    }

    // MARK: - Voice cloning

    /// Clone a voice from an audio URL (WAV/MP3/M4A — `cloneVoice` handles
    /// any sample rate). Saves the voice blob to disk, appends metadata to
    /// `clonedVoices`, and auto-activates if it's the first voice.
    @discardableResult
    func cloneVoice(from audioURL: URL, name: String) async throws -> ClonedVoiceEntry {
        guard isModelDownloaded else {
            throw TTSError.modelNotDownloaded
        }
        isCloning = true
        cloneError = ""
        defer { isCloning = false }

        do {
            let mgr = try await ensureManager()
            let voiceData = try await mgr.cloneVoice(from: audioURL)

            let id = UUID()
            let destURL = voiceBinURL(for: id)
            try mgr.saveClonedVoice(voiceData, to: destURL)

            let duration = audioDuration(of: audioURL)
            let entry = ClonedVoiceEntry(id: id, name: name, durationSeconds: duration)

            var updated = prefs.clonedVoices
            updated.append(entry)
            prefs.clonedVoices = updated
            voices = updated
            if prefs.activeClonedVoiceID == nil {
                prefs.activeClonedVoiceID = id
                activeVoiceID = id
            }
            return entry
        } catch {
            cloneError = error.localizedDescription
            throw error
        }
    }

    func deleteVoice(id: UUID) {
        try? FileManager.default.removeItem(at: voiceBinURL(for: id))
        var updated = prefs.clonedVoices
        updated.removeAll { $0.id == id }
        prefs.clonedVoices = updated
        voices = updated
        if prefs.activeClonedVoiceID == id {
            let next = updated.first?.id
            prefs.activeClonedVoiceID = next
            activeVoiceID = next
        }
        if loadedVoiceID == id {
            activeVoiceData = nil
            loadedVoiceID = nil
        }
    }

    func setActiveVoice(id: UUID?) {
        prefs.activeClonedVoiceID = id
        activeVoiceID = id
        // Force reload next time speak() runs.
        activeVoiceData = nil
        loadedVoiceID = nil
    }

    // MARK: - Speak

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        currentSpeakingText = trimmed

        if isModelDownloaded, let activeID = prefs.activeClonedVoiceID {
            do {
                try await speakWithPocketTTS(trimmed, voiceID: activeID)
                return
            } catch {
                // Swallow and fall back — never leave the user without audio.
            }
        }

        speakWithAppleTTS(trimmed)
    }

    func stop() {
        player?.stop()
        player = nil
        if speechSynth.isSpeaking {
            speechSynth.stopSpeaking(at: .immediate)
        }
        currentSpeakingText = nil
    }

    // MARK: - Private speak implementations

    private func speakWithPocketTTS(_ text: String, voiceID: UUID) async throws {
        let mgr = try await ensureManager()

        if loadedVoiceID != voiceID || activeVoiceData == nil {
            let url = voiceBinURL(for: voiceID)
            activeVoiceData = try mgr.loadClonedVoice(from: url)
            loadedVoiceID = voiceID
        }
        guard let voiceData = activeVoiceData else {
            throw TTSError.voiceLoadFailed
        }

        let wav = try await mgr.synthesize(text: text, voiceData: voiceData)
        let newPlayer = try AVAudioPlayer(data: wav)
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
    }

    private func speakWithAppleTTS(_ text: String) {
        let utter = AVSpeechUtterance(string: text)
        utter.voice = AVSpeechSynthesisVoice(language: "en-US")
        utter.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        speechSynth.speak(utter)
    }

    // MARK: - Helpers

    private func audioDuration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case modelNotDownloaded
    case voiceLoadFailed

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Voice synthesis model is not downloaded. Open Settings → Voice Cloning to download it."
        case .voiceLoadFailed:
            return "Failed to load the cloned voice data."
        }
    }
}

// MARK: - Delegates

extension TTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if TTSService.shared.player === player {
                TTSService.shared.player = nil
                TTSService.shared.currentSpeakingText = nil
            }
        }
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            TTSService.shared.currentSpeakingText = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            TTSService.shared.currentSpeakingText = nil
        }
    }
}
