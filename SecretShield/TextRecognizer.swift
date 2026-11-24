import CoreVideo
import os
import Vision

/// One OCR'd line. `rect` is in frame pixels, origin top-left.
struct TextLine: Sendable, Equatable {
    var text: String
    var rect: CGRect
}

protocol TextRecognizer: Sendable {
    /// OCRs only `regions` (frame pixels, top-left origin). Throws instead of returning a partial result.
    func recognize(_ frame: Frame, in regions: [CGRect]) throws -> [TextLine]
}

/// Vision OCR (`.accurate`, no language correction since keys aren't words) in overlapping tiles run in parallel.
///
/// Why tiles: in testing, Vision's accurate mode silently drops text in large regions. 12 px Menlo text in a
/// 1750+ px wide region returned zero lines, and a 1060 x 1080 region skipped whole long lines that 900 x 1080
/// and 1060 x 600 regions read fine. A dropped line is a leak, so regions are cut into tiles at most 900 px wide.
/// (Smaller tiles cost more: each Vision request has a ~100 ms floor and parallelism doesn't scale far.)
/// A row of text crossing a vertical seam is read by both neighbouring tiles; the two readings are aligned on
/// the characters both saw and joined in the middle of the overlap, away from the glyphs cut by tile edges.
struct VisionTextRecognizer: TextRecognizer {
    static let maxTileWidth: CGFloat = 900
    static let maxTileHeight: CGFloat = 1100 // a 1080p screen is one row of tiles
    static let tileOverlap: CGFloat = 200  // horizontal: ~25 characters at 1x, enough to align two readings
    static let rowOverlap: CGFloat = 64    // vertical: taller than a text line, so every line is whole in some tile

    /// One horizontal strip of tiles. A line belongs to the strip whose `owns` range holds its vertical centre.
    struct TileRow: Equatable {
        let tiles: [CGRect]
        let owns: Range<CGFloat>
    }

    func recognize(_ frame: Frame, in regions: [CGRect]) throws -> [TextLine] {
        let rows = regions.flatMap(Self.tileRows(for:))
        let jobs = rows.flatMap(\.tiles)
        let collected = OSAllocatedUnfairLock(initialState: [Result<[TextLine], any Error>](repeating: .success([]), count: jobs.count))
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let result = Result { try Self.ocr(frame.pixelBuffer, jobs[i]) }
            collected.withLock { $0[i] = result }
        }
        let results = collected.withLock { $0 }
        var lines: [TextLine] = []
        var next = 0
        for row in rows {
            var merged: [TextLine] = []
            for _ in row.tiles { // left to right
                for line in try results[next].get() {
                    if let i = merged.lastIndex(where: { Self.sameRow($0.rect, line.rect) && $0.rect.maxX > line.rect.minX && line.rect.maxX > $0.rect.minX }) {
                        merged[i] = Self.merge(merged[i], line)
                    } else {
                        merged.append(line)
                    }
                }
                next += 1
            }
            lines += merged.filter { row.owns.contains($0.rect.midY) }
        }
        return lines
    }

    static func tileRows(for region: CGRect) -> [TileRow] {
        let columns = spans(from: region.minX, length: region.width, max: maxTileWidth, overlap: tileOverlap)
        return spans(from: region.minY, length: region.height, max: maxTileHeight, overlap: rowOverlap).map { y in
            TileRow(tiles: columns.map { x in
                        CGRect(x: x.span.lowerBound, y: y.span.lowerBound, width: x.span.upperBound - x.span.lowerBound,
                               height: y.span.upperBound - y.span.lowerBound)
                    },
                    owns: y.owns)
        }
    }

    /// Equal spans of at most `max`, neighbours overlapping by exactly `overlap`; each owns up to the middle of
    /// its overlaps (the outer ends own everything beyond, so edge text is never dropped).
    static func spans(from start: CGFloat, length: CGFloat, max: CGFloat, overlap: CGFloat)
        -> [(span: ClosedRange<CGFloat>, owns: Range<CGFloat>)] {
        let n = length <= max ? 1 : Int(((length - overlap) / (max - overlap)).rounded(.up))
        let size = (length + CGFloat(n - 1) * overlap) / CGFloat(n)
        return (0..<n).map { i in
            let lo = start + CGFloat(i) * (size - overlap)
            let ownLo: CGFloat = i == 0 ? -1e9 : lo + overlap / 2
            let ownHi: CGFloat = i == n - 1 ? 1e9 : lo + size - overlap / 2
            return (lo...(lo + size), ownLo..<ownHi)
        }
    }

    /// Joins two readings of the same row from neighbouring tiles. Terminals use monospace fonts, so character
    /// i of a reading sits at minX + i * (width / count); the right reading is aligned on the shared characters
    /// (OCR boxes are a few pixels off) and the join is made mid-overlap, dropping glyphs cut by tile edges.
    static func merge(_ a: TextLine, _ b: TextLine) -> TextLine {
        let (left, right) = a.rect.minX <= b.rect.minX ? (a, b) : (b, a)
        let l = Array(left.text), r = Array(right.text)
        guard !l.isEmpty, !r.isEmpty else { return l.isEmpty ? right : left }
        if right.rect.maxX <= left.rect.maxX { return left } // already contains the other reading
        let cw = left.rect.width / CGFloat(l.count)
        let start = Int(((right.rect.minX - left.rect.minX) / cw).rounded()) // index in `l` where `r` begins
        let shared = max(0, l.count - start)
        func matches(_ shift: Int) -> Int {
            (0..<shared).filter { j in
                let i = start + shift + j
                return i >= 0 && i < l.count && j < r.count && l[i] == r[j]
            }.count
        }
        let shift = [0, -1, 1, -2, 2, -3, 3].reduce(0) { matches($1) > matches($0) ? $1 : $0 }
        let cut = min(shared / 2, r.count)
        let leftEnd = min(l.count, max(0, start + shift + cut))
        return TextLine(text: String(l[..<leftEnd] + r[cut...]), rect: left.rect.union(right.rect))
    }

    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 * min(a.height, b.height)
    }

    private static func ocr(_ pixelBuffer: CVPixelBuffer, _ region: CGRect) throws -> [TextLine] {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        // Vision uses normalised coordinates with the origin at the bottom-left.
        let roi = CGRect(x: region.minX / w, y: (h - region.maxY) / h, width: region.width / w, height: region.height / h)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"] // otherwise Vision sometimes returns Cyrillic look-alikes (Х for X)
        request.regionOfInterest = roi
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = VNImageRectForNormalizedRectUsingRegionOfInterest(observation.boundingBox, Int(w), Int(h), roi)
            return TextLine(text: text, rect: CGRect(x: box.minX, y: h - box.maxY, width: box.width, height: box.height))
        }
    }
}
