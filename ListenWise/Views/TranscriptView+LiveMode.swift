/*
Abstract:
TranscriptView extension — live stream transcription UI, controls, and segment display.
*/

import SwiftUI
import AppKit

extension TranscriptView {

    // MARK: - Live Stream Input Sheet

    @ViewBuilder
    var liveStreamInputSheet: some View {
        VStack(spacing: 16) {
            Text("YouTube Live Stream")
                .font(.title2.bold())
            Text("Paste a YouTube live stream URL to watch with real-time subtitles.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("https://www.youtube.com/watch?v=...", text: $liveStreamURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isShowingLiveStreamInput = false
                    liveStreamURLText = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Start") {
                    let url = liveStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty, let videoID = YouTubeHelper.extractVideoID(url) else { return }
                    vm.configureLiveStream(url: url, videoID: videoID)
                    isShowingLiveStreamInput = false
                    liveStreamURLText = ""
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(YouTubeHelper.extractVideoID(liveStreamURLText) == nil)
            }
        }
        .padding(24)
    }

    // MARK: - Live Transcript Area

    var liveTranscriptArea: some View {
        @Bindable var vm = vm
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()

                Button {
                    Task {
                        if liveTranscriber.isRunning {
                            let _ = await liveTranscriber.stop()
                            vm.saveLiveSegments(liveTranscriber: liveTranscriber)
                        } else {
                            do {
                                liveTranscriber.translateEnabled = vm.liveTranslateEnabled
                                liveTranscriber.translateTargetLang = story.targetLanguage
                                try await liveTranscriber.start()
                            } catch {
                                print("[LiveTranscribe] Error: \(error)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if liveTranscriber.isRunning {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            AudioWaveformView()
                                .frame(width: 24, height: 14)
                        } else {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 11))
                            Text("Transcribe")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(liveTranscriber.isRunning ? .red : .white)
                .background(liveTranscriber.isRunning ? Color.red.opacity(0.15) : preferences.accentColor)
                .clipShape(Capsule())

                Toggle(isOn: $vm.liveTranslateEnabled) {
                    Label("Translate", systemImage: vm.liveTranslateEnabled ? "character.bubble.fill" : "character.bubble")
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(vm.liveTranslateEnabled ? preferences.accentColor : Color.secondary.opacity(0.18))
                .foregroundStyle(vm.liveTranslateEnabled ? .white : .secondary)
                .clipShape(Capsule())
                .onChange(of: vm.liveTranslateEnabled) { _, newValue in
                    liveTranscriber.translateEnabled = newValue
                }

                Button {
                    let text = liveTranscriber.segments.map { seg in
                        seg.translation.isEmpty ? seg.source : "\(seg.source)\n\(seg.translation)"
                    }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())
                .disabled(liveTranscriber.segments.isEmpty)
                .help("Copy transcript with translations")

                Spacer()
            }
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    liveTranscriptView(proxy: proxy)
                        .padding(20)
                }
                .clipped()
            }
        }
    }

    // MARK: - Live Transcript Content

    var liveScrollTrigger: String {
        "\(liveTranscriber.segments.count)|\(liveTranscriber.confirmedText.count)|\(liveTranscriber.volatileText.count)|\(liveTranscriber.segments.last?.translation.count ?? 0)"
    }

    @ViewBuilder
    func liveTranscriptView(proxy: ScrollViewProxy) -> some View {
        @Bindable var vm = vm
        let segments = liveTranscriber.segments
        let volatile = liveTranscriber.volatileText
        VStack(alignment: .leading, spacing: 6) {
            if segments.isEmpty {
                if !volatile.isEmpty {
                    Text(volatile)
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                }
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    VStack(alignment: .leading, spacing: 2) {
                        WordFlowView(text: seg.source, markedWords: $vm.markedWords)
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !seg.translation.isEmpty {
                            Text(seg.translation)
                                .foregroundColor(.blue)
                                .font(.system(size: 15))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .id("live_seg_\(idx)")
                }
                if !volatile.isEmpty {
                    Text(volatile)
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                }
            }

            Color.clear.frame(height: 1).id("live_bottom")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: liveScrollTrigger) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("live_bottom", anchor: .bottom)
            }
        }
    }
}
