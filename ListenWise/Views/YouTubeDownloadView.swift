/*
Abstract:
YouTube video download sheet — uses yt-dlp to download and auto-import.
*/

import SwiftUI
import Foundation

struct YouTubeDownloadView: View {
    @Binding var downloadedURL: URL?
    @Binding var youtubeSourceURL: String
    @Environment(\.dismiss) var dismiss

    @State private var urlText: String = ""
    @State private var isDownloading = false
    @State private var progress: String = ""
    @State private var errorMessage: String = ""
    @State private var downloadTask: Process?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download from YouTube")
                .font(.headline)

            HStack {
                TextField("Paste YouTube URL...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDownloading)

                if isDownloading {
                    Button("Cancel") { cancelDownload() }
                        .foregroundStyle(.red)
                } else {
                    Button("Download") { startDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(urlText.isEmpty || !isValidURL)
                }
            }

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.isEmpty ? "Starting download..." : progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Requires [yt-dlp](https://github.com/yt-dlp/yt-dlp) installed via Homebrew")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 500)
    }

    var isValidURL: Bool {
        urlText.contains("youtube.com/") || urlText.contains("youtu.be/")
    }

    func startDownload() {
        guard !urlText.isEmpty else { return }
        isDownloading = true
        errorMessage = ""
        progress = "Looking for yt-dlp..."

        let url = urlText
        Task.detached {
            // Download to temp directory
            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ListenWise", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let outputTemplate = outputDir.appendingPathComponent("%(title).80s.%(ext)s").path

            // Escape single quotes in URL for shell
            let safeURL = url.replacingOccurrences(of: "'", with: "'\\''")
            let safeTemplate = outputTemplate.replacingOccurrences(of: "'", with: "'\\''")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-c",
                """
                export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
                yt-dlp -f 'bestvideo[vcodec^=avc1][height<=720]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1][height<=720]/best[height<=720]' \
                --merge-output-format mp4 --no-playlist --newline \
                -o '\(safeTemplate)' '\(safeURL)'
                """
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            await MainActor.run {
                downloadTask = process
                progress = "Downloading..."
            }

            // Read output for progress
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                // Extract progress percentage
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { @MainActor in
                        // Show last meaningful line
                        let lines = trimmed.components(separatedBy: "\r")
                        if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                            let clean = last.trimmingCharacters(in: .whitespacesAndNewlines)
                            if clean.count < 200 {
                                progress = clean
                            }
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to run yt-dlp: \(error.localizedDescription)"
                    isDownloading = false
                }
                return
            }

            pipe.fileHandleForReading.readabilityHandler = nil

            guard process.terminationStatus == 0 else {
                // Read remaining stderr for error details
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                await MainActor.run {
                    if process.terminationStatus == 127 {
                        errorMessage = "yt-dlp not found. Install with: brew install yt-dlp"
                    } else {
                        let detail = errMsg.components(separatedBy: "\n")
                            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                        errorMessage = "Download failed: \(detail.isEmpty ? "exit code \(process.terminationStatus)" : detail)"
                    }
                    isDownloading = false
                }
                return
            }

            // Find the downloaded file (most recent mp4 in output dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.contentModificationDateKey]))
            let mp4Files = files?
                .filter { $0.pathExtension == "mp4" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return da > db
                }

            guard let downloadedFile = mp4Files?.first else {
                await MainActor.run {
                    errorMessage = "Download completed but file not found"
                    isDownloading = false
                }
                return
            }

            // Copy to a permanent location in Application Support
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ListenWise", isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let destURL = appSupport.appendingPathComponent(downloadedFile.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL) // remove if exists
            try? FileManager.default.moveItem(at: downloadedFile, to: destURL)

            await MainActor.run {
                youtubeSourceURL = url
                downloadedURL = destURL
                isDownloading = false
                dismiss()
            }
        }
    }

    func cancelDownload() {
        downloadTask?.terminate()
        downloadTask = nil
        isDownloading = false
        progress = ""
    }
}
