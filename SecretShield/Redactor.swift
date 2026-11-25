import CoreImage
import CoreVideo

/// Draws opaque black blocks (never blur) over rects, on the GPU via Core Image, into a fresh buffer.
// Only used from the DelayBuffer's queue; CIContext itself is thread-safe.
final class Redactor: @unchecked Sendable {
    // No colour management: output pixels are byte-identical to the input outside the blocks.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    /// `rects` are frame pixels, top-left origin, covered in black. `holds` are areas whose current pixels are not
    /// verified: they show the same area of `lastSafe` (the last released frame) instead, or black if there is none.
    /// Returns nil if it couldn't draw (caller must then drop the frame).
    func redact(_ frame: Frame, covering rects: [CGRect], holding holds: [CGRect] = [], from lastSafe: Frame? = nil) -> Frame? {
        guard !rects.isEmpty || !holds.isEmpty else { return frame }
        let input = frame.pixelBuffer
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        var image = CIImage(cvPixelBuffer: input)
        let black = CIImage(color: .black)
        let held = lastSafe.flatMap { safe in
            CVPixelBufferGetWidth(safe.pixelBuffer) == w && CVPixelBufferGetHeight(safe.pixelBuffer) == h
                ? CIImage(cvPixelBuffer: safe.pixelBuffer) : nil
        } ?? black
        for r in holds {
            image = held.cropped(to: CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
                .composited(over: image)
        }
        for r in rects { // Core Image's origin is bottom-left
            image = black.cropped(to: CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
                .composited(over: image)
        }
        guard let output = makeBuffer(width: w, height: h) else { return nil }
        CVBufferPropagateAttachments(input, output) // keep the colour space tags so it displays identically
        // Wait for the GPU: releasing a half-drawn buffer could show pixels before the blocks land.
        do {
            try context.startTask(toRender: image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)),
                                  to: CIRenderDestination(pixelBuffer: output)).waitUntilCompleted()
        } catch {
            return nil
        }
        return Frame(pixelBuffer: output, captureTime: frame.captureTime)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, // lets the mirror's layer show it without a copy
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
