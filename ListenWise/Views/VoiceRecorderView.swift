/*
Abstract:
Sheet for recording a short voice sample used as a cloning reference.
Writes to a temp WAV file and calls back with the URL + chosen name.
*/

import SwiftUI
import AVFoundation

struct VoiceRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    var onFinish: (URL, String) -> Void

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var elapsed: Double = 0
    @State private var name: String = ""
    @State private var tempURL: URL?
    @State private var didSave = false
    @State private var errorMessage: String = ""

    private let maxDuration: Double = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Voice Sample")
                .font(.title3.bold())

            Text("Read a short paragraph in a natural voice. 10–30 seconds works best.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Voice name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button {
                    if isRecording { stopRecording() } else { startRecording() }
                } label: {
                    Label(
                        isRecording ? "Stop" : "Start Recording",
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .controlSize(.large)

                if isRecording || elapsed > 0 {
                    Text(String(format: "%.1fs / %.0fs", elapsed, maxDuration))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    guard let url = tempURL else { return }
                    didSave = true
                    onFinish(url, name.isEmpty ? "My Voice" : name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tempURL == nil || isRecording)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task(id: isRecording) {
            guard isRecording else { return }
            // Poll the recorder until it stops (hit maxDuration or the
            // user pressed Stop). Using `.task` instead of a Foundation
            // Timer keeps everything on the main actor and auto-cancels
            // on disappear.
            while !Task.isCancelled, let rec = recorder, rec.isRecording {
                elapsed = rec.currentTime
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let rec = recorder {
                elapsed = rec.currentTime
                stopRecording()
            }
        }
        .onDisappear { cleanup() }
    }

    private func startRecording() {
        errorMessage = ""
        // If the user re-records, drop the previous scratch file so we
        // don't leave stragglers in `temporaryDirectory`.
        if let old = tempURL {
            try? FileManager.default.removeItem(at: old)
            tempURL = nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-voice-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.prepareToRecord()
            rec.record(forDuration: maxDuration)
            recorder = rec
            tempURL = url
            elapsed = 0
            isRecording = true
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        recorder?.stop()
        isRecording = false
    }

    /// Runs on dismiss. Stop any live recording and, unless the user
    /// actually hit Save, delete the scratch WAV from
    /// `temporaryDirectory` so we don't leak it.
    private func cleanup() {
        stopRecording()
        recorder = nil
        if !didSave, let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
    }
}
