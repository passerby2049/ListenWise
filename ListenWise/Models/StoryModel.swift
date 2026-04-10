/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Story data model.
*/

import Foundation
import AVFoundation
import FoundationModels

@Observable
class Story: Identifiable {
    typealias StartTime = CMTime

    var id_ : UUID
    var id: UUID { id_ }
    var title: String
    var text: AttributedString
    var url: URL?
    var isDone: Bool
    var createdAt: Date

    // --- Persisted learning data ---

    /// Original subtitle cards (with timing).
    var savedSubtitleCards: [SubtitleCard] = []
    /// Fixed transcript text from LLM.
    var savedFixedTranscript: String = ""
    /// Fixed subtitle cards from LLM.
    var savedFixedSubtitleCards: [SubtitleCard] = []
    /// Marked words for vocabulary learning.
    var savedMarkedWords: Set<String> = []
    /// Raw LLM word learning response (JSON string).
    var savedWordLearningResponse: String = ""
    /// Raw LLM sentence learning response (JSON string).
    var savedSentenceLearningResponse: String = ""
    /// Translation text.
    var savedTranslation: String = ""
    /// Chat history.
    var savedChatMessages: [ChatMessage] = []
    /// YouTube URL for online playback (if downloaded from YouTube).
    var youtubeURL: String = ""
    /// YouTube HLS streaming URL for direct HD playback via AVPlayer.
    var youtubeStreamingURL: String = ""
    /// Reorganized subtitle cards (LLM-merged with proper sentence boundaries + translation).
    var savedReorganizedCards: [ReorganizedCard] = []
    /// Whether this is a YouTube live stream (no audio download, real-time transcription).
    var isLiveStream: Bool = false
    /// Live transcription segments (source + translation pairs).
    var savedLiveSegments: [LiveSegment] = []

    /// Source language (for speech recognition and AI prompts).
    var sourceLanguage: String = "English"
    /// Target language (for translation).
    var targetLanguage: String = "中文"

    var sourceIsVideo: Bool {
        if !youtubeURL.isEmpty { return true }
        guard let url else { return false }
        return Set(["mp4", "mov", "m4v", "avi", "mkv"]).contains(url.pathExtension.lowercased())
    }

    init(title: String, text: AttributedString, url: URL? = nil, isDone: Bool = false, createdAt: Date = Date()) {
        self.title = title
        self.text = text
        self.url = url
        self.isDone = isDone
        self.createdAt = createdAt
        self.id_ = UUID()
    }

    func suggestedTitle() async throws -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let answer = try await session.respond(to: "Here is a transcript. Please return a concise suggested title for it, with no other text. The title should be descriptive. Transcript: \(text.characters)")
        return answer.content.trimmingCharacters(in: .punctuationCharacters)
    }
}

// MARK: - Language Config

struct LanguageOption: Identifiable, Hashable {
    let id: String          // e.g. "English"
    let displayName: String // e.g. "English"
    let bcp47: String       // e.g. "en-US" for speech recognition
}

enum SupportedLanguages {
    static let source: [LanguageOption] = [
        LanguageOption(id: "English", displayName: "English", bcp47: "en-US"),
        LanguageOption(id: "Japanese", displayName: "Japanese / 日本語", bcp47: "ja-JP"),
        LanguageOption(id: "French", displayName: "French / Français", bcp47: "fr-FR"),
        LanguageOption(id: "German", displayName: "German / Deutsch", bcp47: "de-DE"),
        LanguageOption(id: "Spanish", displayName: "Spanish / Español", bcp47: "es-ES"),
        LanguageOption(id: "Korean", displayName: "Korean / 한국어", bcp47: "ko-KR"),
    ]

    static let target: [LanguageOption] = [
        LanguageOption(id: "中文", displayName: "中文", bcp47: "zh-CN"),
        LanguageOption(id: "English", displayName: "English", bcp47: "en-US"),
        LanguageOption(id: "Japanese", displayName: "Japanese / 日本語", bcp47: "ja-JP"),
    ]

    static func locale(for languageID: String) -> Locale? {
        let all = source + target
        guard let opt = all.first(where: { $0.id == languageID }) else { return nil }
        return Locale(identifier: opt.bcp47)
    }
}

// MARK: - Chat Message

// MARK: - Shared Data Structs

struct SubtitleCard: Codable {
    var text: String
    var start: Double
    var end: Double
}

struct ReorganizedCard: Codable {
    var text: String
    var translation: String
    var start: Double
    var end: Double
}

struct LiveSegment: Codable {
    var source: String
    var translation: String
}

struct ChatMessage: Codable {
    let role: String  // "user" or "assistant"
    var content: String
}

struct TranslationPair: Codable {
    let source: String
    let target: String
}

/// LLM response for subtitle reorganization (with translation)
struct ReorganizedSentence: Codable {
    let cards: [Int]
    let text: String
    let target: String?
}

// MARK: - Equatable & Hashable

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

// MARK: - Extensions

extension Story {
    static func blank() -> Story {
        return .init(title: "New Story", text: AttributedString(""))
    }

    /// A story the user never actually filled with a source.
    /// Used to auto-clean abandoned "New Story" entries on navigation.
    var isBlank: Bool {
        url == nil && youtubeURL.isEmpty && !isLiveStream
    }

    func storyBrokenUpByLines() -> AttributedString {
        if url == nil {
            return text
        } else {
            var final = AttributedString("")
            var working = AttributedString("")
            let copy = text
            copy.runs.forEach { run in
                if copy[run.range].characters.contains(".") {
                    working.append(copy[run.range])
                    final.append(working)
                    final.append(AttributedString("\n\n"))
                    working = AttributedString("")
                } else {
                    if working.characters.isEmpty {
                        let newText = copy[run.range].characters
                        let attributes = run.attributes
                        let trimmed = newText.trimmingPrefix(" ")
                        let newAttributed = AttributedString(trimmed, attributes: attributes)
                        working.append(newAttributed)
                    } else {
                        working.append(copy[run.range])
                    }
                }
            }

            if final.characters.isEmpty {
                return working
            }

            return final
        }
    }

    // MARK: - Export to Markdown

    func exportMarkdown() -> String {
        var md = "# \(title)\n\n"
        if !youtubeURL.isEmpty {
            md += "**Source:** \(youtubeURL)\n\n"
        }
        md += "**Languages:** \(sourceLanguage) → \(targetLanguage)\n\n"
        md += "---\n\n"

        // Transcript
        let transcript = savedFixedTranscript.isEmpty ? String(text.characters) : savedFixedTranscript
        if !transcript.isEmpty {
            md += "## Transcript\n\n"
            md += transcript + "\n\n"
        }

        // Translation
        if !savedTranslation.isEmpty {
            md += "## Translation\n\n"
            md += savedTranslation + "\n\n"
        }

        // Vocabulary
        if !savedMarkedWords.isEmpty {
            md += "## Vocabulary\n\n"
            // Try parsing word explanations from saved response
            if !savedWordLearningResponse.isEmpty,
               let explanations = parseWordExplanationsFromRaw(savedWordLearningResponse) {
                for w in explanations {
                    md += "### \(w.word) (\(w.pos))\n\n"
                    md += "**Definition (\(sourceLanguage)):** \(w.definition_source)\n\n"
                    md += "**Definition (\(targetLanguage)):** \(w.definition_target)\n\n"
                    if !w.context_usage.isEmpty {
                        md += "> \(w.context_usage)\n\n"
                    }
                    if let src = w.sentence_source, !src.isEmpty {
                        md += "**Original:** \(src)\n\n"
                    }
                    if !w.sentence_target.isEmpty {
                        md += "**Translation:** \(w.sentence_target)\n\n"
                    }
                    if !w.example_source.isEmpty {
                        md += "**Example:** *\(w.example_source)*\n\n\(w.example_target)\n\n"
                    }
                    if !w.collocations.isEmpty {
                        md += "**Collocations:** \(w.collocations.joined(separator: ", "))\n\n"
                    }
                    md += "---\n\n"
                }
            } else {
                md += "Words: \(savedMarkedWords.sorted().joined(separator: ", "))\n\n"
                if !savedWordLearningResponse.isEmpty {
                    md += savedWordLearningResponse + "\n\n"
                }
            }
        }

        // Chat
        if !savedChatMessages.isEmpty {
            md += "## Chat Notes\n\n"
            for msg in savedChatMessages {
                if msg.role == "user" {
                    md += "**Q:** \(msg.content)\n\n"
                } else {
                    md += "**A:** \(msg.content)\n\n"
                }
            }
        }

        return md
    }

    private func parseWordExplanationsFromRaw(_ raw: String) -> [WordExplanation]? {
        parseLLMJSON(raw)
    }
}
