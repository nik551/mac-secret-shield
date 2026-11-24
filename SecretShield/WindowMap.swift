import AppKit

struct WindowInfo: Sendable, Equatable {
    let bundleID: String
    /// Frame pixels of the captured display, origin top-left.
    let frame: CGRect
    /// Area whose text this window owns, if wider than `frame` (the window list can lag the pixels while dragging).
    var reach: CGRect?

    var ownedArea: CGRect { reach ?? frame }
    var isTerminal: Bool { Self.terminalBundleIDs.contains(bundleID) }

    static let terminalBundleIDs: Set = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
    ]
}

protocol WindowSource: Sendable {
    /// Visible windows on the captured display, front to back, in pixels of a frame of `frameSize`.
    /// nil if the list can't be read or doesn't line up with the frame.
    func windows(frameSize: CGSize) -> [WindowInfo]?
}

/// Reads the window list once per checked frame.
/// Uses CGWindowList rather than SCShareableContent: it is synchronous (about 1 ms) and documented as
/// front-to-back, while SCShareableContent is async (tens of ms, so often stale) and doesn't document order.
/// A stale or misordered map would attribute terminal text to another app and skip detection.
struct LiveWindowSource: WindowSource {
    /// The display being captured. Window bounds are global (origin at the main display's top-left), so they are
    /// shifted by this display's origin; the main display can change while capturing (plugging in a monitor).
    let displayID: CGDirectDisplayID

    func windows(frameSize: CGSize) -> [WindowInfo]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let display = CGDisplayBounds(displayID)
        guard display.width > 0, display.height > 0 else { return nil } // display gone
        let scale = frameSize.width / display.width
        // The frame must have the display's shape; otherwise the display changed mode mid-capture.
        guard abs(frameSize.height / display.height - scale) < 0.01 else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier // our mirror isn't in the capture, so it can't own text
        return list.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return WindowInfo(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "",
                              frame: CGRect(x: (b.minX - display.minX) * scale, y: (b.minY - display.minY) * scale,
                                           width: b.width * scale, height: b.height * scale))
        }
    }
}
