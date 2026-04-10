/*
Abstract:
YouTube embed player (WKWebView) and native AVPlayer wrapper.
*/

import SwiftUI
import AVKit
import WebKit

// MARK: - YouTube Embed Player (WKWebView)

struct YouTubeEmbedPlayer: NSViewRepresentable {
    let videoID: String
    var onTimeUpdate: ((Double) -> Void)?
    var onWebViewReady: ((WKWebView) -> Void)?

    class Coordinator: NSObject, WKNavigationDelegate {
        var onTimeUpdate: ((Double) -> Void)?
        var timer: Timer?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Start polling YouTube player currentTime for subtitle sync
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                webView.evaluateJavaScript("document.querySelector('video')?.currentTime ?? -1") { result, _ in
                    if let time = result as? Double, time >= 0 {
                        self?.onTimeUpdate?(time)
                    }
                }
            }
        }

        deinit { timer?.invalidate() }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onTimeUpdate = onTimeUpdate
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        // Minimal CSS: hide YouTube chrome, force #movie_player to fill the viewport
        let jsSource = """
        (function() {
            // Force dark theme attribute
            document.documentElement.setAttribute('dark', '');
            var css = `
                html, body, ytd-app, #content, #page-manager, ytd-watch-flexy,
                #columns, #primary, #primary-inner {
                    margin:0!important; padding:0!important; overflow:hidden!important;
                    background:#000!important; background-color:#000!important;
                }
                #masthead-container, #secondary, #below, #comments, #related,
                ytd-masthead, #guide, tp-yt-app-drawer, ytd-mini-guide-renderer,
                ytd-popup-container, #clarify-box, #panels, #ticker,
                .ytp-paid-content-overlay, .ytp-chrome-top,
                .ytp-cards-button, .ytp-ce-element { display:none!important; }
                #movie_player, .html5-video-player {
                    position:fixed!important; top:0!important; left:0!important;
                    width:100vw!important; height:100vh!important;
                    z-index:99999!important; background:#000!important;
                }
                .html5-video-container, video {
                    position:absolute!important; left:0!important; top:0!important;
                    width:100%!important; height:100%!important;
                }
                video { object-fit:contain!important; }
                .ytp-chrome-bottom { opacity:0!important; transition:opacity .3s!important; }
                .html5-video-player:hover .ytp-chrome-bottom { opacity:1!important; }
            `;
            function apply() {
                if (!document.getElementById('yt-clean')) {
                    var s = document.createElement('style');
                    s.id = 'yt-clean';
                    s.textContent = css;
                    (document.head || document.documentElement).appendChild(s);
                }
            }
            apply();
            new MutationObserver(apply).observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: jsSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .black
        webView.setValue(false, forKey: "drawsBackground")  // Prevent white flash in light mode
        webView.navigationDelegate = context.coordinator

        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        webView.load(URLRequest(url: watchURL))
        DispatchQueue.main.async { onWebViewReady?(webView) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Native AVPlayerView with fullscreen button

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
