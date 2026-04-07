/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
App initializer
*/

import SwiftUI

@main
struct ListenWiseApp: App {
    @State private var preferences = AppPreferences()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(preferences)
        }


    }
}
