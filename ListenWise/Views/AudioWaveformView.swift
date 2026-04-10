/*
Abstract:
Simulated audio waveform animation for live transcription indicator.
*/

import SwiftUI

struct AudioWaveformView: View {
    private let barCount = 4

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                WaveformBar(index: i)
            }
        }
    }
}

private struct WaveformBar: View {
    var index: Int
    @State private var animating = false

    private var delay: Double { Double(index) * 0.15 }
    private var duration: Double { [0.4, 0.35, 0.45, 0.3][index % 4] }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.red)
            .frame(width: 2, height: animating ? 12 : 3)
            .animation(
                .easeInOut(duration: duration)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: animating
            )
            .onAppear { animating = true }
    }
}
