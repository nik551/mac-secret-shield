import AppKit

/// Displays frames by handing each pixel buffer's IOSurface (GPU memory) straight to Core Animation:
/// no copy, no NSImage. Also draws the FPS / latency readout.
@MainActor
final class FrameRenderer: NSView {
    private let statsLabel = NSTextField(labelWithString: "Waiting for frames…")
    private var frameCount = 0
    private var latencySum: CFTimeInterval = 0
    private var latencyMax: CFTimeInterval = 0
    private var windowStart = CACurrentMediaTime()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect // letterbox, never stretch

        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.drawsBackground = true
        statsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        statsLabel.frame.origin = NSPoint(x: 8, y: bounds.height - 26)
        statsLabel.autoresizingMask = [.minYMargin] // stay pinned to the top-left on resize
        addSubview(statsLabel)
        statsLabel.sizeToFit()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // We set layer.contents ourselves; tell AppKit not to redraw (and wipe) it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    private var pipeline = PipelineStats()

    func show(_ frame: Frame, stats: PipelineStats) {
        pipeline = stats
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit cross-fade between frames
        layer?.contents = surface
        CATransaction.commit()
        record(latency: Frame.now() - frame.captureTime)
    }

    func clear() {
        layer?.contents = nil
        frameCount = 0; latencySum = 0; latencyMax = 0
        windowStart = CACurrentMediaTime()
        setStats("Waiting for frames…")
    }

    /// Delay = capture timestamp → checked frame handed to Core Animation (the compositor adds ~1 refresh on top).
    private func record(latency: CFTimeInterval) {
        frameCount += 1
        latencySum += latency
        latencyMax = max(latencyMax, latency)
        let elapsed = CACurrentMediaTime() - windowStart
        guard elapsed >= 0.5 else { return }
        setStats(String(format: "%.1f fps · delay avg %.0f ms, max %.0f ms · OCR %.0f ms · %d redacted · %d fail-closed frames",
                        Double(frameCount) / elapsed, latencySum / Double(frameCount) * 1000, latencyMax * 1000,
                        pipeline.ocrMs, pipeline.redactions, pipeline.failClosedFrames))
        frameCount = 0; latencySum = 0; latencyMax = 0
        windowStart = CACurrentMediaTime()
    }

    private func setStats(_ text: String) {
        statsLabel.stringValue = text
        statsLabel.sizeToFit()
    }
}
