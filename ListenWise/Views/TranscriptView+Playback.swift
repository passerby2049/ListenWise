/*
Abstract:
TranscriptView extension — player setup, playback controls, subtitle sync.
*/

import Foundation
import AVFoundation
import AVKit

extension TranscriptView {

    // MARK: - Player Setup

    func setupPlayer() {
        guard story.isDone, let url = story.url, player == nil else { return }
        // Re-acquire security-scoped access for restored URLs
        if securityScopedURL == nil {
            let accessing = url.startAccessingSecurityScopedResource()
            if accessing { securityScopedURL = url }
        }

        // For YouTube videos: video + audio plays via embedded WKWebView.
        // No AVPlayer needed — subtitles are driven by JS time polling.
        if !story.youtubeURL.isEmpty {
            // Just load subtitle cards, no AVPlayer
            if !story.savedSubtitleCards.isEmpty {
                cachedSubtitleCards = story.savedSubtitleCards
            } else {
                let cards = SubtitleExporter.subtitleCards(from: story.text)
                cachedSubtitleCards = cards.isEmpty ? story.savedSubtitleCards : cards
                if !cachedSubtitleCards.isEmpty {
                    story.savedSubtitleCards = cachedSubtitleCards
                }
            }
            // Get duration from local audio file
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    duration = CMTimeGetSeconds(d)
                }
            }
            return
        }

        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        player = p
        finishPlayerSetup(player: p, localURL: url)
    }

    /// Shared player setup — loads subtitle cards, sets up duration and time observer.
    func finishPlayerSetup(player p: AVPlayer, localURL url: URL) {
        if !story.savedSubtitleCards.isEmpty {
            cachedSubtitleCards = story.savedSubtitleCards
        } else {
            let cards = SubtitleExporter.subtitleCards(from: story.text)
            cachedSubtitleCards = cards.isEmpty ? story.savedSubtitleCards : cards
            if !cachedSubtitleCards.isEmpty {
                story.savedSubtitleCards = cachedSubtitleCards
            }
        }

        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration) {
                duration = CMTimeGetSeconds(d)
            }
        }

        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        let isVideo = sourceIsVideo
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            let t = time.seconds

            if !isVideo {
                currentPlaybackTime = t
            }

            let cards = activeSubtitleCards
            let newIndex = cards.firstIndex { $0.start <= t && t < $0.end }
            if newIndex != currentLineIndex {
                currentLineIndex = newIndex
                // Auto-scroll vocab panel to first marked word in current subtitle
                if let idx = newIndex, inspectorTab == .vocab, !markedWords.isEmpty {
                    let lineText = cards[idx].text.lowercased()
                    if let firstMatch = markedWords.sorted().first(where: { lineText.contains($0) }) {
                        vocabScrollTarget = firstMatch
                    }
                }
            }

            if isVideo {
                currentSubtitleText = newIndex.map { cards[$0].text } ?? ""
                if showReorganized && !reorganizedCards.isEmpty, let idx = newIndex, idx < reorganizedCards.count {
                    currentSubtitleTranslation = reorganizedCards[idx].translation
                } else {
                    currentSubtitleTranslation = ""
                }
            }
        }
    }

    /// Active subtitle cards — prefer reorganized, then cached original.
    var activeSubtitleCards: [SubtitleCard] {
        if showReorganized && !reorganizedCards.isEmpty {
            return reorganizedCards.map { SubtitleCard(text: $0.text, start: $0.start, end: $0.end) }
        }
        return cachedSubtitleCards
    }

    /// Called by YouTubeEmbedPlayer's JS polling to update subtitles from YouTube's playback time.
    func updateSubtitleFromYouTube(time t: Double) {
        let cards = activeSubtitleCards
        let newIndex = cards.firstIndex { $0.start <= t && t < $0.end }
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            if let idx = newIndex, inspectorTab == .vocab, !markedWords.isEmpty {
                let lineText = cards[idx].text.lowercased()
                if let firstMatch = markedWords.sorted().first(where: { lineText.contains($0) }) {
                    vocabScrollTarget = firstMatch
                }
            }
        }
        currentSubtitleText = newIndex.map { cards[$0].text } ?? ""
        if showReorganized && !reorganizedCards.isEmpty, let idx = newIndex, idx < reorganizedCards.count {
            currentSubtitleTranslation = reorganizedCards[idx].translation
        } else {
            currentSubtitleTranslation = ""
        }
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        if youtubeWebView != nil {
            youtubeWebView?.evaluateJavaScript("var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}")
            isPlaying.toggle()
            return
        }
        guard let p = player else { return }
        if isPlaying {
            p.pause()
        } else {
            p.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: Double) {
        if let webView = youtubeWebView {
            webView.evaluateJavaScript("var v=document.querySelector('video');if(v){v.currentTime=\(time);v.play()}")
        } else {
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    var timeString: String {
        let fmt: (Double) -> String = { t in
            let m = Int(t) / 60
            let s = Int(t) % 60
            return String(format: "%d:%02d", m, s)
        }
        return "\(fmt(currentPlaybackTime)) / \(fmt(duration))"
    }
}
