/*
Abstract:
Subtitle overlay for video playback — shared by both live and normal modes.
*/

import SwiftUI

struct SubtitleOverlay: View {
    var source: String
    var translation: String

    var body: some View {
        if !source.isEmpty || !translation.isEmpty {
            VStack {
                Spacer()
                VStack(alignment: .center, spacing: 4) {
                    if !source.isEmpty {
                        Text(source)
                            .foregroundStyle(.white)
                            .font(.title3.bold())
                            .lineLimit(2)
                    }
                    if !translation.isEmpty {
                        Text(translation)
                            .foregroundStyle(.white.opacity(0.8))
                            .font(.callout)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 48)
                .padding(.horizontal, 40)
            }
        }
    }
}
