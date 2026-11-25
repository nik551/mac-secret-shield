#if DEBUG
import CoreImage
import ImageIO
import os
import UniformTypeIdentifiers

/// Debug builds only, off by default, turned on only from the menu after a confirmation that the screen shows
/// synthetic test secrets only: writes every frame released to the mirror as a PNG so
/// TestFixtures/leak-check.swift can OCR what viewers saw. Folder 0700, files 0600. Never compiled into Release.
final class ViewerFrameSaver: @unchecked Sendable { // state is behind locks; CIContext is thread-safe
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SecretShield/ViewerFrames")

    private let folder = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private let inFlight = DispatchSemaphore(value: 8)
    private let writeQueue = DispatchQueue(label: "SecretShield.saver", attributes: .concurrent)
    private let context = CIContext()

    func setEnabled(_ on: Bool) {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let run = on ? Self.root.appending(path: name) : nil
        if let run {
            try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.root.path)
        }
        folder.withLock { $0 = run }
        counter.withLock { $0 = 0 }
    }

    func save(_ frame: Frame) {
        guard let folder = folder.withLock({ $0 }) else { return }
        inFlight.wait() // block rather than skip: the leak check must see every released frame
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { inFlight.signal(); return }
        let n = counter.withLock { $0 += 1; return $0 }
        writeQueue.async { [inFlight] in
            let url = folder.appending(path: String(format: "frame-%06d.png", n))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cgImage, nil)
                CGImageDestinationFinalize(destination)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            inFlight.signal()
        }
    }
}
#endif
