/*
Abstract:
Subtitle card generation from attributed text with timing, and audio extraction from video.
*/

import Foundation
import AVFoundation

// MARK: - Subtitle Export

struct SubtitleExporter {
    /// Pre-compute subtitle cards for real-time playback overlay.
    static func subtitleCards(from text: AttributedString) -> [SubtitleCard] {
        var cards: [SubtitleCard] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double?
        var lastEnd: Double = 0
        var hasTimedRun = false

        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            if let timeRange = run.audioTimeRange {
                hasTimedRun = true
                let start = CMTimeGetSeconds(timeRange.start)
                let end = CMTimeGetSeconds(timeRange.end)
                if currentStart == nil { currentStart = start }
                currentEnd = end
                lastEnd = end
                currentText += runText
            } else {
                if currentStart == nil { currentStart = lastEnd }
                currentText += runText
            }

            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            let nonDotEnders: Set<Character> = ["?", "!", "。", "？", "！"]
            let endsWithNonDot = trimmed.last.map { nonDotEnders.contains($0) } ?? false
            let endsWithSentenceDot: Bool = {
                guard trimmed.hasSuffix(".") else { return false }
                let withoutDot = trimmed.dropLast()
                let lastWord = withoutDot.split(separator: " ").last.map(String.init) ?? ""
                return lastWord.count >= 2 && lastWord.allSatisfy(\.isLetter)
            }()
            let sentenceEnd = endsWithNonDot || endsWithSentenceDot
            let endsWithAbbreviation: Bool = {
                let words = trimmed.split(separator: " ")
                guard let last = words.last else { return false }
                return last.hasSuffix(".") && last.count <= 2
            }()
            let overLength = trimmed.count > 60 && currentText.hasSuffix(" ") && !endsWithAbbreviation
            if sentenceEnd || overLength {
                let s = currentStart ?? lastEnd
                let e = currentEnd ?? (lastEnd + 3)
                cards.append(SubtitleCard(text: trimmed, start: s, end: e))
                lastEnd = e
                currentText = ""
                currentStart = nil
                currentEnd = nil
            }
        }

        let remaining = currentText.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            let s = currentStart ?? lastEnd
            let e = currentEnd ?? (lastEnd + 3)
            cards.append(SubtitleCard(text: remaining, start: s, end: e))
        }

        return hasTimedRun ? cards : []
    }

    /// Return the subtitle text active at the given playback position.
    static func subtitle(at time: Double, in cards: [SubtitleCard]) -> String {
        cards.first { $0.start <= time && time < $0.end }?.text ?? ""
    }
}

// MARK: - Audio Extraction

let videoFileExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]

/// Extract audio track from a video file into a temporary m4a.
func extractAudioFromVideo(_ videoURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: videoURL)
    let duration = try? await asset.load(.duration)

    let tempURL = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString)
        .appendingPathExtension("m4a")

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw TranscriptionError.audioFilePathNotFound
    }
    session.timeRange = CMTimeRange(start: .zero, duration: duration ?? CMTime(seconds: 7200, preferredTimescale: 600))

    try await session.export(to: tempURL, as: .m4a)
    return tempURL
}
