/*
Abstract:
Small speaker button used in learning cards to read example sentences aloud
through `TTSService`. Shows a "playing" state when this button's text is the
one currently being spoken.
*/

import SwiftUI

struct SpeakerButton: View {
    let text: String
    var size: CGFloat = 13

    @State private var tts = TTSService.shared

    private var isPlaying: Bool {
        tts.currentSpeakingText == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button {
            if isPlaying {
                tts.stop()
            } else {
                Task { await tts.speak(text) }
            }
        } label: {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop" : "Read aloud")
        .accessibilityLabel(isPlaying ? "Stop reading" : "Read aloud")
    }
}
