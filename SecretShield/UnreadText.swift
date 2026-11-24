import CoreGraphics
import CoreVideo

/// Fail-closed backstop for OCR: finds pixels that look like text (sharp light/dark edges) but lie outside every
/// line OCR returned. Vision silently skips text now and then (faint or fading text, dense blocks, odd glyphs);
/// whatever it didn't read can't have been checked, so it is blacked out.
enum UnreadText {
    /// Luminance step between neighbouring pixels that counts as a glyph edge.
    static let edgeContrast = 48
    /// Edges a pixel row needs outside OCR'd text to count as unread text (a cursor or a stray pixel is not).
    static let minEdgesPerRow = 4

    /// `areas`: where to look (frame pixels, top-left origin). `lines`: everything OCR read there.
    static func rects(in pixelBuffer: CVPixelBuffer, areas: [CGRect], lines: [TextLine]) -> [CGRect] {
        guard !areas.isEmpty else { return [] }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return areas } // can't look: assume unread
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let read = lines.map { $0.rect.insetBy(dx: -6, dy: -3) }

        var out: [CGRect] = []
        for area in areas {
            let x0 = max(0, Int(area.minX)), x1 = min(width - 1, Int(area.maxX))
            let y0 = max(0, Int(area.minY)), y1 = min(height, Int(area.maxY))
            guard x1 > x0, y1 > y0 else { continue }
            var block: (y0: Int, y1: Int, x0: Int, x1: Int)?
            func flush() {
                if let b = block {
                    out.append(CGRect(x: b.x0, y: b.y0, width: b.x1 - b.x0 + 1, height: b.y1 - b.y0 + 1).insetBy(dx: -4, dy: -4))
                }
                block = nil
            }
            for y in stride(from: y0, to: y1, by: 2) { // every other row: text lines are 10+ px tall
                let covered = read.filter { CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY }
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                func luma(_ x: Int) -> Int { let p = row + x * 4; return (Int(p[2]) * 2 + Int(p[1]) * 5 + Int(p[0])) / 8 } // BGRA
                var edges = 0, lo = Int.max, hi = Int.min
                var previous = luma(x0)
                for x in (x0 + 1)...x1 {
                    let current = luma(x)
                    defer { previous = current }
                    guard abs(current - previous) >= edgeContrast,
                          !covered.contains(where: { CGFloat(x) >= $0.minX && CGFloat(x) < $0.maxX }) else { continue }
                    edges += 1; lo = min(lo, x); hi = max(hi, x)
                }
                if edges >= minEdgesPerRow {
                    if let b = block, y <= b.y1 + 4 { block = (b.y0, y + 1, min(b.x0, lo), max(b.x1, hi)) } else { flush(); block = (y, y + 1, lo, hi) }
                }
            }
            flush()
        }
        return out
    }
}
