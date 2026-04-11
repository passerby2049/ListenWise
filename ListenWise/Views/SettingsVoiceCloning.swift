/*
Abstract:
Settings pane for PocketTTS voice cloning — download model, import or
record reference clips, manage the user's voice library.
*/

import SwiftUI
import UniformTypeIdentifiers

struct SettingsVoiceCloning: View {
    @State private var tts = TTSService.shared

    @State private var isImporting = false
    @State private var isRecording = false
    @State private var importedURL: URL?
    @State private var pendingName: String = ""
    @State private var showingNameSheet = false
    @State private var pendingImportURL: URL?

    var body: some View {
        Form {
            Section {
                if tts.isModelDownloaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Voice synthesis model ready")
                        Spacer()
                        Button("Forget") { tts.forgetModel() }
                            .controlSize(.small)
                    }
                } else if tts.isDownloadingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading model…")
                        ProgressView(value: tts.downloadProgress)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Download the PocketTTS model to clone your own voice. If you skip this, example sentences will be read using the built-in system voice.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Download Model (~400 MB)") {
                            Task { await tts.downloadModel() }
                        }
                        if !tts.downloadError.isEmpty {
                            Text(tts.downloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("Voice Synthesis Model")
            }

            if tts.isModelDownloaded {
                Section {
                    if tts.voices.isEmpty {
                        Text("No cloned voices yet. Add one to use it for reading example sentences.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tts.voices) { voice in
                            voiceRow(voice)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Import Audio…", systemImage: "waveform.badge.plus")
                        }
                        Button {
                            isRecording = true
                        } label: {
                            Label("Record Sample…", systemImage: "mic.circle")
                        }
                        if tts.isCloning {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if !tts.cloneError.isEmpty {
                        Text(tts.cloneError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Cloned Voices")
                } footer: {
                    Text("Provide a 10–30 second clip of clean speech. Longer or noisier clips don't improve results.")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $isRecording) {
            VoiceRecorderView { url, name in
                Task { await performClone(from: url, name: name) }
            }
        }
        .sheet(isPresented: $showingNameSheet, onDismiss: releasePendingImport) {
            nameSheet
        }
    }

    // MARK: - Voice row

    @ViewBuilder
    private func voiceRow(_ voice: ClonedVoiceEntry) -> some View {
        let isActive = tts.activeVoiceID == voice.id
        HStack(spacing: 12) {
            Button {
                tts.setActiveVoice(id: voice.id)
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.body)
                Text(String(format: "%.1fs · %@", voice.durationSeconds, voice.createdAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                tts.deleteVoice(id: voice.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Name sheet (for file import)

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name This Voice")
                .font(.title3.bold())
            TextField("Voice name", text: $pendingName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) {
                    showingNameSheet = false
                }
                Spacer()
                Button("Clone") {
                    guard let url = pendingImportURL else { return }
                    let name = pendingName.isEmpty ? "Imported Voice" : pendingName
                    // Hand the URL off to the Task and let the sheet's
                    // onDismiss handle the scope release uniformly.
                    pendingImportURL = nil
                    showingNameSheet = false
                    Task {
                        await performClone(from: url, name: name)
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if url.startAccessingSecurityScopedResource() {
                pendingImportURL = url
                pendingName = url.deletingPathExtension().lastPathComponent
                showingNameSheet = true
            }
        case .failure:
            break
        }
    }

    private func performClone(from url: URL, name: String) async {
        do {
            _ = try await tts.cloneVoice(from: url, name: name)
        } catch {
            // Error surfaces via tts.cloneError.
        }
    }

    /// Safety net for the name sheet: if the user dismisses via ESC or
    /// clicking outside without hitting Cancel/Clone, release the
    /// security-scoped resource we acquired in `handleImport`.
    private func releasePendingImport() {
        if let url = pendingImportURL {
            url.stopAccessingSecurityScopedResource()
            pendingImportURL = nil
        }
        pendingName = ""
    }
}
