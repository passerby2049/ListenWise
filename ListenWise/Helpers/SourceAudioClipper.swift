/*
Abstract:
Produces per-sentence audio clips for review cards. Resolves the originating story's
audio (local file or YouTube re-download), then uses AVAssetExportSession to extract
the exact time range. Clipped m4a files are cached on disk; per-session full downloads
are kept in memory during a batch so multiple sentences from the same video only pay
for one download.
*/

import Foundation
import AVFoundation
import CryptoKit

@MainActor
final class SourceAudioClipper {
    static let shared = SourceAudioClipper()

    /// Persistent cache directory for clipped m4a files.
    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise", isDirectory: true)
            .appendingPathComponent("VocabAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Session-scoped full audio downloads keyed by story id — cleared by `clearSessionDownloads()`.
    private var fullAudioByStory: [UUID: URL] = [:]

    /// URLs for which we started security-scoped access and must pair with a stop.
    private var scopedLocalURLs: [UUID: URL] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns the cached clip URL if it already exists on disk.
    func cachedClipURL(for sentence: GlobalVocabulary.SourceSentence) -> URL? {
        let url = clipURL(for: sentence)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Ensure a clip exists for this sentence, producing one if necessary. Returns the URL.
    /// Throws if the source can't be resolved or the clip can't be extracted.
    func prepareClip(for sentence: GlobalVocabulary.SourceSentence) async throws -> URL {
        if let cached = cachedClipURL(for: sentence) { return cached }

        guard let storyID = sentence.storyID,
              let start = sentence.start,
              let end = sentence.end,
              end > start else {
            throw ClipError.missingTiming
        }

        let sourceAudio = try await resolveFullAudio(for: storyID)
        let destination = clipURL(for: sentence)
        try await extract(from: sourceAudio, start: start, end: end, to: destination)
        return destination
    }

    /// Count of sentences in `items` that do not yet have a cached clip.
    func pendingCount(in items: [GlobalVocabulary.SourceSentence]) -> Int {
        var count = 0
        for item in items {
            guard item.storyID != nil, item.start != nil else { continue }
            if cachedClipURL(for: item) == nil { count += 1 }
        }
        return count
    }

    /// Release temporary full-audio downloads from memory and disk after a batch finishes.
    func clearSessionDownloads() {
        for (id, _) in fullAudioByStory {
            releaseFullAudio(for: id)
        }
        fullAudioByStory.removeAll()
        scopedLocalURLs.removeAll()
    }

    /// Release the temp full audio for a single story once all its sentences are clipped.
    /// Deletes the file if it's a temp download, and stops security-scoped access if
    /// the source was a user-owned local file.
    func releaseFullAudio(for storyID: UUID) {
        if let scoped = scopedLocalURLs.removeValue(forKey: storyID) {
            scoped.stopAccessingSecurityScopedResource()
        }
        guard let url = fullAudioByStory.removeValue(forKey: storyID) else { return }
        let temp = FileManager.default.temporaryDirectory.path
        if url.path.hasPrefix(temp) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes used by the clip cache on disk.
    func cacheSizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Remove every cached clip. Does not touch session full-audio downloads.
    func clearCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Internal

    private func clipURL(for sentence: GlobalVocabulary.SourceSentence) -> URL {
        let payload = "\(sentence.storyID?.uuidString ?? "nil")|\(sentence.start ?? 0)|\(sentence.end ?? 0)|\(sentence.source)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hex).m4a")
    }

    private func resolveFullAudio(for storyID: UUID) async throws -> URL {
        if let existing = fullAudioByStory[storyID],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }

        guard let source = StoryStore.shared.loadAudioSource(for: storyID) else {
            throw ClipError.storyNotFound
        }

        if let local = source.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            // Local file is authoritative — no need to cache a duplicate.
            fullAudioByStory[storyID] = local
            if source.didStartSecurityScope {
                scopedLocalURLs[storyID] = local
            }
            return local
        }
        // Story had a bookmark but file is gone — release the scope we started in loadAudioSource.
        if source.didStartSecurityScope, let scoped = source.localFileURL {
            scoped.stopAccessingSecurityScopedResource()
        }

        guard let ytURL = source.youtubeURL else { throw ClipError.noSourceAvailable }

        // Download audio stream into a temp m4a. Re-encode to ensure AV can read it.
        let rawTemp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-raw-\(storyID.uuidString).m4a")
        let reencodedTemp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-audio-\(storyID.uuidString).m4a")
        try? FileManager.default.removeItem(at: rawTemp)
        try? FileManager.default.removeItem(at: reencodedTemp)

        let pageInfo = try await YouTubeHelper.scrapeWatchPage(for: ytURL)
        let audio = try await YouTubeHelper.fetchAudioStream(
            for: ytURL,
            visitorData: pageInfo.visitorData,
            signatureTimestamp: pageInfo.signatureTimestamp
        )
        try await YouTubeHelper.downloadWithRangeChunks(
            from: audio.url,
            to: rawTemp,
            contentLength: audio.contentLength,
            progress: { _, _ in }
        )
        try await YouTubeHelper.reencodeToM4A(from: rawTemp, to: reencodedTemp)
        try? FileManager.default.removeItem(at: rawTemp)

        fullAudioByStory[storyID] = reencodedTemp
        return reencodedTemp
    }

    private func extract(from source: URL, start: Double, end: Double, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipError.exportSessionFailed
        }

        // Pad start slightly to avoid clipping the first phoneme.
        let pad: Double = 0.15
        let clampedStart = max(0, start - pad)
        let clampedEnd = end + pad
        let timescale: CMTimeScale = 600
        let range = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: timescale),
            end: CMTime(seconds: clampedEnd, preferredTimescale: timescale)
        )
        session.timeRange = range

        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw error
        }
    }

    enum ClipError: LocalizedError {
        case missingTiming
        case storyNotFound
        case noSourceAvailable
        case exportSessionFailed
        case exportFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .missingTiming: return "Source sentence has no stored timing."
            case .storyNotFound: return "Original story could not be found."
            case .noSourceAvailable: return "No local file or YouTube URL available for this story."
            case .exportSessionFailed: return "Could not create audio export session."
            case .exportFailed(let s): return "Audio export failed (status \(s))."
            }
        }
    }
}
