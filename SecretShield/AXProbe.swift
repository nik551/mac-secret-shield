#if DEBUG
import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// Gate 1 feasibility probe (debug only, not used by the mirror): can terminal text and per-row bounds come from
/// the Accessibility API instead of OCR? For Terminal.app and iTerm2, on a window titled "SecretShield AX probe"
/// (TestFixtures/show-fake-env.sh), it reports which AX attributes exist, compares the visible text with the fake
/// fixture, runs SecretDetector on it, asks for bounds one visual row at a time, outlines those rows on screen and
/// screenshots the result, then repeats after scrolling, resizing, a font change, a narrow window and (if there is
/// one) a move to the other display.
///
/// Writes ~/Library/Caches/SecretShield/AXProbe/report.md plus PNGs (folder 0700, files 0600). The report has
/// key names, counts and timings only, never values. Screenshots show the synthetic fixture secrets only.
@MainActor
final class AXProbe {
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SecretShield/AXProbe")
    static let windowTitle = "SecretShield AX probe"
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "TestFixtures")

    private let overlay = OutlineOverlay()
    private var report = ""

    /// Runs every scenario for both terminals and returns the report file.
    func run() async -> URL? {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // kAXTrustedCheckOptionPrompt (a global var Swift 6 rejects)
        guard AXIsProcessTrustedWithOptions(prompt) else { return nil } // macOS shows the Accessibility prompt
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let detector = try? SecretDetector.bundled(), let fixture = try? Fixture.load(from: Self.fixtures) else {
            return nil
        }
        report = "# AX probe report\n\n\(Date())  •  displays: \(NSScreen.screens.count)\n"
        for (name, bundleID) in [("Terminal", "com.apple.Terminal"), ("iTerm2", "com.googlecode.iterm2")] {
            await probe(terminal: name, bundleID: bundleID, fixture: fixture, detector: detector)
        }
        let url = Self.folder.appending(path: "report.md")
        try? report.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // MARK: Scenarios

    private func probe(terminal name: String, bundleID: String, fixture: Fixture, detector: SecretDetector) async {
        report += "\n## \(name)\n\n"
        guard let (pid, found) = await prepareWindow(terminal: name, bundleID: bundleID) else { return }
        let originalPosition: CGPoint? = value(found, kAXPositionAttribute, .cgPoint)
        let originalSize: CGSize? = value(found, kAXSizeAttribute, .cgSize)

        let window = found
        var scenarios: [(String, () async -> Void)] = [
            ("baseline", {}),
            ("scrolled up (scroll bar moved)", { [self] in scrollUp(window, pid: pid) }),
            ("resized 1000x560", { [self] in set(window, kAXSizeAttribute, CGSize(width: 1000, height: 560)) }),
            ("font bigger (View menu, twice)", { [self] in
                for _ in 0..<2 { pressMenuItem(pid, titles: ["Make Text Bigger", "Bigger"]) }
            }),
            ("narrow 440 wide, keys wrap", { [self] in
                for _ in 0..<2 { pressMenuItem(pid, titles: ["Make Text Smaller", "Smaller"]) } // font back first
                set(window, kAXSizeAttribute, CGSize(width: 440, height: 700))
                scrollBar(window, to: 1) // back to the bottom, where the secrets are
            }),
        ]
        if let other = NSScreen.screens.first(where: { !$0.frame.contains(cocoaPoint(originalPosition ?? .zero)) }) {
            scenarios.append(("on the other display (\(other.localizedName))", { [self] in
                set(window, kAXSizeAttribute, CGSize(width: 1000, height: 560))
                set(window, kAXPositionAttribute, axPoint(top: other.frame.maxY - 60, left: other.frame.minX + 60))
                scrollBar(window, to: 1)
            }))
        } else {
            report += "_Only one display connected: the MacBook vs external display case was not tested._\n\n"
        }

        for (i, (scenario, action)) in scenarios.enumerated() {
            await action()
            try? await Task.sleep(for: .seconds(1.2)) // let the terminal reflow and redraw
            report += "### \(scenario)\n\n"
            await measure(window, terminal: name, scenario: i, fixture: fixture, detector: detector, listAttributes: i == 0)
        }

        scroll(pid: pid, window: window, lines: -40)
        if let originalSize { set(window, kAXSizeAttribute, originalSize) }
        if let originalPosition { set(window, kAXPositionAttribute, originalPosition) }
    }

    /// Finds the probe/stress page in `bundleID`'s windows, brings it to the front in its own (not full-screen)
    /// window, and returns it. Notes problems in the report.
    private func prepareWindow(terminal name: String, bundleID: String) async -> (pid_t, AXUIElement)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            report += "Not running. Open it with `open -a \(name) TestFixtures/show-fake-env.sh`.\n"
            return nil
        }
        let pid = app.processIdentifier
        // AX lists only windows in the current Space: activate the app, then pick the page from its Window menu
        // (which also selects it if it's a background tab) so macOS switches to wherever it is.
        for _ in 0..<10 { // a page that was just opened may take a few seconds to appear
            confirmFixtureScript(pid)
            app.activate()
            try? await Task.sleep(for: .seconds(1))
            if probeWindow(AXUIElementCreateApplication(pid)) != nil { break }
            if selectProbeTab(pid) { try? await Task.sleep(for: .seconds(1.5)) }
            if probeWindow(AXUIElementCreateApplication(pid)) != nil { break }
        }
        guard var found = probeWindow(AXUIElementCreateApplication(pid)) else {
            report += "No window or tab showing the probe page. Run `open -a \(name) TestFixtures/show-fake-env.sh`.\n"
            report += "Windows and tabs seen: \(windowAndTabTitles(pid).joined(separator: " | "))\n"
            return nil
        }
        app.activate()
        AXUIElementPerformAction(found, kAXRaiseAction as CFString) // menu commands act on the front window
        try? await Task.sleep(for: .milliseconds(600))
        // A full-screen window can't be resized or moved, and a page opened next to one lands in it as a tab.
        if isFullScreen(found) {
            pressMenuItem(pid, titles: ["Move Tab to New Window"])
            try? await Task.sleep(for: .seconds(1.5))
            if let moved = probeWindow(AXUIElementCreateApplication(pid)) { found = moved }
            if isFullScreen(found) {
                AXUIElementSetAttributeValue(found, "AXFullScreen" as CFString, kCFBooleanFalse)
                try? await Task.sleep(for: .seconds(1.5))
            }
            report += isFullScreen(found) ? "_Window is still full screen: resize/move scenarios can't take effect._\n\n"
                                           : "_The page was a tab in a full-screen window; moved it to its own window first._\n\n"
            AXUIElementPerformAction(found, kAXRaiseAction as CFString)
        }
        return (pid, found)
    }

    // MARK: Gate 2 stress run

    /// One stress run over Terminal and iTerm2 pages (TestFixtures/stress-page.sh): waits through the fast printing,
    /// then fast scrolling, dragging, resizing, font changes, a trip to the other display and back, and the pointer
    /// hovering over the rows. Returns false without Accessibility permission. Leaves the windows where they were.
    func stress() async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for (name, bundleID) in [("Terminal", "com.apple.Terminal"), ("iTerm2", "com.googlecode.iterm2")] {
            guard let (pid, window) = await prepareWindow(terminal: name, bundleID: bundleID) else { continue }
            let step = { (ms: Int) in try? await Task.sleep(for: .milliseconds(ms)) }
            await step(6000) // the page prints the fixture as fast as it can for a few seconds
            for i in 0..<30 { scrollBar(window, to: i % 2 == 0 ? 0 : 1); await step(40) } // fast scrolling
            scrollBar(window, to: 1)
            if let start: CGPoint = value(window, kAXPositionAttribute, .cgPoint) { // dragging
                for i in 0..<40 { set(window, kAXPositionAttribute, CGPoint(x: start.x + CGFloat(i * 8), y: start.y + CGFloat(i * 4))); await step(16) }
                for i in (0..<40).reversed() { set(window, kAXPositionAttribute, CGPoint(x: start.x + CGFloat(i * 8), y: start.y + CGFloat(i * 4))); await step(16) }
            }
            if let size: CGSize = value(window, kAXSizeAttribute, .cgSize) { // resizing: rows rewrap
                for i in 0..<20 { set(window, kAXSizeAttribute, CGSize(width: max(420, size.width - CGFloat(i * 25)), height: size.height)); await step(30) }
                set(window, kAXSizeAttribute, size)
                await step(300)
            }
            for _ in 0..<2 { pressMenuItem(pid, titles: ["Make Text Bigger", "Bigger"]); await step(400) }
            for _ in 0..<2 { pressMenuItem(pid, titles: ["Make Text Smaller", "Smaller"]); await step(400) }
            if let start: CGPoint = value(window, kAXPositionAttribute, .cgPoint),
               let other = NSScreen.screens.first(where: { !$0.frame.contains(cocoaPoint(start)) }) { // other display
                set(window, kAXPositionAttribute, axPoint(top: other.frame.maxY - 60, left: other.frame.minX + 60))
                await step(1200)
                set(window, kAXPositionAttribute, start)
                await step(800)
            }
            if let p: CGPoint = value(window, kAXPositionAttribute, .cgPoint), let s: CGSize = value(window, kAXSizeAttribute, .cgSize) {
                for i in 0..<60 { // hovering over the rows
                    let point = CGPoint(x: p.x + 40 + CGFloat(i * 7).truncatingRemainder(dividingBy: max(1, s.width - 80)),
                                        y: p.y + 60 + CGFloat(i * 9).truncatingRemainder(dividingBy: max(1, s.height - 100)))
                    CGWarpMouseCursorPosition(point)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                    await step(30)
                }
            }
            await step(800)
        }
        await closePages()
        let notes = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SecretShield/stress-notes.md")
        try? (report.isEmpty ? "ok\n" : report).write(to: notes, atomically: true, encoding: .utf8) // no text, only notes
        return true
    }

    /// iTerm2 asks "OK to run …?" for every script opened with `open -a iTerm`. Press OK, but only for our own
    /// fixture scripts (never ticks "suppress permanently").
    private func confirmFixtureScript(_ pid: pid_t) {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] {
            let items = children(window)
            let texts = items.compactMap { e -> String? in
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v)
                return v as? String
            }
            guard texts.contains(where: { $0.hasPrefix("OK to run") && $0.contains("/TestFixtures/") && $0.contains(".sh") }) else { continue }
            if let ok = items.first(where: { title($0) == "OK" }) { AXUIElementPerformAction(ok, kAXPressAction as CFString) }
        }
    }

    /// Debug aid: what iTerm2's windows say (titles, static texts, buttons), written to stress-notes.md.
    func dumpITermWindows() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first else { return }
        var lines: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            var role: CFTypeRef?, value: CFTypeRef?, title: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &value)
            AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
            let r = role as? String ?? "?"
            if r != kAXTextAreaRole, let t = (value as? String) ?? (title as? String), !t.isEmpty { lines.append("\(String(repeating: " ", count: depth))\(r): \(t.prefix(200))") }
            guard depth < 6, r != kAXTextAreaRole else { return }
            for c in children(e) { walk(c, depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
        for w in (windows as? [AXUIElement]) ?? [] { lines.append("WINDOW"); walk(w, 0) }
        try? lines.joined(separator: "\n").write(to: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "SecretShield/stress-notes.md"), atomically: true, encoding: .utf8)
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        var c: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c)
        return (c as? [AXUIElement]) ?? []
    }

    /// Ends every probe/stress page's `sleep` and closes all their windows, so the next run starts clean.
    func closePages() async {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "sleep 86400"]
        try? kill.run()
        kill.waitUntilExit()
        try? await Task.sleep(for: .milliseconds(800))
        for bundleID in ["com.apple.Terminal", "com.googlecode.iterm2"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            while let window = probeWindow(AXUIElementCreateApplication(app.processIdentifier)) {
                var close: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close)
                guard let close, CFGetTypeID(close) == AXUIElementGetTypeID(),
                      AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) == .success else { break } // swiftlint:disable:this force_cast
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    // MARK: Measurement

    private func measure(_ window: AXUIElement, terminal: String, scenario: Int, fixture: Fixture,
                         detector: SecretDetector, listAttributes: Bool) async {
        guard let (text, path) = textElement(in: window) else {
            report += "- No AXTextArea found in the window.\n\n"
            return
        }
        report += "- Text element: \(path.joined(separator: " > "))\n"
        let textFrame: CGRect? = {
            guard let p: CGPoint = value(text, kAXPositionAttribute, .cgPoint), let s: CGSize = value(text, kAXSizeAttribute, .cgSize) else { return nil }
            return CGRect(origin: p, size: s)
        }()
        // The text area can be taller than the window (whole scrollback); what's on screen is its scroll area.
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(text, kAXParentAttribute as CFString, &parent)
        let viewport: CGRect? = {
            guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return textFrame }
            let scrollArea = parent as! AXUIElement // swiftlint:disable:this force_cast (type checked above)
            guard let p: CGPoint = value(scrollArea, kAXPositionAttribute, .cgPoint),
                  let s: CGSize = value(scrollArea, kAXSizeAttribute, .cgSize) else { return textFrame }
            return CGRect(origin: p, size: s)
        }()
        report += "- Frames (AX points, top-left origin): text area \(describe(textFrame)), on-screen viewport \(describe(viewport))\n"
        let attributes = names(text, AXUIElementCopyAttributeNames)
        let parameterized = names(text, AXUIElementCopyParameterizedAttributeNames)
        if listAttributes {
            report += "- Attributes: \(attributes.sorted().joined(separator: ", "))\n"
            report += "- Parameterized attributes: \(parameterized.sorted().joined(separator: ", "))\n"
        }

        // Visible text: AXVisibleCharacterRange + AXStringForRange, else the whole AXValue.
        var visible: CFRange?
        var string: String?
        var readTimes: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            visible = value(text, kAXVisibleCharacterRangeAttribute, .cfRange)
            if let visible { string = parameter(text, kAXStringForRangeParameterizedAttribute, axValue(visible)) as? String }
            readTimes.append(ms(since: start))
        }
        var source = "AXVisibleCharacterRange + AXStringForRange"
        if string == nil || visible?.length == 0 {
            var whole: CFTypeRef?
            let start = ContinuousClock.now
            AXUIElementCopyAttributeValue(text, kAXValueAttribute as CFString, &whole)
            readTimes = [ms(since: start)]
            string = whole as? String
            visible = string.map { CFRange(location: 0, length: ($0 as NSString).length) }
            source = "AXValue (whole buffer; AXVisibleCharacterRange was empty or unsupported)"
        }
        guard let string, let visible else {
            report += "- Could not read any text.\n\n"
            return
        }
        report += "- Text read via \(source): \(visible.length) chars, \(stats(readTimes)) per read (5 reads)"
        var total: CFTypeRef?
        AXUIElementCopyAttributeValue(text, kAXNumberOfCharactersAttribute as CFString, &total)
        if let total = (total as? NSNumber)?.intValue {
            report += visible.length >= total ? " — NOTE: the \"visible\" range is the whole buffer (\(total) chars), not just what's on screen" : " of \(total) in the buffer"
        }
        report += "\n"
        let rowHeight: CGFloat = (parameterValue(text, kAXBoundsForRangeParameterizedAttribute,
                                                 CFRange(location: visible.location, length: 1), .cgRect) as CGRect?)?.height ?? 0

        // Visual rows: AXRangeForLine if supported, else newline-separated lines.
        let rowsStart = ContinuousClock.now
        let rows = visualRows(text, visible: visible, string: string, useAX: parameterized.contains("AXRangeForLine"))
        report += "- Rows: \(rows.ranges.count) via \(rows.source) (\(String(format: "%.1f", ms(since: rowsStart))) ms total)"
        let tallRows = rows.ranges.filter { row in
            guard row.length > 0, let r: CGRect = parameterValue(text, kAXBoundsForRangeParameterizedAttribute,
                                                                  CFRange(location: visible.location + row.location, length: row.length), .cgRect) else { return false }
            return r.height > rowHeight * 1.3
        }.count
        report += "; one character is \(Int(rowHeight)) pt tall; \(tallRows) of these \"rows\" span more than one visual row (wrapped lines)\n"

        // Accuracy against the fixture.
        let located = fixture.lines.map { line in (line, Fixture.locate(line.text, in: string)) }
        let exact = located.filter { $0.1?.exact == true }.count
        let split = located.filter { $0.1?.exact == false }
        let missing = located.filter { $0.1 == nil }
        report += "- Fixture lines in the visible text: \(exact) exact"
        report += split.isEmpty ? "" : ", \(split.count) only with row breaks removed (\(split.map(\.0.name).joined(separator: ", ")))"
        report += missing.isEmpty ? "" : ", \(missing.count) not visible (\(missing.map(\.0.name).joined(separator: ", ")))"
        report += "\n"

        // Detection, then bounds one visual row at a time.
        let detected = detector.secretRanges(in: string)
        var outlines: [CGRect] = []
        var boundsTimes: [Double] = []
        var lineNotes: [String] = []
        for (line, match) in located {
            guard let match, let valueRange = match.valueRange else { continue }
            let covered = detected.filter { NSIntersectionRange($0, valueRange).length > 0 }
            let union = covered.reduce(NSRange(location: NSNotFound, length: 0)) { $0.location == NSNotFound ? $1 : NSUnionRange($0, $1) }
            let full = union.location != NSNotFound && NSIntersectionRange(union, valueRange).length == valueRange.length
            var rects: [CGRect] = []
            for row in rows.ranges {
                let piece = NSIntersectionRange(row, union.location == NSNotFound ? NSRange(location: 0, length: 0) : union)
                guard piece.length > 0 else { continue }
                rects += visualRowRects(text, CFRange(location: visible.location + piece.location, length: piece.length),
                                        rowHeight: rowHeight, times: &boundsTimes)
            }
            if let viewport { rects = rects.filter { $0.intersects(viewport) } } // rows scrolled out of view need no outline
            outlines += rects
            let byDesign = line.name == "DATABASE_URL" ? " (by design: only the password)" : line.name.hasPrefix("PEM BEGIN") ? " (by design: from BEGIN on)" : ""
            var note = "\(line.name): " + (covered.isEmpty ? "NOT detected" : full ? "detected fully" : "detected partly" + byDesign)
            if !rects.isEmpty {
                let heights = rects.map { Int($0.height.rounded()) }
                note += ", \(rects.count) on-screen row rect(s) (heights \(heights.map(String.init).joined(separator: "/")) pt)"
            }
            if let keyRange = match.keyRange, union.location != NSNotFound,
               let keyRect: CGRect = parameterValue(text, kAXBoundsForRangeParameterizedAttribute,
                                                    CFRange(location: visible.location + keyRange.location, length: keyRange.length), .cgRect),
               let first = rects.first {
                // Key and value on the same row: the value outline must start where "KEY=" ends.
                if abs(first.midY - keyRect.midY) < first.height / 2 {
                    note += first.minX + 0.5 >= keyRect.maxX ? ", key name clear" : ", OVERLAPS key name by \(Int(keyRect.maxX - first.minX)) pt"
                }
            }
            lineNotes.append(note)
        }
        report += "- Bounds: \(boundsTimes.count) queries (per visual row, splitting wrapped rows), \(stats(boundsTimes)) each\n"
        if let first = outlines.first { report += "- First value rect: \(describe(first))\n" }
        report += lineNotes.filter { !$0.hasPrefix("PEM line") }.map { "  - \($0)\n" }.joined()
        let pem = lineNotes.filter { $0.hasPrefix("PEM line") }
        if !pem.isEmpty { report += "  - PEM body lines: \(pem.filter { $0.contains("detected fully") }.count)/\(pem.count) detected fully\n" }

        // Outline the rows on screen and keep a screenshot of the terminal window.
        overlay.show(outlines + [viewport].compactMap { $0 })
        try? await Task.sleep(for: .milliseconds(300))
        let windowRect: CGRect? = {
            guard let p: CGPoint = value(window, kAXPositionAttribute, .cgPoint),
                  let s: CGSize = value(window, kAXSizeAttribute, .cgSize) else { return nil }
            return CGRect(origin: p, size: s)
        }()
        if let windowRect {
            let file = "\(terminal.lowercased())-\(scenario).png"
            if await screenshot(windowRect, to: Self.folder.appending(path: file)) {
                report += "- Screenshot with outlines: `\(file)`\n"
            }
        }
        overlay.orderOut(nil)
        report += "\n"
    }

    private func visualRows(_ text: AXUIElement, visible: CFRange, string: String, useAX: Bool) -> (ranges: [NSRange], source: String) {
        if useAX, let first: Int = intParameter(text, kAXLineForIndexParameterizedAttribute, visible.location),
           let last: Int = intParameter(text, kAXLineForIndexParameterizedAttribute, visible.location + max(0, visible.length - 1)),
           last >= first {
            let ranges = (first...last).compactMap { line -> NSRange? in
                guard let r: CFRange = parameterValue(text, kAXRangeForLineParameterizedAttribute, line, .cfRange) else { return nil }
                return NSRange(location: r.location - visible.location, length: r.length) // relative to the visible string
            }
            if !ranges.isEmpty { return (ranges, "AXLineForIndex + AXRangeForLine") }
        }
        var ranges: [NSRange] = []
        (string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (string as NSString).length),
                                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in ranges.append(range) }
        return (ranges, "newlines in the text (AXRangeForLine unsupported or failed)")
    }

    /// Bounds for `range`, one rect per visual row: if a range comes back taller than one row (a wrapped line), find
    /// the longest prefix that fits in one row by bisection and continue after it.
    private func visualRowRects(_ text: AXUIElement, _ range: CFRange, rowHeight: CGFloat, times: inout [Double]) -> [CGRect] {
        func bounds(_ location: Int, _ length: Int) -> CGRect? {
            let start = ContinuousClock.now
            defer { times.append(ms(since: start)) }
            return parameterValue(text, kAXBoundsForRangeParameterizedAttribute, CFRange(location: location, length: length), .cgRect)
        }
        let fits = { (r: CGRect?) in r.map { rowHeight > 0 && $0.height <= rowHeight * 1.3 } ?? false }
        var rects: [CGRect] = []
        var start = range.location
        let end = range.location + range.length
        while start < end {
            if let whole = bounds(start, end - start), fits(whole) { rects.append(whole); break }
            var lo = 0, hi = end - start // longest length that fits in one row
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if fits(bounds(start, mid)) { lo = mid } else { hi = mid - 1 }
            }
            if lo == 0 { start += 1; continue } // no bounds for this character; skip it
            if let r = bounds(start, lo) { rects.append(r) }
            start += lo
        }
        return rects
    }

    /// Terminal shows only the selected tab's text; press the tab whose title mentions the probe page.
    /// Terminal doesn't expose its tabs as AX elements, but its Window menu lists every tab by title.
    private func selectProbeTab(_ pid: pid_t) -> Bool {
        if let tab = tabs(pid).first(where: { title($0).map { t in Self.tabHints.contains { t.contains($0) } } ?? false }) {
            return AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
        }
        return pressMenuItem(pid, matching: { t in Self.tabHints.contains { t.contains($0) } })
    }

    private static let tabHints = [windowTitle, "show-fake-env", "sleep"]

    private func tabs(_ pid: pid_t) -> [AXUIElement] {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
        func collect(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXRadioButtonRole { return [element] }
            guard depth < 5 else { return [] }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            return ((children as? [AXUIElement]) ?? []).flatMap { collect($0, depth: depth + 1) }
        }
        return ((windows as? [AXUIElement]) ?? []).flatMap { collect($0, depth: 0) }
    }

    private func title(_ element: AXUIElement) -> String? {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private func windowAndTabTitles(_ pid: pid_t) -> [String] {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
        return ((windows as? [AXUIElement]) ?? []).compactMap { title($0).map { "window \"\($0)\"" } }
            + tabs(pid).compactMap { title($0).map { "tab \"\($0)\"" } }
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var flag: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &flag)
        return (flag as? Bool) == true
    }

    private func describe(_ r: CGRect?) -> String {
        guard let r else { return "n/a" }
        return "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: Actions on the terminal (need Accessibility permission)

    private func scrollUp(_ window: AXUIElement, pid: pid_t) {
        if let (text, _) = textElement(in: window) {
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(text, kAXParentAttribute as CFString, &parent)
            if let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                var bar: CFTypeRef?
                AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXVerticalScrollBarAttribute as CFString, &bar) // swiftlint:disable:this force_cast
                if let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() {
                    var current: CFTypeRef?
                    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, &current) // swiftlint:disable:this force_cast
                    let now = (current as? NSNumber)?.doubleValue ?? 1
                    let result = AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, // swiftlint:disable:this force_cast
                                                              max(0, now - 0.25) as CFNumber)
                    report += "_Scroll bar value \(String(format: "%.2f", now)) → \(String(format: "%.2f", max(0, now - 0.25))): \(result == .success ? "set" : "not settable (\(result.rawValue))")._\n\n"
                    if result == .success { return }
                }
            }
        }
        scroll(pid: pid, window: window, lines: 8) // fallback: scroll-wheel event
    }

    private func scrollBar(_ window: AXUIElement, to position: Double) {
        guard let (text, _) = textElement(in: window) else { return }
        var parent: CFTypeRef?, bar: CFTypeRef?
        AXUIElementCopyAttributeValue(text, kAXParentAttribute as CFString, &parent)
        guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return }
        AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXVerticalScrollBarAttribute as CFString, &bar) // swiftlint:disable:this force_cast
        guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
        AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, position as CFNumber) // swiftlint:disable:this force_cast
    }

    private func pressMenuItem(_ pid: pid_t, titles: [String]) {
        if !pressMenuItem(pid, matching: { titles.contains($0) }) {
            report += "_No menu item named \(titles.joined(separator: " / "))._\n\n"
        }
    }

    @discardableResult
    private func pressMenuItem(_ pid: pid_t, matching: (String) -> Bool) -> Bool {
        var bar: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar)
        guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            if let title = title as? String, matching(title) { return element }
            guard depth < 4 else { return nil }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { if let hit = find(child, depth: depth + 1) { return hit } }
            return nil
        }
        guard let item = find(bar as! AXUIElement, depth: 0) else { return false } // swiftlint:disable:this force_cast
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func scroll(pid: pid_t, window: AXUIElement, lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        if let p: CGPoint = value(window, kAXPositionAttribute, .cgPoint), let s: CGSize = value(window, kAXSizeAttribute, .cgSize) {
            event.location = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        }
        event.postToPid(pid)
    }

    // MARK: Screenshot (includes our own outline overlay, unlike the mirror's capture)

    private func screenshot(_ axRect: CGRect, to url: URL) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        let centre = CGPoint(x: axRect.midX, y: axRect.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(centre) }) else { return false }
        let bounds = CGDisplayBounds(display.displayID) // global, top-left origin like AX
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let local = axRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY).intersection(CGRect(origin: .zero, size: bounds.size))
        config.sourceRect = local
        config.width = Int(local.width * CGFloat(filter.pointPixelScale))
        config.height = Int(local.height * CGFloat(filter.pointPixelScale))
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        guard (try? png.write(to: url)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    // MARK: AX helpers

    private func probeWindow(_ app: AXUIElement) -> AXUIElement? {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        let all = (windows as? [AXUIElement]) ?? []
        let byTitle = all.first { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return (title as? String)?.contains(Self.windowTitle) == true
        }
        // Terminal.app doesn't always show the title the script sets; fall back to the page's last line.
        return byTitle ?? all.first { window in
            guard let (text, _) = textElement(in: window) else { return false }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(text, kAXValueAttribute as CFString, &value)
            return (value as? String)?.contains("window left open for the SecretShield AX probe") == true
        }
    }

    /// Depth-first search for the text area, returning it with its role path.
    private func textElement(in element: AXUIElement, path: [String] = [], depth: Int = 0) -> (AXUIElement, [String])? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let path = path + [(role as? String) ?? "?"]
        if role as? String == kAXTextAreaRole { return (element, path) }
        guard depth < 10 else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let found = textElement(in: child, path: path, depth: depth + 1) { return found }
        }
        return nil
    }

    private func names(_ element: AXUIElement, _ copy: (AXUIElement, UnsafeMutablePointer<CFArray?>) -> AXError) -> [String] {
        var array: CFArray?
        guard copy(element, &array) == .success else { return [] }
        return (array as? [String]) ?? []
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return unpack(raw, type)
    }

    private func parameter(_ element: AXUIElement, _ attribute: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, argument, &raw) == .success else { return nil }
        return raw
    }

    private func parameterValue<T>(_ element: AXUIElement, _ attribute: String, _ range: CFRange, _ type: AXValueType) -> T? {
        unpack(parameter(element, attribute, axValue(range)), type)
    }

    private func parameterValue<T>(_ element: AXUIElement, _ attribute: String, _ number: Int, _ type: AXValueType) -> T? {
        unpack(parameter(element, attribute, number as CFNumber), type)
    }

    private func intParameter(_ element: AXUIElement, _ attribute: String, _ index: Int) -> Int? {
        (parameter(element, attribute, index as CFNumber) as? NSNumber)?.intValue
    }

    private func unpack<T>(_ raw: CFTypeRef?, _ type: AXValueType) -> T? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue // swiftlint:disable:this force_cast (type checked above)
        switch type {
        case .cgPoint: var v = CGPoint.zero; return AXValueGetValue(axValue, type, &v) ? v as? T : nil
        case .cgSize: var v = CGSize.zero; return AXValueGetValue(axValue, type, &v) ? v as? T : nil
        case .cgRect: var v = CGRect.zero; return AXValueGetValue(axValue, type, &v) ? v as? T : nil
        case .cfRange: var v = CFRange(); return AXValueGetValue(axValue, type, &v) ? v as? T : nil
        default: return nil
        }
    }

    private func axValue(_ range: CFRange) -> AXValue {
        var range = range
        return AXValueCreate(.cfRange, &range)!
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) {
        var point = point
        if let v = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, attribute as CFString, v) }
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ size: CGSize) {
        var size = size
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, attribute as CFString, v) }
    }

    /// AX uses global coordinates with the origin at the top-left of the main display; Cocoa uses bottom-left.
    private func cocoaPoint(_ ax: CGPoint) -> CGPoint { CGPoint(x: ax.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - ax.y) }
    private func axPoint(top: CGFloat, left: CGFloat) -> CGPoint { CGPoint(x: left, y: (NSScreen.screens.first?.frame.maxY ?? 0) - top) }

    private func ms(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }

    private func stats(_ times: [Double]) -> String {
        guard !times.isEmpty else { return "n/a" }
        return String(format: "avg %.2f ms, max %.2f ms", times.reduce(0, +) / Double(times.count), times.max()!)
    }
}

/// The fake fixture as it should appear on screen: one entry per .env line and PEM line.
struct Fixture {
    struct Line { let name: String; let text: String }
    let lines: [Line]

    static func load(from folder: URL) throws -> Fixture {
        let env = try String(contentsOf: folder.appending(path: "fake.env"), encoding: .utf8).split(separator: "\n")
        let pem = try String(contentsOf: folder.appending(path: "fake_key.pem"), encoding: .utf8).split(separator: "\n")
        let envLines = env.filter { !$0.hasPrefix("#") }.map { line -> Line in
            let name = String(line.prefix { $0 != "=" })
            return Line(name: name, text: String(line))
        }
        let pemLines = pem.enumerated().map { i, line in
            Line(name: line.hasPrefix("-----") ? "PEM \(line.contains("BEGIN") ? "BEGIN" : "END") line" : "PEM line \(i)",
                 text: String(line))
        }
        return Fixture(lines: envLines + pemLines)
    }

    /// Finds `line` in `text`, also when the terminal put row breaks inside it (soft wraps). Ranges are in `text`.
    static func locate(_ line: String, in text: String) -> (exact: Bool, valueRange: NSRange?, keyRange: NSRange?)? {
        let ns = text as NSString
        var kept: [Int] = [] // index in `text` of each UTF-16 unit kept after dropping row breaks
        var stripped: [unichar] = []
        for i in 0..<ns.length where ns.character(at: i) != 10 && ns.character(at: i) != 13 {
            kept.append(i)
            stripped.append(ns.character(at: i))
        }
        let haystack = NSString(characters: stripped, length: stripped.count)
        let found = haystack.range(of: line)
        guard found.location != NSNotFound else { return nil }
        let start = kept[found.location], end = kept[found.location + found.length - 1] + 1
        let exact = end - start == found.length
        let name = line.prefix { $0 != "=" }
        let isEnv = line.contains("=") && !line.hasPrefix("-----")
        let valueStartInLine = isEnv ? name.utf16.count + 1 : 0
        guard valueStartInLine < found.length else { return (exact, nil, nil) }
        let valueStart = kept[found.location + valueStartInLine]
        let keyRange = isEnv ? NSRange(location: start, length: valueStart - start) : nil
        return (exact, NSRange(location: valueStart, length: end - valueStart), keyRange)
    }
}

/// Transparent, click-through window over all screens that outlines rectangles given in AX (top-left) coordinates.
@MainActor
final class OutlineOverlay: NSWindow {
    private let canvas = OutlineView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = canvas
    }

    func show(_ axRects: [CGRect]) {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        // With "Displays have separate Spaces" a window shows on one display only, so cover just the display
        // the outlines are on (the last rect passed is the terminal's viewport).
        let anchor = axRects.last.map { CGPoint(x: $0.midX, y: mainTop - $0.midY) } ?? .zero
        let all = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.screens.first)?.frame ?? .zero
        setFrame(all, display: false)
        canvas.rects = axRects.map { r in
            CGRect(x: r.minX - all.minX, y: mainTop - r.maxY - all.minY, width: r.width, height: r.height)
        }
        orderFrontRegardless()
    }
}

private final class OutlineView: NSView {
    var rects: [CGRect] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        for r in rects {
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }
}
#endif
