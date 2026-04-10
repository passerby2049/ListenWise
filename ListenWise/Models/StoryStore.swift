/*
Abstract:
Persistence layer — saves/loads stories, exports to Markdown.
*/

import Foundation
import AVFoundation

class StoryStore {
    static let shared = StoryStore()

    private let storageDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise", isDirectory: true)
            .appendingPathComponent("Stories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Save

    func save(_ stories: [Story]) {
        for story in stories {
            save(story)
        }
        let activeIDs = Set(stories.map { $0.id.uuidString })
        if let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                if !activeIDs.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func save(_ story: Story) {
        let data = StoryData(
            id: story.id,
            title: story.title,
            plainText: String(story.text.characters),
            isDone: story.isDone,
            urlBookmark: bookmarkData(for: story.url),
            urlPath: story.url?.path,
            subtitleCards: {
                let fromText = SubtitleExporter.subtitleCards(from: story.text)
                return fromText.isEmpty ? story.savedSubtitleCards : fromText
            }(),
            fixedTranscript: nilIfEmpty(story.savedFixedTranscript),
            fixedSubtitleCards: story.savedFixedSubtitleCards.isEmpty ? nil : story.savedFixedSubtitleCards,
            markedWords: story.savedMarkedWords.isEmpty ? nil : Array(story.savedMarkedWords),
            wordLearningResponse: nilIfEmpty(story.savedWordLearningResponse),
            sentenceLearningResponse: nilIfEmpty(story.savedSentenceLearningResponse),
            translation: nilIfEmpty(story.savedTranslation),
            chatMessages: story.savedChatMessages.isEmpty ? nil : story.savedChatMessages,
            youtubeURL: nilIfEmpty(story.youtubeURL),
            youtubeStreamingURL: nilIfEmpty(story.youtubeStreamingURL),
            reorganizedCards: story.savedReorganizedCards.isEmpty ? nil : story.savedReorganizedCards,
            sourceLanguage: story.sourceLanguage,
            targetLanguage: story.targetLanguage,
            isLiveStream: story.isLiveStream ? true : nil,
            liveSegments: story.savedLiveSegments.isEmpty ? nil : story.savedLiveSegments
        )
        let file = storageDir.appendingPathComponent("\(story.id.uuidString).json")
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let jsonData = try? encoder.encode(data) {
                try? jsonData.write(to: file, options: .atomic)
            }
        }
    }

    // MARK: - Load

    func loadAll() -> [Story] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { loadStory(from: $0) }
            .sorted { $0.title < $1.title }
    }

    private func loadStory(from file: URL) -> Story? {
        guard let jsonData = try? Data(contentsOf: file),
              let data = try? JSONDecoder().decode(StoryData.self, from: jsonData) else {
            return nil
        }

        let story = Story(title: data.title, text: AttributedString(data.plainText), isDone: data.isDone)
        story.id_ = data.id

        // Restore file URL
        if let bookmark = data.urlBookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                story.url = url
            }
        }
        if story.url == nil, let path = data.urlPath {
            story.url = URL(fileURLWithPath: path)
        }

        // Restore all learning data
        story.savedSubtitleCards = data.subtitleCards ?? []
        story.savedFixedTranscript = data.fixedTranscript ?? ""
        story.savedFixedSubtitleCards = data.fixedSubtitleCards ?? []
        story.savedMarkedWords = Set(data.markedWords ?? [])
        story.savedWordLearningResponse = data.wordLearningResponse ?? ""
        story.savedSentenceLearningResponse = data.sentenceLearningResponse ?? ""
        story.savedTranslation = data.translation ?? ""
        story.savedChatMessages = data.chatMessages ?? []
        story.youtubeURL = data.youtubeURL ?? ""
        story.youtubeStreamingURL = data.youtubeStreamingURL ?? ""
        story.savedReorganizedCards = data.reorganizedCards ?? []
        story.sourceLanguage = data.sourceLanguage ?? "English"
        story.targetLanguage = data.targetLanguage ?? "中文"
        story.isLiveStream = data.isLiveStream ?? false
        story.savedLiveSegments = data.liveSegments ?? []

        return story
    }

    // MARK: - Export

    /// Export a single story to Markdown file. Returns the file URL.
    func exportToMarkdown(_ story: Story) throws -> URL {
        let exportDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let safeTitle = story.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(80)
        let file = exportDir.appendingPathComponent("\(safeTitle).md")
        try story.exportMarkdown().write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Export all stories to a folder. Returns the folder URL.
    func exportAllToMarkdown(_ stories: [Story]) throws -> URL {
        let exportDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenWise Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        for story in stories where story.isDone {
            _ = try exportToMarkdown(story)
        }
        return exportDir
    }

    // MARK: - Helpers

    private func bookmarkData(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func nilIfEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}

// MARK: - Codable Data Model

/*
 Storage schema — all fields optional except id/title/plainText/isDone.

 StoryData
 ├── id: UUID
 ├── title: String
 ├── plainText: String               // Original transcript
 ├── isDone: Bool
 ├── urlBookmark: Data?              // Security-scoped bookmark
 ├── urlPath: String?                // Fallback file path
 ├── subtitleCards: [SubtitleCard]?   // Original timing data
 ├── fixedTranscript: String?        // LLM-fixed transcript
 ├── fixedSubtitleCards: [SubtitleCard]?  // LLM-fixed subtitles with timing
 ├── markedWords: [String]?          // User's vocabulary list
 ├── wordLearningResponse: String?   // Raw LLM response (JSON)
 ├── translation: String?            // Full text translation
 └── chatMessages: [ChatMessage]?    // Chat history
*/
private struct StoryData: Codable {
    let id: UUID
    let title: String
    let plainText: String
    let isDone: Bool
    let urlBookmark: Data?
    let urlPath: String?
    let subtitleCards: [SubtitleCard]?
    let fixedTranscript: String?
    let fixedSubtitleCards: [SubtitleCard]?
    let markedWords: [String]?
    let wordLearningResponse: String?
    let sentenceLearningResponse: String?
    let translation: String?
    let chatMessages: [ChatMessage]?
    let youtubeURL: String?
    let youtubeStreamingURL: String?
    let reorganizedCards: [ReorganizedCard]?
    let sourceLanguage: String?
    let targetLanguage: String?
    let isLiveStream: Bool?
    let liveSegments: [LiveSegment]?
}
