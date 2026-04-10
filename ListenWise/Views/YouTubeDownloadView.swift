/*
Abstract:
YouTube video import UI — user pastes a URL, progress is shown, audio is downloaded.
All API/download logic lives in YouTubeService.swift (YouTubeHelper enum).
*/

import SwiftUI
import Foundation
import AVFoundation

struct YouTubeDownloadView: View {
    @Binding var downloadedURL: URL?
    @Binding var youtubeSourceURL: String
    @Binding var youtubeStreamingURL: String
    @Environment(\.dismiss) var dismiss

    @State private var urlText: String = ""
    @State private var isDownloading = false
    @State private var progress: String = ""
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from YouTube")
                .font(.headline)

            HStack {
                TextField("Paste YouTube URL...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDownloading)

                if isDownloading {
                    Button("Cancel") {
                        isDownloading = false
                        progress = ""
                    }
                    .foregroundStyle(.red)
                } else {
                    Button("Import") { startDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(urlText.isEmpty || !isValidURL)
                }
            }

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.isEmpty ? "Starting..." : progress)
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
        progress = "Fetching video info..."

        let url = urlText
        Task.detached {
            do {
                // 1) Scrape watch page for visitorData and signatureTimestamp
                await MainActor.run { progress = "Fetching page info..." }
                let pageInfo = try await YouTubeHelper.scrapeWatchPage(for: url)

                // 2) Fetch HLS URL via IOS client (for HD playback)
                await MainActor.run { progress = "Getting streaming URL..." }
                let hlsURL = await YouTubeHelper.fetchHLSURL(for: url)

                // 3) Fetch audio stream URL via ANDROID_VR client (for download)
                await MainActor.run { progress = "Getting audio stream..." }
                let audioInfo = try await YouTubeHelper.fetchAudioStream(
                    for: url,
                    visitorData: pageInfo.visitorData,
                    signatureTimestamp: pageInfo.signatureTimestamp
                )

                // 4) Download audio in 1MB chunks via curl with Range headers
                let outputDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ListenWise", isDirectory: true)
                    .appendingPathComponent("Downloads", isDirectory: true)
                try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                let safeTitle = (audioInfo.title ?? "youtube_audio")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .prefix(80)
                let rawFile = outputDir.appendingPathComponent("\(safeTitle)_raw.m4a")
                let finalFile = outputDir.appendingPathComponent("\(safeTitle).m4a")

                await MainActor.run {
                    progress = "Downloading audio (\(ByteCountFormatter.string(fromByteCount: audioInfo.contentLength, countStyle: .file)))..."
                }

                try await YouTubeHelper.downloadWithRangeChunks(
                    from: audioInfo.url,
                    to: rawFile,
                    contentLength: audioInfo.contentLength
                ) { downloaded, total in
                    Task { @MainActor in
                        let pct = Int(Double(downloaded) / Double(total) * 100)
                        let dlStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                        progress = "Downloading: \(dlStr) / \(totalStr) (\(pct)%)"
                    }
                }

                // 5) Re-encode to standard m4a
                await MainActor.run { progress = "Converting audio..." }
                try await YouTubeHelper.reencodeToM4A(from: rawFile, to: finalFile)
                try? FileManager.default.removeItem(at: rawFile)

                // 6) Done
                await MainActor.run {
                    youtubeSourceURL = url
                    youtubeStreamingURL = hlsURL ?? ""
                    downloadedURL = finalFile
                    isDownloading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Error: \(error.localizedDescription)"
                    isDownloading = false
                }
            }
        }
    }
}
