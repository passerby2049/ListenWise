/*
Abstract:
Real-time transcriber that connects ScreenCaptureKit audio capture
to Apple Speech (SpeechTranscriber/SpeechAnalyzer) with live translation.
*/

import Foundation
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class LiveTranscriber: ObservableObject {
    @Published var isRunning = false
    @Published var confirmedText = ""
    @Published var volatileText = ""
    @Published var audioLevel: Float = 0

    /// Paired segments: each confirmed segment with its translation.
    @Published var segments: [LiveSegment] = []
    /// Whether real-time translation is enabled.
    var translateEnabled = true
    var translateModel: String {
        UserDefaults.standard.string(forKey: "defaultModel") ?? "google/gemini-2.5-flash"
    }
    var translateTargetLang = "中文"

    private let capture = LiveAudioCapture()

    // Apple Speech state
    private var spokenWordTranscriber: SpokenWordTranscriber?
    private var appleSpeechTask: Task<Void, Never>?
    private var translationTasks: [Int: Task<Void, Never>] = [:]

    /// Start live transcription.
    func start() async throws {
        guard !isRunning else { return }
        try await startAppleSpeech()
        isRunning = true
    }

    // MARK: - Apple Speech (system audio via ScreenCaptureKit)

    private func startAppleSpeech() async throws {
        var dummyStory = Story(title: "", text: AttributedString())
        let storyBinding = Binding<Story>(get: { dummyStory }, set: { dummyStory = $0 })

        let transcriber = SpokenWordTranscriber(story: storyBinding)
        self.spokenWordTranscriber = transcriber

        // Set up the speech analyzer (same as sample app's setUpTranscriber)
        try await transcriber.setUpForLiveStream()

        // Poll transcriber's text for UI — insert newline between each finalized segment
        appleSpeechTask = Task { @MainActor in
            var prevFinalizedLen = 0
            while !Task.isCancelled {
                let finalized = String(transcriber.finalizedTranscript.characters)
                let currentLen = finalized.count
                if currentLen > prevFinalizedLen {
                    // New finalized segment arrived
                    let newPart = String(finalized.dropFirst(prevFinalizedLen))
                        .trimmingCharacters(in: .whitespaces)
                    if !newPart.isEmpty {
                        if self.confirmedText.isEmpty {
                            self.confirmedText = newPart
                        } else {
                            self.confirmedText += "\n" + newPart
                        }
                        // Add segment and kick off translation
                        let segIndex = self.segments.count
                        self.segments.append(LiveSegment(source: newPart, translation: ""))
                        if self.translateEnabled && !self.translateModel.isEmpty {
                            self.translateSegment(at: segIndex, text: newPart)
                        }
                    }
                    prevFinalizedLen = currentLen
                }
                self.volatileText = String(transcriber.volatileTranscript.characters)
                self.audioLevel = self.capture.audioLevel
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Feed ScreenCaptureKit audio to the speech transcriber
        // Apple Speech needs 48kHz for best quality (its analyzer format is 16kHz Int16,
        // but BufferConverter handles the conversion)
        capture.onAudioBuffer = { [weak transcriber] buffer in
            guard let transcriber else { return }
            Task {
                try? await transcriber.streamAudioToTranscriber(buffer)
            }
        }

        try await capture.startCapture()
    }

    // MARK: - Stop

    @discardableResult
    func stop() async -> String {
        guard isRunning else { return "" }

        await capture.stopCapture()

        if let transcriber = spokenWordTranscriber {
            appleSpeechTask?.cancel()
            appleSpeechTask = nil
            await transcriber.stopLiveStream()
            spokenWordTranscriber = nil
        }

        let finalText = confirmedText
        isRunning = false
        audioLevel = 0

        // Wait for pending translations with a 5-second timeout
        let pending = translationTasks
        translationTasks = [:]
        await withTaskGroup(of: Void.self) { group in
            // Await all pending translation tasks
            for (_, task) in pending {
                group.addTask { await task.value }
            }
            // Timeout: cancel remaining after 5 seconds
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                for (_, task) in pending { task.cancel() }
            }
            await group.waitForAll()
        }

        return finalText
    }

    /// The current full display text (confirmed + volatile).
    var displayText: String {
        if volatileText.isEmpty { return confirmedText }
        if confirmedText.isEmpty { return volatileText }
        return confirmedText + " " + volatileText
    }

    // MARK: - Real-time Translation

    private func translateSegment(at index: Int, text: String) {
        let prompt = """
        This is a real-time speech-to-text transcription segment. Please:
        1. Fix any misrecognized proper nouns, names, places (e.g. "Bideen" → "Biden", "Ukrane" → "Ukraine"). Use context to infer correct spelling.
        2. Fix obvious speech-to-text errors while keeping the original meaning.
        3. Translate the corrected text into \(translateTargetLang).

        Output exactly two lines, nothing else:
        Line 1: the corrected original text (if no correction needed, output the original as-is)
        Line 2: the \(translateTargetLang) translation

        Transcription:
        \(text)
        """

        let task = Task { @MainActor in
            var raw = ""
            do {
                for try await token in AIProvider.stream(prompt: prompt, model: translateModel) {
                    raw += token
                    if index < self.segments.count {
                        let parsed = Self.parseTwoLines(raw)
                        if let corrected = parsed.corrected,
                           corrected != self.segments[index].source {
                            self.segments[index].source = corrected
                            self.rebuildConfirmedText()
                        }
                        if let translation = parsed.translation, !translation.isEmpty {
                            self.segments[index].translation = translation
                        }
                    }
                }
            } catch {
                if index < self.segments.count && self.segments[index].translation.isEmpty {
                    self.segments[index].translation = "⚠️ \(error.localizedDescription)"
                }
            }
            self.translationTasks.removeValue(forKey: index)
        }
        translationTasks[index] = task
    }

    /// Parse LLM two-line output with tolerance for empty lines and "Line N:" prefixes.
    static func parseTwoLines(_ raw: String) -> (corrected: String?, translation: String?) {
        let prefixPattern = /^(line\s*\d+\s*[:：]\s*)/
        let nonEmptyLines = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                if let match = s.lowercased().prefixMatch(of: prefixPattern) {
                    s = String(s.dropFirst(match.0.count)).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty }

        let corrected = nonEmptyLines.count >= 1 ? nonEmptyLines[0] : nil
        let translation = nonEmptyLines.count >= 2 ? nonEmptyLines[1] : nil
        return (corrected, translation)
    }

    private func rebuildConfirmedText() {
        confirmedText = segments.map(\.source).joined(separator: "\n")
    }

}
