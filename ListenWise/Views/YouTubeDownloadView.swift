/*
Abstract:
YouTube video import — uses innertube API (ANDROID_VR client) to download audio
for transcription, and IOS client to get HLS streaming URL for HD playback.
No external dependencies required.
*/

import SwiftUI
import Foundation
import AVFoundation
import YouTubeKit

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

// MARK: - YouTube Helpers

enum YouTubeHelper {

    struct PageInfo {
        let visitorData: String
        let signatureTimestamp: Int?
    }

    struct AudioStreamInfo {
        let title: String?
        let url: URL
        let contentLength: Int64
    }

    struct VideoStreamInfo {
        let url: URL
        let qualityLabel: String
        let width: Int
        let height: Int
    }

    // MARK: - Video ID Extraction

    static func extractVideoID(_ urlString: String) -> String? {
        if urlString.contains("youtu.be/"),
           let url = URL(string: urlString) {
            return url.lastPathComponent
        }
        if let url = URLComponents(string: urlString),
           let v = url.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        return nil
    }

    // MARK: - curl Helper

    /// Run curl and return stdout as String. Uses curl instead of URLSession
    /// because YouTube's bot detection blocks URLSession from sandboxed apps.
    private static func curlGet(_ url: String, headers: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = ["-s", "-L", url]
        for h in headers { args += ["-H", h] }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run curl POST and return stdout as String.
    /// Writes body to a temp file to avoid argument escaping issues.
    private static func curlPost(_ url: String, body: String, headers: [String] = []) throws -> String {
        // Write body to temp file
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try body.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = ["-s", "-L", "-X", "POST", "--data-binary", "@\(tempFile.path)", url]
        for h in headers { args += ["-H", h] }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Step 1: Scrape Watch Page

    /// Scrape the YouTube watch page to extract visitorData and signatureTimestamp.
    /// These are required for ANDROID_VR client to return downloadable URLs.
    /// Uses curl to avoid YouTube's bot detection on sandboxed URLSession.
    static func scrapeWatchPage(for urlString: String) async throws -> PageInfo {
        guard let videoID = extractVideoID(urlString) else { throw URLError(.badURL) }

        // Fetch watch page HTML via curl
        let html = try curlGet(
            "https://youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1",
            headers: ["User-Agent: Mozilla/5.0", "Accept-Language: en-US,en"]
        )

        guard !html.isEmpty else {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch watch page"])
        }

        // Check if YouTube returned a bot check page
        if html.contains("Sign in to confirm") || html.contains("confirm you're not a bot") {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "YouTube bot detection on watch page"])
        }

        // Extract visitorData from "VISITOR_DATA":"..." in ytcfg
        var visitorData = ""
        if let range = html.range(of: "\"VISITOR_DATA\":\"") {
            let valueStart = range.upperBound
            if let valueEnd = html[valueStart...].range(of: "\"") {
                visitorData = String(html[valueStart..<valueEnd.lowerBound])
            }
        }

        print("[YouTube] visitorData: \(visitorData.prefix(30))..., html length: \(html.count)")

        // Extract player JS URL and signature timestamp
        var signatureTimestamp: Int?
        if let jsMatch = html.range(of: "/s/player/", options: .literal) {
            let jsAfter = html[jsMatch.lowerBound...]
            if let endQuote = jsAfter.range(of: "\"") {
                let jsPath = String(jsAfter[..<endQuote.lowerBound])
                let jsContent = try curlGet(
                    "https://youtube.com\(jsPath)",
                    headers: ["User-Agent: Mozilla/5.0"]
                )
                if let stsRange = jsContent.range(of: "signatureTimestamp:") ??
                    jsContent.range(of: "sts:") {
                    let after = jsContent[stsRange.upperBound...]
                    let digits = after.prefix(while: { $0.isNumber || $0.isWhitespace })
                        .trimmingCharacters(in: .whitespaces)
                    signatureTimestamp = Int(digits)
                }
            }
        }

        print("[YouTube] signatureTimestamp: \(signatureTimestamp ?? -1)")
        return PageInfo(visitorData: visitorData, signatureTimestamp: signatureTimestamp)
    }

    // MARK: - Step 2: Fetch HLS URL (IOS Client)

    /// Fetch HLS streaming URL via IOS client for HD playback.
    static func fetchHLSURL(for urlString: String) async -> String? {
        guard let videoID = extractVideoID(urlString) else { return nil }
        let body = "{\"contentCheckOk\":true,\"context\":{\"client\":{\"clientName\":\"IOS\",\"clientVersion\":\"21.13.6\",\"deviceMake\":\"Apple\",\"deviceModel\":\"iPhone16,2\",\"hl\":\"en\",\"osName\":\"iPhone\",\"osVersion\":\"26.4.23E246\",\"userAgent\":\"com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 26_4 like Mac OS X;)\",\"utcOffsetMinutes\":0}},\"playbackContext\":{\"contentPlaybackContext\":{\"html5Preference\":\"HTML5_PREF_WANTS\"}},\"racyCheckOk\":true,\"videoId\":\"\(videoID)\"}"

        guard let response = try? curlPost(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            body: body,
            headers: [
                "Content-Type: application/json",
                "User-Agent: com.google.ios.youtube/21.13.6 (iPhone16,2; U; CPU iOS 26_4 like Mac OS X;)"
            ]
        ), let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let streaming = json["streamingData"] as? [String: Any],
           let hlsURL = streaming["hlsManifestUrl"] as? String else {
            print("[YouTube] fetchHLSURL failed")
            return nil
        }
        print("[YouTube] HLS URL: \(hlsURL.prefix(80))...")
        return hlsURL
    }

    // MARK: - Fetch Playable Stream via YouTubeKit

    /// Use YouTubeKit to get the best video stream URL.
    /// Priority: HD adaptive H.264 (720p) > progressive (360p).
    /// HD streams are video-only but that's fine — audio plays from local file.
    static func fetchBestStreamURL(for urlString: String) async throws -> URL {
        guard let videoID = extractVideoID(urlString) else { throw URLError(.badURL) }

        let yt = YouTubeKit.YouTube(videoID: videoID)
        let streams = try await yt.streams

        for s in streams where s.includesVideoTrack {
            let vc = s.videoCodec.map { "\($0)" } ?? "-"
            print("[YouTubeKit] itag=\(s.itag) \(s.isProgressive ? "prog" : "adap") \(vc) \(s.videoResolution.map { "\($0)p" } ?? "-") playable=\(s.isNativelyPlayable)")
        }

        // 1) Best HD adaptive video (video-only, H.264, highest res)
        let hdVideo = streams
            .filter { $0.isNativelyPlayable && $0.includesVideoTrack && !$0.includesAudioTrack }
            .sorted(by: { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) })

        if let best = hdVideo.first {
            print("[YouTubeKit] Using HD: itag=\(best.itag) \(best.videoResolution.map { "\($0)p" } ?? "?")")
            return best.url
        }

        // 2) Fallback: progressive (video+audio)
        let progressive = streams
            .filter { $0.isProgressive && $0.isNativelyPlayable }
            .sorted(by: { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) })

        if let best = progressive.first {
            print("[YouTubeKit] Using progressive: itag=\(best.itag) \(best.videoResolution.map { "\($0)p" } ?? "?")")
            return best.url
        }

        throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "No playable stream found"])
    }

    // MARK: - Step 2b: Fetch MP4 Video Stream (ANDROID_VR Client)

    struct HDStreamURLs {
        let videoURL: URL?       // adaptive HD video-only (720p H.264)
        let progressiveURL: URL? // fallback progressive (360p video+audio)
    }

    /// Fetch HD video stream URL (adaptive, video-only) + progressive fallback via YouTubeKit.
    static func fetchHDStreamURLs(for urlString: String) async throws -> HDStreamURLs {
        guard let videoID = extractVideoID(urlString) else { throw URLError(.badURL) }

        let yt = YouTubeKit.YouTube(videoID: videoID)
        let streams = try await yt.streams

        for s in streams where s.includesVideoTrack {
            let vc = s.videoCodec.map { "\($0)" } ?? "-"
            print("[YouTubeKit] itag=\(s.itag) \(s.isProgressive ? "prog" : "adap") \(vc) \(s.videoResolution.map { "\($0)p" } ?? "-") playable=\(s.isNativelyPlayable)")
        }

        // Best adaptive HD video-only H.264 stream (720p+)
        let hdVideo = streams
            .filter { $0.isNativelyPlayable && $0.includesVideoTrack && !$0.includesAudioTrack && ($0.videoResolution ?? 0) > 360 }
            .sorted(by: { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) })
            .first

        // Best progressive (video+audio) fallback
        let progressive = streams
            .filter { $0.isProgressive && $0.isNativelyPlayable }
            .sorted(by: { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) })
            .first

        if let hd = hdVideo {
            print("[YouTubeKit] HD stream: itag=\(hd.itag) \(hd.videoResolution.map { "\($0)p" } ?? "?")")
        }
        if let prog = progressive {
            print("[YouTubeKit] Progressive fallback: itag=\(prog.itag) \(prog.videoResolution.map { "\($0)p" } ?? "?")")
        }

        return HDStreamURLs(videoURL: hdVideo?.url, progressiveURL: progressive?.url)
    }

    /// Fetch a direct MP4 H.264 progressive video URL from ANDROID_VR client.
    /// This is more reliable than HLS for macOS AVPlayer:
    ///   - No VP9 codec issues (ANDROID_VR returns H.264/MP4)
    ///   - Direct URL, no manifest parsing needed
    ///   - No signature decryption required
    static func fetchVideoStreamURL(
        for urlString: String,
        visitorData: String,
        signatureTimestamp: Int?,
        preferredMaxHeight: Int = 720
    ) async -> VideoStreamInfo? {
        guard let videoID = extractVideoID(urlString) else { return nil }

        let stsValue = signatureTimestamp.map { String($0) } ?? "null"
        let bodyJSON = "{\"context\":{\"client\":{\"clientName\":\"ANDROID_VR\",\"clientVersion\":\"1.65.10\",\"androidSdkVersion\":32,\"deviceModel\":\"Quest 3\"}},\"videoId\":\"\(videoID)\",\"playbackContext\":{\"contentPlaybackContext\":{\"html5Preference\":\"HTML5_PREF_WANTS\",\"signatureTimestamp\":\(stsValue)}},\"contentCheckOk\":true,\"racyCheckOk\":true}"

        guard let response = try? curlPost(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            body: bodyJSON,
            headers: [
                "Content-Type: application/json",
                "User-Agent: com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                "X-Goog-Visitor-Id: \(visitorData)",
                "X-Youtube-Client-Version: 1.65.10",
                "X-Youtube-Client-Name: 28",
                "Origin: https://www.youtube.com"
            ]
        ), let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let streaming = json["streamingData"] as? [String: Any] else {
            print("[YouTube] fetchVideoStreamURL: failed to get streaming data")
            return nil
        }

        // Look for progressive (video+audio) MP4 streams first (itag 18 = 360p, itag 22 = 720p)
        if let formats = streaming["formats"] as? [[String: Any]] {
            let mp4Streams = formats.filter {
                ($0["mimeType"] as? String)?.hasPrefix("video/mp4") == true && $0["url"] is String
            }.sorted {
                ($0["height"] as? Int ?? 0) > ($1["height"] as? Int ?? 0)
            }

            // Pick the best progressive stream at or below the preferred max height
            let best = mp4Streams.first { ($0["height"] as? Int ?? 0) <= preferredMaxHeight }
                ?? mp4Streams.last  // fall back to smallest

            if let stream = best,
               let urlStr = stream["url"] as? String,
               let url = URL(string: urlStr) {
                let info = VideoStreamInfo(
                    url: url,
                    qualityLabel: stream["qualityLabel"] as? String ?? "\(stream["height"] as? Int ?? 0)p",
                    width: stream["width"] as? Int ?? 0,
                    height: stream["height"] as? Int ?? 0
                )
                print("[YouTube] Video stream: \(info.qualityLabel) (\(info.width)x\(info.height))")
                return info
            }
        }

        print("[YouTube] fetchVideoStreamURL: no progressive MP4 found")
        return nil
    }

    /// Refresh the streaming URL for a video — call when the saved URL has expired (403).
    /// Returns (hlsURL, videoStreamURL) — either may be nil.
    static func refreshStreamingURLs(for urlString: String) async -> (hls: String?, videoMP4: URL?) {
        // Scrape page first to get visitor data
        guard let pageInfo = try? await scrapeWatchPage(for: urlString) else {
            return (nil, nil)
        }

        let hls = await fetchHLSURL(for: urlString)
        let mp4 = await fetchVideoStreamURL(
            for: urlString,
            visitorData: pageInfo.visitorData,
            signatureTimestamp: pageInfo.signatureTimestamp
        )

        return (hls, mp4?.url)
    }

    // MARK: - Step 3: Fetch Audio Stream (ANDROID_VR Client)

    /// Fetch downloadable audio stream URL via ANDROID_VR client.
    /// Requires visitorData and signatureTimestamp from the watch page.
    static func fetchAudioStream(
        for urlString: String,
        visitorData: String,
        signatureTimestamp: Int?
    ) async throws -> AudioStreamInfo {
        guard let videoID = extractVideoID(urlString) else { throw URLError(.badURL) }

        let stsValue = signatureTimestamp.map { String($0) } ?? "null"
        let bodyJSON = "{\"context\":{\"client\":{\"clientName\":\"ANDROID_VR\",\"clientVersion\":\"1.65.10\",\"androidSdkVersion\":32,\"deviceModel\":\"Quest 3\"}},\"videoId\":\"\(videoID)\",\"playbackContext\":{\"contentPlaybackContext\":{\"html5Preference\":\"HTML5_PREF_WANTS\",\"signatureTimestamp\":\(stsValue)}},\"contentCheckOk\":true,\"racyCheckOk\":true}"

        let response = try curlPost(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            body: bodyJSON,
            headers: [
                "Content-Type: application/json",
                "User-Agent: com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                "X-Goog-Visitor-Id: \(visitorData)",
                "X-Youtube-Client-Version: 1.65.10",
                "X-Youtube-Client-Name: 28",
                "Origin: https://www.youtube.com"
            ]
        )

        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streaming = json["streamingData"] as? [String: Any] else {
            if let data = response.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ps = json["playabilityStatus"] as? [String: Any],
               let reason = ps["reason"] as? String {
                throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get streaming data"])
        }

        let title = (json["videoDetails"] as? [String: Any])?["title"] as? String

        // Find best audio/mp4 stream (prefer itag 140 — AAC 128kbps)
        guard let adaptiveFormats = streaming["adaptiveFormats"] as? [[String: Any]] else {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "No adaptive formats"])
        }

        let audioFormats = adaptiveFormats.filter {
            ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] is String
        }

        let sorted = audioFormats.sorted { a, b in
            let aItag = a["itag"] as? Int ?? 0
            let bItag = b["itag"] as? Int ?? 0
            if aItag == 140 { return true }
            if bItag == 140 { return false }
            return (a["bitrate"] as? Int ?? 0) > (b["bitrate"] as? Int ?? 0)
        }

        guard let best = sorted.first,
              let urlStr = best["url"] as? String,
              let audioURL = URL(string: urlStr) else {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "No downloadable audio stream"])
        }

        let contentLength = Int64(best["contentLength"] as? String ?? "0") ?? 0

        return AudioStreamInfo(title: title, url: audioURL, contentLength: contentLength)
    }

    // MARK: - Step 4: Chunked Range Download via curl

    /// Download file in 1MB chunks using curl with Range headers.
    /// YouTube's CDN requires Range headers — full file requests return 403.
    static func downloadWithRangeChunks(
        from url: URL,
        to destination: URL,
        contentLength: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let chunkSize: Int64 = 1_048_576 // 1MB
        guard contentLength > 0 else {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown content length"])
        }

        // Create output file
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destination)
        defer { try? fileHandle.close() }

        var downloaded: Int64 = 0
        let urlString = url.absoluteString

        while downloaded < contentLength {
            let rangeEnd = min(downloaded + chunkSize - 1, contentLength - 1)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-L", "-H", "Range: bytes=\(downloaded)-\(rangeEnd)", urlString]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0, !data.isEmpty else {
                throw NSError(domain: "YouTube", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Download failed at byte \(downloaded)"])
            }

            fileHandle.write(data)
            downloaded += Int64(data.count)
            progress(downloaded, contentLength)
        }
    }

    // MARK: - Step 5: Re-encode Audio

    /// Re-encode to standard m4a format (YouTube's format may not be recognized by AVAudioFile).
    static func reencodeToM4A(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }

        session.outputURL = destination
        session.outputFileType = .m4a
        await session.export()

        if let error = session.error { throw error }
        guard session.status == .completed else {
            throw NSError(domain: "YouTube", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed: \(session.status.rawValue)"])
        }
    }

    // MARK: - Legacy API (for existing code)

    /// Fetch HLS streaming URL only (backward compatible).
    static func fetchStreamingURL(for urlString: String) async -> String? {
        await fetchHLSURL(for: urlString)
    }
}
