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
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var accentColor: Color {
        AppPreferences.color(for: accentColorName)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(preferences)
                .tint(accentColor)
                .accentColor(accentColor)
                .onChange(of: appearance) { _, newValue in
                    applyAppearance(newValue)
                }
                .onAppear { applyAppearance(appearance) }
        }

        Settings {
            SettingsView()
                .environment(preferences)
                .tint(accentColor)
                .accentColor(accentColor)
        }
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
