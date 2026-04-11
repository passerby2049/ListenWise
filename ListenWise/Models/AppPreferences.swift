/*
Abstract:
Shared app preferences used by SettingsView and shell UI.
*/

import SwiftUI

struct GoogleAIKeyEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var key: String

    init(id: UUID = UUID(), name: String, key: String) {
        self.id = id
        self.name = name
        self.key = key
    }
}

@Observable
final class AppPreferences {
    var openRouterAPIKey: String {
        get { UserDefaults.standard.string(forKey: "openRouterAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openRouterAPIKey") }
    }

    var anthropicBaseURL: String {
        get { UserDefaults.standard.string(forKey: "anthropicBaseURL") ?? "https://api.anthropic.com" }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicBaseURL") }
    }

    var anthropicAPIKey: String {
        get { UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicAPIKey") }
    }

    var googleAIKeys: [GoogleAIKeyEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "googleAIKeys"),
                  let decoded = try? JSONDecoder().decode([GoogleAIKeyEntry].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "googleAIKeys")
            }
        }
    }

    var googleAIActiveKeyID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "googleAIActiveKeyID"),
                  let id = UUID(uuidString: str) else { return nil }
            return id
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(id.uuidString, forKey: "googleAIActiveKeyID")
            } else {
                UserDefaults.standard.removeObject(forKey: "googleAIActiveKeyID")
            }
        }
    }

    /// Read-only: resolves the currently active Google AI API key string,
    /// used by `AIProvider` for auth headers. If no key is marked active
    /// but at least one entry exists, falls back to the first entry.
    var googleAIAPIKey: String {
        let keys = googleAIKeys
        guard !keys.isEmpty else { return "" }
        if let activeID = googleAIActiveKeyID, let match = keys.first(where: { $0.id == activeID }) {
            return match.key
        }
        return keys.first?.key ?? ""
    }

    var defaultModel: String {
        get { UserDefaults.standard.string(forKey: "defaultModel") ?? "google/gemini-2.5-flash" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultModel") }
    }

    /// Selected transcription engine ID.
    var transcriptionEngineID: String {
        get { UserDefaults.standard.string(forKey: "transcriptionEngineID") ?? TranscriptionEngineID.appleSpeech.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptionEngineID") }
    }

    var selectedTranscriptionEngine: TranscriptionEngineID {
        get { TranscriptionEngineID(rawValue: transcriptionEngineID) ?? .appleSpeech }
        set { transcriptionEngineID = newValue.rawValue }
    }

    /// "system", "light", or "dark"
    var appearance: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "appearance") }
    }

    /// Accent color name: "blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"
    var accentColorName: String {
        get { UserDefaults.standard.string(forKey: "accentColorName") ?? "blue" }
        set { UserDefaults.standard.set(newValue, forKey: "accentColorName") }
    }

    var accentColor: Color {
        Self.color(for: accentColorName)
    }

    static func color(for name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "gray": return .gray
        default: return .blue
        }
    }

}
