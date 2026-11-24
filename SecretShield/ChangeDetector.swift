import CoreGraphics
import CoreVideo

/// Finds which horizontal strips of a frame differ from the last frame whose check completed.
/// Strips are full width because terminal text runs in full-width lines.
struct ChangeDetector {
    static let stripHeight = 32
    private var reference: [UInt8] = []
    private var width = 0
    private var height = 0

    /// Changed bands in frame pixels (top-left origin), widened by one strip above and below so a text line
    /// cut by a strip edge is OCR'd whole. With no reference yet (or a size change) the whole frame is changed.
    func changedBands(in pixelBuffer: CVPixelBuffer) -> [CGRect] {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        guard w == width, h == height, !reference.isEmpty else { return [CGRect(x: 0, y: 0, width: w, height: h)] }
        let strip = Self.stripHeight, strips = (h + strip - 1) / strip, rowBytes = w * 4
        var changed = [Bool](repeating: false, count: strips)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [CGRect(x: 0, y: 0, width: w, height: h)] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        reference.withUnsafeBytes { ref in
            for s in 0..<strips {
                for y in s * strip ..< min(h, (s + 1) * strip)
                where memcmp(base + y * bytesPerRow, ref.baseAddress! + y * rowBytes, rowBytes) != 0 {
                    changed[s] = true
                    break
                }
            }
        }

        var bands: [CGRect] = []
        for s in 0..<strips where changed[s] {
            let top = max(0, s - 1) * strip, bottom = min(h, (s + 2) * strip)
            if let last = bands.last, CGFloat(top) <= last.maxY {
                bands[bands.count - 1] = CGRect(x: 0, y: last.minY, width: CGFloat(w), height: CGFloat(bottom) - last.minY)
            } else {
                bands.append(CGRect(x: 0, y: top, width: w, height: bottom - top))
            }
        }
        return bands
    }

    /// Remembers this frame's pixels as the checked state to compare later frames against.
    mutating func setReference(_ pixelBuffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = width * 4
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { reference = []; return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        reference = [UInt8](repeating: 0, count: rowBytes * height)
        reference.withUnsafeMutableBytes { ref in
            for y in 0..<height { memcpy(ref.baseAddress! + y * rowBytes, base + y * bytesPerRow, rowBytes) }
        }
    }

    /// For each of `rows` in `pixelBuffer`, a row of the reference frame with identical pixels across `columns`
    /// (a terminal window's x-range), if there is one: text that only moved since the last checked frame.
    /// When a row matches several reference rows (blank lines), the one at the most common scroll offset wins.
    func matchRows(in pixelBuffer: CVPixelBuffer, columns: CGRect, rows: [Int]) -> [Int: Int] {
        guard CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height,
              !reference.isEmpty, !rows.isEmpty else { return [:] }
        let x0 = max(0, Int(columns.minX)), x1 = min(width, Int(columns.maxX))
        guard x1 > x0 else { return [:] }
        let rowBytes = width * 4, count = (x1 - x0) * 4
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [:] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        func hash(_ p: UnsafeRawPointer) -> Int {
            var h = Hasher()
            h.combine(bytes: UnsafeRawBufferPointer(start: p, count: count))
            return h.finalize()
        }

        return reference.withUnsafeBytes { (ref: UnsafeRawBufferPointer) -> [Int: Int] in
            func refRow(_ y: Int) -> UnsafeRawPointer { ref.baseAddress! + (y * rowBytes + x0 * 4) }
            func newRow(_ y: Int) -> UnsafeRawPointer { UnsafeRawPointer(base) + (y * bytesPerRow + x0 * 4) }
            var refByHash: [Int: [Int]] = [:]
            for y in 0..<height { refByHash[hash(refRow(y)), default: []].append(y) }
            let candidates: [(y: Int, refs: [Int])] = rows.map { ($0, refByHash[hash(newRow($0))] ?? []) }
            // The scroll offset most rows with a single match agree on.
            var votes: [Int: Int] = [:]
            for c in candidates where c.refs.count == 1 { votes[c.refs[0] - c.y, default: 0] += 1 }
            let offset = votes.max { $0.value < $1.value }?.key ?? 0
            var matches: [Int: Int] = [:]
            for c in candidates {
                let target = c.y + offset
                guard let best = c.refs.min(by: { abs($0 - target) < abs($1 - target) }),
                      memcmp(newRow(c.y), refRow(best), count) == 0 else { continue } // hash collision: treat as new
                matches[c.y] = best
            }
            return matches
        }
    }
}
