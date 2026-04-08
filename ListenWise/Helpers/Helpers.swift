/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Utility code — Story extensions, transcription errors, subtitle export, JSON parsing.
*/

import Foundation
import AVFoundation

extension Story: Equatable {
    static func == (lhs: Story, rhs: Story) -> Bool {
        lhs.id == rhs.id
    }
}

extension Story: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum TranscriptionError: Error {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound

    var descriptionString: String {
        switch self {
        case .couldNotDownloadModel:
            return "Could not download the model."
        case .failedToSetupRecognitionStream:
            return "Could not set up the speech recognition stream."
        case .invalidAudioDataType:
            return "Unsupported audio format."
        case .localeNotSupported:
            return "This locale is not yet supported by SpeechAnalyzer."
        case .noInternetForModelDownload:
            return "The model could not be downloaded because the user is not connected to internet."
        case .audioFilePathNotFound:
            return "Couldn't find the audio file."
        }
    }
}

// MARK: - Subtitle Export

struct SubtitleExporter {
    /// Pre-compute subtitle cards for real-time playback overlay.
    static func subtitleCards(from text: AttributedString) -> [(text: String, start: Double, end: Double)] {
        var groups: [(text: String, start: Double, end: Double)] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double?
        var lastEnd: Double = 0 // Track the last known end time for runs without timing
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
                // Run without timing — use last known end time as fallback only when
                // the transcript contains real timing somewhere. If there is no timing
                // at all (e.g. restored plain text), return [] so callers can fall back
                // to saved subtitle cards instead of collapsing into one huge block.
                if currentStart == nil { currentStart = lastEnd }
                currentText += runText
            }

            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]
            let sentenceEnd = trimmed.last.map { sentenceEnders.contains($0) } ?? false
            if sentenceEnd || trimmed.count > 60 {
                let s = currentStart ?? lastEnd
                let e = currentEnd ?? (lastEnd + 3) // Estimate 3s if no end time
                groups.append((trimmed, s, e))
                lastEnd = e
                currentText = ""
                currentStart = nil
                currentEnd = nil
            }
        }

        // Flush remaining text
        let remaining = currentText.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            let s = currentStart ?? lastEnd
            let e = currentEnd ?? (lastEnd + 3)
            groups.append((remaining, s, e))
        }

        // If the transcript has no timing metadata at all, these synthesized groups are
        // not trustworthy for subtitle/timestamp restoration. Let callers fall back to
        // persisted original subtitle cards instead.
        return hasTimedRun ? groups : []
    }

    /// Return the subtitle text active at the given playback position.
    static func subtitle(at time: Double, in cards: [(text: String, start: Double, end: Double)]) -> String {
        cards.first { $0.start <= time && time < $0.end }?.text ?? ""
    }
}

// MARK: - JSON Parsing Utility

/// Extract and decode a JSON array from an LLM response that may be wrapped in markdown fences.
func parseLLMJSON<T: Decodable>(_ raw: String) -> [T]? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "["), let e = jsonStr.lastIndex(of: "]") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([T].self, from: data)
}

/// Extract and decode a JSON object from an LLM response that may be wrapped in markdown fences.
func parseLLMJSONObject<T: Decodable>(_ raw: String) -> T? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "{"), let e = jsonStr.lastIndex(of: "}") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
