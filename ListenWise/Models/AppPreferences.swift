/*
Abstract:
Shared app preferences used by SettingsView and shell UI.
*/

import SwiftUI

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
