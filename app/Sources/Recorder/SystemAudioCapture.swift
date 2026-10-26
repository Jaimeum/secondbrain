import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures everything the Mac plays (whole display's audio, so it also works with headphones and
/// AirPods) through ScreenCaptureKit. Video is configured as small as possible and discarded.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let videoQueue = DispatchQueue(label: "app.secondbrain.recorder.video-discard", qos: .background)
    private let onBuffer: (CMSampleBuffer) -> Void
    private let onStop: (Error) -> Void
    private var stream: SCStream?

    /// `onBuffer` runs on `queue`.
    init(queue: DispatchQueue, onBuffer: @escaping (CMSampleBuffer) -> Void, onStop: @escaping (Error) -> Void) {
        self.queue = queue
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Without a screen output SCK logs an error for every dropped video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        self.stream = nil
        onStop(error)
    }
}
