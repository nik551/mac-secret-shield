import CoreVideo
import Foundation
import os

struct PipelineStats: Sendable {
    var ocrMs = 0.0
    var redactions = 0
    /// Frames released with every changed band blacked out because the check missed its budget or failed.
    var failClosedFrames = 0
    /// Frames in which at least one AX terminal's area showed the last sanitized pixels instead of new ones.
    var heldFrames = 0
    var heldReasons: [String: Int] = [:]
}

/// Holds each captured frame until it has been checked, then releases it with secrets covered.
///
/// Fail-closed rules:
/// - A frame is released only once OCR + detection finished, or once its budget (measured from capture) ran out,
///   in which case every changed band is blacked out.
/// - While a check runs, a newer frame replaces the waiting one; the mirror keeps showing the last safe frame.
/// - "Changed" is measured against the last frame whose check *completed*, so blacked-out areas get re-checked.
/// - If OCR, the window list or drawing fails, the frame is blacked out or dropped, never shown raw.
///
/// All mutable state is confined to `queue` (a serial queue), hence @unchecked Sendable.
final class DelayBuffer: @unchecked Sendable {
    private let budget: CFTimeInterval
    private let recognizer: any TextRecognizer
    private let detector: SecretDetector
    private let windowSource: any WindowSource
    private let axSource: AXTerminalSource?
    private let redactor: Redactor
    private let onRelease: @Sendable (Frame, PipelineStats) -> Void
    private let queue = DispatchQueue(label: "SecretShield.delay", qos: .userInteractive)
    private let ocrQueue = DispatchQueue(label: "SecretShield.ocr", qos: .userInteractive)

    private var waiting: Frame?
    private var busy = false
    private var changes = ChangeDetector()
    private var checkedRedactions: [CGRect] = []
    private var checkedTerminals: [CGRect] = [] // terminal window frames at the last completed check
    /// Folded text of secrets found this session, so a piece of one is still covered after its context has gone
    /// (e.g. the first row of a wrapped key scrolled away). Memory only: never logged or written anywhere.
    private var remembered: [String] = []
    private var stats = PipelineStats()
    private var lastSafe: Frame?                      // last released (sanitized) frame, for holds
    private var axReference: [String: AXTerminalSource.State] = [:] // per window: state at the reference frame
    private var axWaitScheduled = false

    private final class Job: @unchecked Sendable { var released = false } // touched only on `queue`
    /// Counts and timings only, never screen content. Watch with: log stream --predicate 'subsystem == "SecretShield"'
    private static let log = Logger(subsystem: "SecretShield", category: "pipeline")

    init(budget: CFTimeInterval = 0.3, recognizer: any TextRecognizer, detector: SecretDetector,
         windowSource: any WindowSource, axSource: AXTerminalSource? = nil, redactor: Redactor = Redactor(),
         onRelease: @escaping @Sendable (Frame, PipelineStats) -> Void) {
        self.budget = budget
        self.recognizer = recognizer
        self.detector = detector
        self.windowSource = windowSource
        self.axSource = axSource
        self.redactor = redactor
        self.onRelease = onRelease
    }

    func submit(_ frame: Frame) {
        queue.async {
            self.waiting = frame
            self.startNextIfIdle()
        }
    }

    private func startNextIfIdle() {
        guard !busy, let frame = waiting else { return }
        // AX masks are only trusted for a frame once the terminal state is known to have held around its capture.
        if axSource != nil, Frame.now() < frame.captureTime + AXTerminalSource.settle + 0.008 {
            if !axWaitScheduled {
                axWaitScheduled = true
                queue.asyncAfter(deadline: .now() + (frame.captureTime + AXTerminalSource.settle + 0.008 - Frame.now())) {
                    self.axWaitScheduled = false
                    self.startNextIfIdle()
                }
            }
            return
        }
        waiting = nil
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let bands = changes.changedBands(in: frame.pixelBuffer)

        guard let windows = windowSource.windows(frameSize: size) else {
            // Can't tell which text is in a terminal: black out everything that changed (reference stays as is).
            stats.failClosedFrames += 1
            return release(frame, covering: checkedRedactions.filter { r in !bands.contains { $0.intersects(r) } } + bands)
        }
        let ax = axCheck(frame, windows: windows, bands: bands, size: size)
        if bands.isEmpty { return release(frame, covering: checkedRedactions + ax.masks, holding: ax.holds) }

        let terminals = windows.filter { $0.isTerminal && !ax.handled.contains($0.frame) }.map(\.frame)
        let (regions, carried, areas, newText) = plan(frame, bands: bands, terminals: terminals)
        // Text in a terminal's widened area counts as terminal text even when the window list lags the pixels
        // (dragging); windows in front of it still own their own text. AX-handled terminals are left out of OCR.
        let checkedWindows = windows.filter { !ax.handled.contains($0.frame) }.map { w in
            var widened = w
            widened.reach = areas.first { $0.window == w.frame }?.area
            return widened
        }
        if regions.isEmpty { // only scrolled / non-terminal changes: nothing new to read
            if ax.holds.isEmpty {
                changes.setReference(frame.pixelBuffer)
                axReference.merge(ax.states) { _, new in new }
            }
            checkedTerminals = terminals
            checkedRedactions = carried
            stats.redactions = carried.count + ax.masks.count
            return release(frame, covering: carried + ax.masks, holding: ax.holds)
        }

        let job = Job()
        busy = true
        let remaining = max(0, frame.captureTime + budget - Frame.now())
        queue.asyncAfter(deadline: .now() + remaining) {
            self.failClosed(job, frame, covering: carried + regions + ax.masks, holding: ax.holds)
        }
        let waitedMs = Int((Frame.now() - frame.captureTime) * 1000)
        ocrQueue.async { [recognizer, detector, remembered] in
            let start = Frame.now()
            let detection = try? Self.detect(in: frame, bands: regions, windows: checkedWindows, recognizer: recognizer,
                                             detector: detector, remembered: remembered, mustBeRead: newText)
            let found = detection?.rects
            let ms = (Frame.now() - start) * 1000
            self.queue.async {
                self.busy = false
                Self.log.notice("""
                    check: waited \(waitedMs, privacy: .public) ms, changed \(Int(bands.reduce(0) { $0 + $1.height }), privacy: .public) px, \
                    OCR'd \(Int(regions.reduce(0) { $0 + $1.height }), privacy: .public) px in \(Int(ms), privacy: .public) ms, \
                    \(found?.count ?? -1, privacy: .public) found, late \(job.released, privacy: .public)
                    """)
                if let found {
                    self.remember(detection?.secrets ?? [])
                    if ax.holds.isEmpty {
                        self.changes.setReference(frame.pixelBuffer)
                        self.axReference.merge(ax.states) { _, new in new }
                    }
                    self.checkedTerminals = terminals
                    // Re-read rows find the same secrets again: drop carried blocks a fresh one already covers.
                    self.checkedRedactions = found + carried.filter { c in !found.contains { $0.contains(c.insetBy(dx: 2, dy: 2)) } }
                    self.stats.ocrMs = ms
                    self.stats.redactions = self.checkedRedactions.count
                    if !job.released {
                        job.released = true
                        self.release(frame, covering: self.checkedRedactions + ax.masks, holding: ax.holds)
                    } else if self.waiting == nil {
                        // This frame went out blacked out at its deadline. Nothing newer has arrived (ScreenCaptureKit
                        // sends nothing while the screen is still), so show the now-checked version instead of
                        // leaving the mirror stuck on black.
                        self.release(frame, covering: self.checkedRedactions + ax.masks, holding: ax.holds)
                    }
                } else {
                    self.failClosed(job, frame, covering: carried + regions + ax.masks, holding: ax.holds)
                }
                self.startNextIfIdle()
            }
        }
    }

    /// Decides what to OCR for this frame and which earlier redactions still apply.
    ///
    /// - A terminal window that hasn't moved since the last completed check: rows that only scrolled (pixel-identical
    ///   to a row of the last checked frame across the window's width) keep their redactions, which follow their
    ///   rows; other changed rows are OCR'd with one strip of context above and below, so a key wrapped onto a new
    ///   line is read together with the line before it.
    /// - A terminal window that moved, resized or appeared, or whose content mostly changed without scrolling (the
    ///   window list can lag the pixels by a frame while dragging): OCR all of it, widened by a margin, since its
    ///   text may sit tens of pixels from where the window list says.
    /// Steady terminals are read exactly inside their frame: a wider region lets Vision glue text from the window
    /// behind onto terminal rows, which breaks wrap detection.
    /// - Non-terminal changes need no check (detection only covers terminals).
    private func plan(_ frame: Frame, bands: [CGRect], terminals: [CGRect])
        -> (ocr: [CGRect], carried: [CGRect], areas: [(window: CGRect, area: CGRect)], newText: [CGRect]) {
        let strip = CGFloat(ChangeDetector.stripHeight)
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let isChanged = { (y: Int) in bands.contains { CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY } }
        var regions: [CGRect] = []
        var newText: [CGRect] = [] // rows that changed without just scrolling: all text there must be read
        var areas: [(window: CGRect, area: CGRect)] = [] // window frame → area whose text it owns
        var movedAreas: [CGRect] = []
        var steady: [(area: CGRect, moved: [Int: Int])] = [] // new row → reference row
        func readInFull(_ window: CGRect) {
            let area = window.insetBy(dx: -6 * strip, dy: -6 * strip).intersection(bounds)
            if !area.isNull { areas.append((window, area)); movedAreas.append(area); regions.append(area); newText.append(area) }
        }
        for window in terminals {
            let area = window.intersection(bounds)
            guard checkedTerminals.contains(window), !area.isNull, area.width >= 8 else { readInFull(window); continue }
            let rows = (Int(area.minY)..<Int(area.maxY)).filter(isChanged)
            let matches = changes.matchRows(in: frame.pixelBuffer, columns: area, rows: rows)
            if CGFloat(rows.count - matches.count) > 0.5 * area.height { readInFull(window); continue } // likely moving
            areas.append((window, area))
            steady.append((area, matches))
            var run: ClosedRange<Int>?
            func flush() {
                guard let r = run else { return }
                regions.append(CGRect(x: area.minX, y: CGFloat(r.lowerBound) - strip, width: area.width,
                                      height: CGFloat(r.count) + 2 * strip).intersection(area))
                newText.append(CGRect(x: area.minX, y: CGFloat(r.lowerBound), width: area.width, height: CGFloat(r.count)))
                run = nil
            }
            for y in rows where matches[y] == nil { // group rows that need OCR into runs
                if let r = run, y <= r.upperBound + Int(strip) { run = r.lowerBound...y } else { flush(); run = y...y }
            }
            flush()
        }
        let carried = checkedRedactions.compactMap { r -> CGRect? in
            if movedAreas.contains(where: { $0.intersects(r) }) { return nil } // re-read in full
            let refRows = Int(r.minY)..<Int(ceil(r.maxY))
            let unchanged = refRows.filter { !isChanged($0) }
            // Inside a steady terminal, scrolled rows take their redaction along; elsewhere only unchanged rows keep it.
            let window = steady.first { $0.area.contains(CGPoint(x: r.midX, y: r.midY)) }
            let now = unchanged + (window?.moved.compactMap { refRows.contains($0.value) ? $0.key : nil } ?? [])
            guard let lo = now.min(), let hi = now.max() else { return nil } // scrolled away or overwritten
            return CGRect(x: r.minX, y: CGFloat(lo), width: r.width, height: CGFloat(hi - lo + 1))
        }
        return (Self.mergeOverlapping(regions), carried, areas, newText)
    }

    private func remember(_ secrets: [String]) {
        for secret in secrets where !remembered.contains(secret) { remembered.append(secret) }
        if remembered.count > 500 { remembered.removeFirst(remembered.count - 500) }
    }

    private func failClosed(_ job: Job, _ frame: Frame, covering rects: [CGRect], holding holds: [CGRect] = []) {
        guard !job.released else { return }
        job.released = true
        stats.failClosedFrames += 1
        release(frame, covering: rects, holding: holds)
    }

    private func release(_ frame: Frame, covering rects: [CGRect], holding holds: [CGRect] = []) {
        // can't draw the blocks: drop the frame, the mirror keeps the last safe one
        guard let safe = redactor.redact(frame, covering: rects, holding: holds, from: lastSafe) else { return }
        lastSafe = safe
        if !holds.isEmpty { stats.heldFrames += 1 }
        Self.log.notice("""
            release: delay \(Int((Frame.now() - frame.captureTime) * 1000), privacy: .public) ms, \
            blocks \(rects.count, privacy: .public), held areas \(holds.count, privacy: .public)
            """)
        onRelease(safe, stats)
    }

    // MARK: AX terminals

    static func describe(_ r: CGRect) -> String {
        r.isNull ? "-" : "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    /// For each Terminal/iTerm2 window: its masks if its AX state is verified for this frame, else its visible area
    /// as a hold. `handled` are the windows AX took care of (left out of OCR); a window AX can't read for over a
    /// second falls back to OCR instead.
    private func axCheck(_ frame: Frame, windows: [WindowInfo], bands: [CGRect], size: CGSize)
        -> (masks: [CGRect], holds: [CGRect], handled: [CGRect], states: [String: AXTerminalSource.State]) {
        guard let axSource else { return ([], [], [], [:]) }
        var masks: [CGRect] = [], holds: [CGRect] = [], handled: [CGRect] = []
        var states: [String: AXTerminalSource.State] = [:]
        // Masks and holds are NOT clipped by the windows listed in front: that list can lag the screen after a
        // window comes forward, and clipping by a stale list once left a whole terminal unmasked. Covering a little
        // of the window in front is the safe direction.
        let margin = 2 * CGFloat(ChangeDetector.stripHeight)
        let verdicts = axSource.verdicts(capturedAt: frame.captureTime, frameSize: size)
        for v in verdicts {
            let key = "\(v.id)"
            switch v.verdict {
            case .verified(let state, let windowMasks, let cursors, let rowHeight):
                let box = windowMasks.reduce(CGRect.null) { $0.union($1) }
                Self.log.notice("ax: \(Self.describe(v.frame), privacy: .public) verified, \(windowMasks.count, privacy: .public) masks in \(Self.describe(box), privacy: .public)")
                // Same text state as at the reference frame, yet pixels changed: only the cursor's or the mouse's
                // row may change without re-verification; anything else waits until the screen settles.
                let changed = bands.map { $0.intersection(v.frame) }.filter { !$0.isNull && !$0.isEmpty }
                let rowMargin = rowHeight + 2 * CGFloat(ChangeDetector.stripHeight)
                var allowed = cursors.map { CGRect(x: v.frame.minX, y: $0.minY - rowMargin, width: v.frame.width, height: $0.height + 2 * rowMargin) }
                if let mouse = axSource.mouseInPixels(frameSize: size) {
                    allowed.append(CGRect(x: v.frame.minX, y: mouse.y - rowMargin, width: v.frame.width, height: 2 * rowMargin))
                }
                let explained = changed.allSatisfy { c in allowed.contains { $0.contains(c) } }
                if axReference[key] == state, !explained, waiting != nil {
                    holds.append(v.frame)
                    stats.heldReasons["pixels changed without a text change, screen not settled", default: 0] += 1
                    Self.log.notice("held: pixels changed without a text change, screen not settled")
                } else {
                    masks += windowMasks
                    states[key] = state
                }
            case .unverified(let reason):
                // Hold everywhere the window has been since shortly before capture (it may be moving), plus a margin.
                // Never handed to OCR instead: OCR has never checked these pixels, and unchanged pixels would then
                // go out unchecked. An unreadable terminal stays held (fail closed).
                holds.append(v.history.insetBy(dx: -margin, dy: -margin))
                stats.heldReasons[reason, default: 0] += 1
                Self.log.notice("held: \(reason, privacy: .public) \(Self.describe(v.frame), privacy: .public)")
            }
        }
        // Terminal/iTerm2 windows AX doesn't track yet (just opened): hold them until it does.
        for window in windows where AXTerminalSource.bundleIDs.contains(window.bundleID) {
            handled.append(window.frame) // never OCR'd: AX or nothing
            let tracked = verdicts.contains { v in // same window: edges within 40 px (both lists are read ~10 ms apart)
                abs(v.frame.minX - window.frame.minX) < 40 && abs(v.frame.minY - window.frame.minY) < 40
                    && abs(v.frame.maxX - window.frame.maxX) < 40 && abs(v.frame.maxY - window.frame.maxY) < 40
            }
            guard !tracked else { continue }
            holds.append(window.frame.insetBy(dx: -margin, dy: -margin))
            stats.heldReasons["window not tracked yet", default: 0] += 1
            Self.log.notice("held: window not tracked yet \(Self.describe(window.frame), privacy: .public)")
        }
        return (masks, holds, handled, states)
    }

    // MARK: Detection (pure apart from OCR; static so tests can call it)

    /// OCRs the changed bands inside terminal windows and returns padded rects (frame pixels) to black out.
    static func secretRects(in frame: Frame, bands: [CGRect], windows: [WindowInfo],
                            recognizer: any TextRecognizer, detector: SecretDetector) throws -> [CGRect] {
        try detect(in: frame, bands: bands, windows: windows, recognizer: recognizer, detector: detector,
                   remembered: [], mustBeRead: []).rects
    }

    /// As `secretRects`, also covering any token that is part of a secret found earlier (`remembered`, folded) and any
    /// text-like pixels in `mustBeRead` that OCR didn't return (see UnreadText), and returning the folded text of
    /// every secret found, to remember for later frames.
    static func detect(in frame: Frame, bands: [CGRect], windows: [WindowInfo], recognizer: any TextRecognizer,
                       detector: SecretDetector, remembered: [String],
                       mustBeRead: [CGRect]) throws -> (rects: [CGRect], secrets: [String]) {
        let regions = mergeOverlapping(bands.flatMap { band in
            windows.filter(\.isTerminal).map { $0.ownedArea.intersection(band) }
        }.filter { !$0.isNull && $0.width >= 8 && $0.height >= 8 })
        guard !regions.isEmpty else { return ([], []) }

        // Each line belongs to the topmost window containing its centre; only terminal lines are checked.
        var linesByWindow: [Int: [TextLine]] = [:]
        let lines = try recognizer.recognize(frame, in: regions)
        let unread = UnreadText.rects(in: frame.pixelBuffer, areas: mustBeRead, lines: lines)
        for line in lines {
            let centre = CGPoint(x: line.rect.midX, y: line.rect.midY)
            guard let owner = windows.firstIndex(where: { $0.ownedArea.contains(centre) }), windows[owner].isTerminal else { continue }
            linesByWindow[owner, default: []].append(line)
        }
        let results = linesByWindow.map { owner, lines in
            detect(in: lines, window: windows[owner].frame, detector: detector, remembered: remembered)
        }
        return (results.flatMap(\.rects) + unread, results.flatMap(\.secrets))
    }

    static func secretRects(in lines: [TextLine], window: CGRect, detector: SecretDetector) -> [CGRect] {
        detect(in: lines, window: window, detector: detector, remembered: []).rects
    }

    static func detect(in lines: [TextLine], window: CGRect, detector: SecretDetector,
                       remembered: [String]) -> (rects: [CGRect], secrets: [String]) {
        let ordered = readingOrder(lines)
        let texts = ordered.map(\.text)
        let separators = zip(ordered, ordered.dropFirst()).map { a, b in
            VisionTextRecognizer.sameRow(a.rect, b.rect) ? " " : wraps(a, onto: b, window: window) ? "" : "\n"
        }
        let found = detector.findSecrets(in: texts, separators: separators)
        let secrets = found.compactMap { f -> String? in
            f.range.length >= 8 ? SecretDetector.fold((texts[f.line] as NSString).substring(with: f.range)) : nil
        }
        let rects = (found + SecretDetector.findRemembered(remembered, in: texts)).map { finding in
            let line = ordered[finding.line]
            let cw = line.rect.width / CGFloat(max(1, line.text.utf16.count)) // monospace: equal-width characters
            let x0 = line.rect.minX + CGFloat(finding.range.location) * cw
            let x1 = line.rect.minX + CGFloat(finding.range.location + finding.range.length) * cw
            return CGRect(x: x0, y: line.rect.minY, width: x1 - x0, height: line.rect.height)
                .insetBy(dx: -(4 + cw / 2), dy: -4)
        }
        return (rects, secrets)
    }

    /// Rows top to bottom, boxes within a row left to right.
    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if let last = rows.last?.first, VisionTextRecognizer.sameRow(last.rect, line.rect) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// A terminal soft-wraps a line when it reaches the right edge; the rest continues at the left of the next row.
    static func wraps(_ a: TextLine, onto b: TextLine, window: CGRect) -> Bool {
        let cw = a.rect.width / CGFloat(max(1, a.text.count))
        return !a.text.hasSuffix(" ")
            && window.maxX - a.rect.maxX < 6 * cw
            && b.rect.minY - a.rect.maxY < a.rect.height
            && b.rect.minX <= a.rect.minX + 2 * cw
    }

    static func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects {
            var merged = r
            while let i = out.firstIndex(where: { $0.intersects(merged) }) { merged = merged.union(out.remove(at: i)) }
            out.append(merged)
        }
        return out
    }
}
