/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
App initializer
*/

import SwiftUI
import AppKit

@main
struct ListenWiseApp: App {
    @State private var preferences = AppPreferences()
    @State private var deepLink = DeepLinkRouter()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var accentColor: Color {
        AppPreferences.color(for: accentColorName)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(preferences)
                .environment(deepLink)
                .tint(accentColor)
                .onChange(of: appearance) { _, newValue in
                    applyAppearance(newValue)
                }
                .onAppear { applyAppearance(appearance) }
                .onOpenURL { url in handleDeepLink(url) }
        }

        Settings {
            SettingsView()
                .environment(preferences)
                .tint(accentColor)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "listenwise",
              url.host?.lowercased() == "import",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              !raw.isEmpty
        else { return }
        deepLink.pendingYouTubeURL = raw
    }
}

private func applyAppearance(_ appearance: String) {
    switch appearance {
    case "light":
        NSApp.appearance = NSAppearance(named: .aqua)
    case "dark":
        NSApp.appearance = NSAppearance(named: .darkAqua)
    default:
        NSApp.appearance = nil
    }
}
