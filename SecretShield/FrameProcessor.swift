import CoreVideo

/// One captured screen image and the moment ScreenCaptureKit captured it.
// shortcut: @unchecked Sendable because CVPixelBuffer isn't annotated Sendable; safe while no stage writes into a
// buffer after capture. Revisit when the Redactor draws into buffers (give it its own output pool).
struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Host-clock seconds (mach time, same clock as `CACurrentMediaTime()`).
    let captureTime: CFTimeInterval
}

/// The stage between capture and display; OCR + redaction plug in here.
/// Runs on the capture queue. Return nil to drop the frame: the mirror then keeps showing the last frame
/// that was released, so an unchecked frame never reaches the shared window (fail closed).
protocol FrameProcessor: Sendable {
    func process(_ frame: Frame) -> Frame?
}

/// Weekend-1 placeholder: forwards every frame unchanged.
struct PassthroughProcessor: FrameProcessor {
    func process(_ frame: Frame) -> Frame? { frame }
}
