/*
Abstract:
Captures audio from the app's own window using ScreenCaptureKit.
Used for real-time transcription of YouTube live streams or any in-app media.
*/

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

@MainActor
final class LiveAudioCapture: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var audioLevel: Float = 0  // 0.0 - 1.0 for UI meters

    private var stream: SCStream?
    private var outputDelegate: AudioOutputDelegate?
    private var videoSink: VideoDropDelegate?

    /// Called on each audio buffer (16kHz mono Float32).
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Start capturing audio from the display (captures all system audio including WKWebView).
    /// - Parameter sampleRate: Audio sample rate. 48000 for Apple Speech.
    func startCapture(sampleRate: Int = 48000) async throws {
        guard !isCapturing else { return }

        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Use display-level capture to get all audio (WKWebView audio goes through
        // a separate WebContent process, so window-level capture misses it)
        guard let display = content.displays.first else {
            throw LiveCaptureError.windowNotFound
        }

        // Capture display audio, excluding nothing — we want all audio output
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = 1         // Mono
        config.excludesCurrentProcessAudio = false  // We want our own WKWebView audio
        // Disable video capture to avoid "stream output NOT found" errors
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimum

        let delegate = AudioOutputDelegate { [weak self] buffer in
            self?.onAudioBuffer?(buffer)
            // Update level meter
            if let channelData = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    sum += abs(channelData[i])
                }
                let avg = frames > 0 ? sum / Float(frames) : 0
                Task { @MainActor in
                    self?.audioLevel = min(avg * 5, 1.0)  // Scale for visibility
                }
            }
        }
        self.outputDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        // Add dummy video handler to suppress "stream output NOT found" errors
        let videoSink = VideoDropDelegate()
        try stream.addStreamOutput(videoSink, type: .screen, sampleHandlerQueue: .global(qos: .background))
        self.videoSink = videoSink
        try await stream.startCapture()

        self.stream = stream
        self.isCapturing = true
    }

    /// Stop capturing.
    func stopCapture() async {
        guard isCapturing else { return }
        try? await stream?.stopCapture()
        stream = nil
        outputDelegate = nil
        videoSink = nil
        isCapturing = false
        audioLevel = 0
    }
}

// MARK: - Audio Output Delegate

private class AudioOutputDelegate: NSObject, SCStreamOutput {
    let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy sample data into PCM buffer
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        onBuffer(pcmBuffer)
    }
}

// MARK: - Video Drop Delegate (suppresses "stream output NOT found" errors)

private class VideoDropDelegate: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Intentionally empty — we only need audio, this just prevents error logs
    }
}

// MARK: - Error

enum LiveCaptureError: LocalizedError {
    case windowNotFound
    case captureNotAuthorized

    var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return "Could not find app window for audio capture"
        case .captureNotAuthorized:
            return "Screen recording permission is required for live audio capture"
        }
    }
}
