import CoreMedia
import CoreVideo

/// One screen image and the moment ScreenCaptureKit captured it.
// shortcut: @unchecked Sendable because CVPixelBuffer isn't annotated Sendable; safe because no stage writes into
// a buffer after capture (the Redactor renders into a fresh one). Revisit if a stage starts drawing in place.
struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Host-clock seconds (mach time, same clock as `Frame.now()`).
    let captureTime: CFTimeInterval

    static func now() -> CFTimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
