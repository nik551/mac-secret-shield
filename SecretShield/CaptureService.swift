import CoreMedia
@preconcurrency import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noMainDisplay, ownAppNotFound
    var errorDescription: String? {
        switch self {
        case .noMainDisplay: "Couldn't find the main display."
        case .ownAppNotFound: "Couldn't exclude SecretShield's own windows from capture, so the mirror was not started."
        }
    }
}

/// Streams the main display at 30 fps with this app's windows excluded and hands each complete frame to
/// `onFrame` on a background queue. Nothing here decides what is shown: the DelayBuffer does.
@MainActor
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: @Sendable (Frame) -> Void
    private let onStop: (any Error) -> Void
    private let frameQueue = DispatchQueue(label: "SecretShield.capture", qos: .userInteractive)
    private var stream: SCStream?

    init(onFrame: @escaping @Sendable (Frame) -> Void,
         onStop: @escaping (any Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noMainDisplay
        }
        // Excluding the whole app (not a window list) also covers windows we open after capture starts.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.filter { $0.processID == pid }
        guard !ownApp.isEmpty else { throw CaptureError.ownAppNotFound } // fail closed: no infinite mirror

        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale) // 2 on Retina: capture real pixels, not points
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8 // max; the DelayBuffer holds a few frames while checking
        config.showsCursor = false // the pointer never reaches viewers; hover changes are judged separately

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput / SCStreamDelegate — called by ScreenCaptureKit off the main thread.

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(Frame(pixelBuffer: pixelBuffer, captureTime: sampleBuffer.presentationTimeStamp.seconds))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.stream = nil
            self.onStop(error)
        }
    }

    /// ScreenCaptureKit also sends "idle"/"blank" status buffers with no new image; only `.complete` has pixels.
    nonisolated private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}
