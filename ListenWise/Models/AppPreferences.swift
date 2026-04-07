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

    var configuredProvidersSummary: String {
        let providers = [
            openRouterAPIKey.isEmpty ? nil : "OpenRouter",
            anthropicAPIKey.isEmpty ? nil : "Anthropic"
        ].compactMap { $0 }

        if providers.isEmpty {
            return "No provider configured"
        }

        return providers.joined(separator: " + ")
    }
}
