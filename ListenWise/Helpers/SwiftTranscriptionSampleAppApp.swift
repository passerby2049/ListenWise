/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
App initializer
*/

import SwiftUI

@main
struct ListenWiseApp: App {
    @State private var preferences = AppPreferences()
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(preferences)
                .preferredColorScheme(colorScheme)
        }


    }
}
