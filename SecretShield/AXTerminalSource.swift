import AppKit
import ApplicationServices
import os

/// Terminal text from the Accessibility (AX) API instead of OCR, for Terminal.app and iTerm2 (Gate 1: exact text,
/// exact per-row bounds, sub-millisecond reads).
///
/// A poller on its own queue reads, every 10 ms, a *state* for each terminal window on the captured display:
/// window frame, and per text area its on-screen viewport, scroll offset, row height (font), cursor cell and a hash
/// of the visible text. When the state changes, the masks for the new state are computed while it is still current
/// (and thrown away if it changed during the computation).
///
/// A frame captured at t0 may use a window's masks only if that window's state was the same from `settle` before t0
/// up to a poll after t0: the terminal has drawn that state by t0, so the masks match the frame's pixels. Anything
/// else is "unverified" and the caller holds the last sanitized pixels for that window. Never a raw frame.
final class AXTerminalSource: @unchecked Sendable { // all mutable state is confined to `queue`
    static let bundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    /// How long after its AX state changes a terminal may still be drawing the old state. Terminal.app draws
    /// within about two display refreshes; iTerm2's renderer lagged its AX state by more than that in stress runs
    /// (masks one or two rows off while scrolling), so it gets a longer margin.
    static let settle: CFTimeInterval = 0.035
    static let settleByBundle: [String: CFTimeInterval] = ["com.apple.Terminal": 0.035, "com.googlecode.iterm2": 0.15]
    private static let log = Logger(subsystem: "SecretShield", category: "ax")

    struct Area: Equatable {
        var viewport: CGRect     // AX points: the on-screen part of the text area
        var textOrigin: CGPoint  // moves when the text scrolls
        var rowHeight: CGFloat   // changes with the font size
        var cursor: CGRect?      // the insertion point's cell
        var textHash: Int        // hash of the visible text (never stored or logged as text)
    }

    struct State: Equatable {
        var windowFrame: CGRect
        var areas: [Area]
    }

    enum Verdict {
        /// Masks and cursor cells in frame pixels for this frame; `state` identifies the version they belong to.
        case verified(state: State, masks: [CGRect], cursors: [CGRect], rowHeight: CGFloat)
        case unverified(reason: String)
    }

    private final class Window {
        let element: AXUIElement
        var settle = AXTerminalSource.settle
        var textAreas: [AXUIElement] = []
        var state: State?
        var stateSince: CFTimeInterval = 0
        var masks: [CGRect]? // AX points, for `state`
        var frames: [(time: CFTimeInterval, frame: CGRect)] = [] // AX points, last second: where the window has been
        init(element: AXUIElement) { self.element = element }
    }

    private let detector: SecretDetector
    private let displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "SecretShield.ax", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var windows: [Window] = []
    private var lastPoll: CFTimeInterval = 0
    private var lastDiscovery: CFTimeInterval = 0

    init(detector: SecretDetector, displayID: CGDirectDisplayID) {
        self.detector = detector
        self.displayID = displayID
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            windows = [] // drops all masks and text hashes for this session
        }
    }

    struct WindowVerdict {
        let id: Int          // stable for the window's lifetime
        let frame: CGRect    // frame pixels, latest
        let history: CGRect  // frame pixels: everywhere the window has been since shortly before capture
        let verdict: Verdict
    }

    /// A verdict for every Terminal/iTerm2 window AX tracks (not only those the window list shows: that list is read
    /// later than the frame and can briefly miss a window), for a frame captured at `capturedAt` of size
    /// `frameSize`. Call at least `settle` after capture.
    func verdicts(capturedAt t0: CFTimeInterval, frameSize: CGSize) -> [WindowVerdict] {
        queue.sync {
            guard let map = Self.pointsToPixels(displayID: displayID, frameSize: frameSize) else { return [] }
            let scale = frameSize.width / max(1, CGDisplayBounds(displayID).width)
            return windows.compactMap { window in
                guard let latest = window.frames.last?.frame else { return nil }
                let history = window.frames.filter { $0.time >= t0 - 0.1 }.reduce(map(latest)) { $0.union(map($1.frame)) }
                let verdict: Verdict
                if let state = window.state, let masks = window.masks {
                    if window.stateSince > t0 - window.settle {
                        verdict = .unverified(reason: "state changed around capture")
                    } else if lastPoll < t0 + 0.005 {
                        verdict = .unverified(reason: "no poll after capture")
                    } else {
                        verdict = .verified(state: state, masks: masks.map(map), cursors: state.areas.compactMap(\.cursor).map(map),
                                            rowHeight: (state.areas.map(\.rowHeight).max() ?? 0) * scale)
                    }
                } else {
                    verdict = .unverified(reason: "AX read failed")
                }
                return WindowVerdict(id: Int(CFHash(window.element)), frame: map(latest), history: history, verdict: verdict)
            }
        }
    }

    /// The pointer position in frame pixels (hovering may legitimately change a terminal row's pixels).
    func mouseInPixels(frameSize: CGSize) -> CGPoint? {
        guard let point = CGEvent(source: nil)?.location,
              let map = Self.pointsToPixels(displayID: displayID, frameSize: frameSize) else { return nil }
        return map(CGRect(origin: point, size: .zero)).origin
    }

    // MARK: Polling

    private func poll() {
        let now = Frame.now()
        if now - lastDiscovery > 0.1 { discover(); lastDiscovery = now }
        for window in windows {
            let state = read(window)
            if let frame = state?.windowFrame { window.frames.append((now, frame)) }
            window.frames.removeAll { now - $0.time > 1 }
            if state != window.state || window.masks == nil {
                window.state = state
                window.stateSince = now
                window.masks = state.flatMap { masks(for: window, state: $0) }
            }
        }
        lastPoll = Frame.now()
    }

    /// Finds the AX windows of Terminal and iTerm2 (only those in the current Space are listed, which is what's on
    /// screen) and their text areas. Keeps already-tracked windows so their state history survives.
    private func discover() {
        var found: [Window] = []
        for app in NSWorkspace.shared.runningApplications where Self.bundleIDs.contains(app.bundleIdentifier ?? "") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.05) // a hung terminal must not stall the mirror
            for windowElement in children(element, kAXWindowsAttribute) {
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &minimized)
                if (minimized as? Bool) == true { continue } // not on screen
                let window = windows.first { CFEqual($0.element, windowElement) } ?? Window(element: windowElement)
                window.settle = Self.settleByBundle[app.bundleIdentifier ?? ""] ?? 0.15
                window.textAreas = textAreas(in: windowElement, depth: 0)
                found.append(window)
            }
        }
        windows = found
    }

    private func read(_ window: Window) -> State? {
        guard let position: CGPoint = value(window.element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = value(window.element, kAXSizeAttribute, .cgSize) else { return nil }
        var areas: [Area] = []
        for text in window.textAreas {
            guard let area = readArea(text) else { Self.log.notice("ax state read failed: text area"); return nil }
            areas.append(area)
        }
        return State(windowFrame: CGRect(origin: position, size: size), areas: areas)
    }

    private func readArea(_ text: AXUIElement) -> Area? {
        guard let origin: CGPoint = value(text, kAXPositionAttribute, .cgPoint),
              let viewport = viewport(of: text),
              let visible = visibleRange(text, viewport: viewport),
              let string = string(text, visible) else { return nil }
        let first: CGRect? = bounds(text, CFRange(location: visible.location, length: 1))
        var cursor: CGRect?
        if let selection: CFRange = value(text, kAXSelectedTextRangeAttribute, .cfRange) {
            cursor = bounds(text, CFRange(location: selection.location, length: 1))
        }
        return Area(viewport: viewport, textOrigin: origin, rowHeight: first?.height ?? 0, cursor: cursor, textHash: string.hashValue)
    }

    /// Masks for `state`: every secret value (key names stay visible), one rect per visual row, clipped to the
    /// viewport. nil if AX failed or the state changed while reading (the masks would not belong to `state`).
    private func masks(for window: Window, state: State) -> [CGRect]? {
        var masks: [CGRect] = []
        for (text, area) in zip(window.textAreas, state.areas) {
            guard let visible = visibleRange(text, viewport: area.viewport) else { return fail("visible range") }
            // Read some text around the visible rows too, so a value whose key scrolled off is still recognised.
            let total = (number(text, kAXNumberOfCharactersAttribute) ?? (visible.location + visible.length))
            let start = max(0, visible.location - 4096), end = min(total, visible.location + visible.length + 1024)
            guard let context = string(text, CFRange(location: start, length: end - start)) else { return fail("string") }
            let visibleRange = NSRange(location: visible.location - start, length: visible.length)
            for secret in detector.secretRanges(in: context) {
                // Only the rows on screen (the corner probe includes partly visible edge rows): iTerm2 has no
                // bounds for characters outside the viewport.
                let onScreen = NSIntersectionRange(secret, visibleRange)
                guard onScreen.length > 0 else { continue }
                let rows = rowRects(text, CFRange(location: start + onScreen.location, length: onScreen.length), rowHeight: area.rowHeight,
                                    isBreak: { i in (context as NSString).character(at: i - start) == 10 })
                guard let rows else { return fail("row bounds (row height \(Int(area.rowHeight)))") }
                masks += rows.compactMap { r in
                    let clipped = r.intersection(area.viewport)
                    return clipped.isNull || clipped.isEmpty ? nil : clipped
                }
            }
        }
        return read(window) == state ? masks : fail("state moved while computing")
    }

    private func fail(_ step: String) -> [CGRect]? {
        Self.log.notice("ax masks failed at: \(step, privacy: .public)") // which step only, never text
        return nil
    }

    /// Bounds one visual row at a time: a range taller than one row (iTerm2 returns whole wrapped lines) is split
    /// at the longest prefix that fits in a row, found by bisection. nil if AX fails.
    /// `isBreak(i)`: character i (absolute index) is a line break, which has no bounds of its own (iTerm2) and
    /// is skipped; any other character without bounds fails the whole computation.
    private func rowRects(_ text: AXUIElement, _ range: CFRange, rowHeight: CGFloat, isBreak: (Int) -> Bool) -> [CGRect]? {
        guard rowHeight > 0 else { return nil }
        let fits = { (r: CGRect?) in r.map { $0.height <= rowHeight * 1.3 } ?? false }
        var rects: [CGRect] = []
        var charWidth: CGFloat?
        var start = range.location
        let end = range.location + range.length
        while start < end {
            if let whole = bounds(text, CFRange(location: start, length: end - start)), fits(whole) { rects.append(whole); break }
            var lo = 0, hi = end - start
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if fits(bounds(text, CFRange(location: start, length: mid))) { lo = mid } else { hi = mid - 1 }
            }
            if lo == 0, isBreak(start) { start += 1; continue }
            if lo == 0, let one = bounds(text, CFRange(location: start, length: 1)), one.height > rowHeight * 1.3 {
                // iTerm2 gives the character at a soft wrap a box spanning both rows, full width. Cover one cell at
                // the end of the upper row and one at the start of the lower row (the character is in one of them).
                let cell = charWidth ?? rowHeight * 0.6
                rects.append(CGRect(x: one.maxX - cell, y: one.minY, width: cell, height: rowHeight))
                rects.append(CGRect(x: one.minX, y: one.maxY - rowHeight, width: cell, height: rowHeight))
                start += 1
                continue
            }
            guard lo > 0, let row = bounds(text, CFRange(location: start, length: lo)) else { return nil }
            rects.append(row)
            charWidth = row.width / CGFloat(lo)
            start += lo
        }
        return rects
    }

    /// Neither terminal reports only the on-screen characters (Terminal: empty, iTerm2: everything), so ask which
    /// characters sit at the viewport's top-left and bottom-right corners.
    private func visibleRange(_ text: AXUIElement, viewport: CGRect) -> CFRange? {
        guard let first: CFRange = parameter(text, kAXRangeForPositionParameterizedAttribute,
                                             CGPoint(x: viewport.minX + 1, y: viewport.minY + 1)),
              let last: CFRange = parameter(text, kAXRangeForPositionParameterizedAttribute,
                                            CGPoint(x: viewport.maxX - 1, y: viewport.maxY - 1)) else { return nil }
        let end = last.location + max(1, last.length)
        return end > first.location ? CFRange(location: first.location, length: end - first.location) : nil
    }

    private func viewport(of text: AXUIElement) -> CGRect? {
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(text, kAXParentAttribute as CFString, &parent)
        let element = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil } ?? text // swiftlint:disable:this force_cast
        guard let p: CGPoint = value(element, kAXPositionAttribute, .cgPoint), let s: CGSize = value(element, kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: AX helpers

    private func textAreas(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if role as? String == kAXTextAreaRole { return [element] } // iTerm2 split panes: one per pane
        guard depth < 8 else { return [] }
        return children(element, kAXChildrenAttribute).flatMap { textAreas(in: $0, depth: depth + 1) }
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private func string(_ text: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard let arg = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(text, kAXStringForRangeParameterizedAttribute as CFString, arg, &raw) == .success else { return nil }
        return raw as? String
    }

    private func bounds(_ text: AXUIElement, _ range: CFRange) -> CGRect? {
        parameter(text, kAXBoundsForRangeParameterizedAttribute, range)
    }

    private func parameter<T>(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> T? {
        var range = range
        guard let arg = AXValueCreate(.cfRange, &range) else { return nil }
        return parameter(element, attribute, arg)
    }

    private func parameter<T>(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> T? {
        var point = point
        guard let arg = AXValueCreate(.cgPoint, &point) else { return nil }
        return parameter(element, attribute, arg)
    }

    private func parameter<T>(_ element: AXUIElement, _ attribute: String, _ arg: AXValue) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, arg, &raw) == .success else { return nil }
        return unpack(raw)
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return unpack(raw)
    }

    private func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        var raw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        return (raw as? NSNumber)?.intValue
    }

    private func unpack<T>(_ raw: CFTypeRef?) -> T? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue // swiftlint:disable:this force_cast (type checked above)
        switch AXValueGetType(axValue) {
        case .cgPoint: var v = CGPoint.zero; return AXValueGetValue(axValue, .cgPoint, &v) ? v as? T : nil
        case .cgSize: var v = CGSize.zero; return AXValueGetValue(axValue, .cgSize, &v) ? v as? T : nil
        case .cgRect: var v = CGRect.zero; return AXValueGetValue(axValue, .cgRect, &v) ? v as? T : nil
        case .cfRange: var v = CFRange(); return AXValueGetValue(axValue, .cfRange, &v) ? v as? T : nil
        default: return nil
        }
    }

    /// AX points (global, top-left origin) → pixels of a frame of the captured display.
    static func pointsToPixels(displayID: CGDirectDisplayID, frameSize: CGSize) -> ((CGRect) -> CGRect)? {
        let display = CGDisplayBounds(displayID)
        guard display.width > 0 else { return nil }
        let scale = frameSize.width / display.width
        return { r in CGRect(x: (r.minX - display.minX) * scale, y: (r.minY - display.minY) * scale,
                             width: r.width * scale, height: r.height * scale) }
    }
}
