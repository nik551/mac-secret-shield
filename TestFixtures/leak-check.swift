// OCRs the viewer frames saved by SecretShield's debug "Save viewer frames" toggle and reports any seeded FAKE
// secret from this folder (fake.env, fake_key.pem) that is readable in them. Readable = a leak.
//
// Usage:  swift TestFixtures/leak-check.swift [frames-folder]
//         (default: newest run in ~/Library/Caches/SecretShield/ViewerFrames)
// Exit code 0 = no leaks, 1 = leaks found, 2 = usage / setup problem.
// Prints secret names and frame file names only, never values.

import Foundation
import ImageIO
import Vision

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if !FileManager.default.fileExists(atPath: fixtures.appending(path: "fake.env").path) {
    let generate = Process()
    generate.executableURL = fixtures.appending(path: "make-fixtures.sh")
    try? generate.run()
    generate.waitUntilExit()
}

// MARK: Seeded secrets

/// Lowercase, drop whitespace, and fold OCR look-alikes so "O0", "l1I|" and "S5" compare equal.
func fold(_ s: String) -> String {
    String(s.lowercased().compactMap { c -> Character? in
        if c.isWhitespace { return nil }
        switch c {
        case "o": return "0"
        case "l", "i", "|": return "1"
        case "s": return "5"
        case "—", "–": return "-"
        default: return c
        }
    })
}

var secrets: [(name: String, value: String)] = []
for line in (try? String(contentsOf: fixtures.appending(path: "fake.env"), encoding: .utf8))?.split(separator: "\n") ?? [] {
    guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
    var value = String(line[line.index(after: eq)...])
    if value.contains("://"), let at = value.lastIndex(of: "@"), let colon = value[..<at].lastIndex(of: ":") {
        value = String(value[value.index(after: colon)..<at]) // only the password part of a URL is secret
    }
    secrets.append((String(line[..<eq]), value))
}
for (i, line) in ((try? String(contentsOf: fixtures.appending(path: "fake_key.pem"), encoding: .utf8))?
    .split(separator: "\n") ?? []).enumerated() where !line.hasPrefix("-----") {
    secrets.append(("PRIVATE KEY line \(i)", String(line)))
}
guard !secrets.isEmpty else { print("No seeded secrets found next to this script."); exit(2) }

/// 10-character windows of the secret, skipping a service prefix like "sk-proj-" that may legitimately be visible.
func fragments(_ value: String) -> [String] {
    let head = value.prefix(16)
    let skip = head.lastIndex(where: { $0 == "-" || $0 == "_" }).map { head.distance(from: head.startIndex, to: $0) + 1 } ?? 0
    let core = Array(fold(String(value.dropFirst(skip))))
    guard core.count > 10 else { return [String(core)] }
    return (0...(core.count - 10)).map { String(core[$0..<$0 + 10]) }
}
let fragmentsBySecret = secrets.map { ($0.name, fragments($0.value)) }

// MARK: Frames

let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SecretShield/ViewerFrames")
let folder: URL
if CommandLine.arguments.count > 1 {
    folder = URL(fileURLWithPath: CommandLine.arguments[1])
} else if let newest = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter({ $0.hasDirectoryPath }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    folder = newest
} else {
    print("No frames folder given and none found in \(root.path)."); exit(2)
}
let allFrames = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !allFrames.isEmpty else { print("No PNG frames in \(folder.path)."); exit(2) }

// Consecutive identical frames add nothing; check each distinct frame once.
var frames: [URL] = []
var previous: Data?
for url in allFrames {
    let data = try? Data(contentsOf: url)
    if data != previous { frames.append(url) }
    previous = data
}

/// Vision drops small text in wide regions, so OCR in overlapping 1000 px wide tiles (as the app does).
/// The 300 px overlap is wider than any 10-character fragment, so a fragment is never only split across tiles.
func ocr(_ url: URL) -> (text: String, ms: Double) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return ("", 0) }
    let width = CGFloat(image.width), tile: CGFloat = 1000, overlap: CGFloat = 300
    var x: CGFloat = 0, text = ""
    let start = Date()
    repeat {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: x / width, y: 0, width: min(tile, width - x) / width, height: 1)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        text += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") + "\n"
        x += tile - overlap
    } while x + overlap < width
    return (text, Date().timeIntervalSince(start) * 1000)
}

let lock = NSLock()
var leaks: [(frame: String, secret: String)] = []
var blankFrames = 0
var totalMs = 0.0
DispatchQueue.concurrentPerform(iterations: frames.count) { i in
    let (text, ms) = ocr(frames[i])
    let folded = fold(text)
    let found = fragmentsBySecret.filter { _, frags in frags.contains { folded.contains($0) } }.map(\.0)
    lock.lock()
    totalMs += ms
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blankFrames += 1 }
    leaks += found.map { (frames[i].lastPathComponent, $0) }
    lock.unlock()
}

print("Checked \(frames.count) distinct frames (\(allFrames.count) saved) in \(folder.path)")
print(String(format: "Average OCR per frame: %.0f ms", totalMs / Double(frames.count)))
if blankFrames > 0 { print("Warning: OCR found no text at all in \(blankFrames) frame(s).") }
if leaks.isEmpty {
    print("No seeded secrets readable. ✅")
    exit(0)
}
for leak in leaks.sorted(by: { $0.frame < $1.frame }) { print("LEAK \(leak.frame): \(leak.secret)") }
print("\(leaks.count) leak(s) in \(Set(leaks.map(\.frame)).count) frame(s). ❌")
exit(1)
