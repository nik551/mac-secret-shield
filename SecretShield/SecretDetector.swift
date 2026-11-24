import Foundation

/// Finds secrets in OCR'd text. Pure logic: no UI, no Vision, no I/O beyond loading the bundled patterns.
/// Scoring follows CLAUDE.md: service pattern +score from JSON, keyword on the left of a value +50,
/// random-looking value +40, allowlisted value = 0. Redact at >= 60.
struct SecretDetector: Sendable {
    struct Pattern: Decodable, Sendable {
        let id: String
        let name: String
        /// If the regex has a capture group, only group 1 is redacted (e.g. just the password in a DB URL).
        let regex: String
        let score: Int
    }

    /// A span to redact, as a UTF-16 range inside one input line.
    struct Finding: Equatable, Sendable {
        let line: Int
        let range: NSRange
    }

    static let threshold = 60
    static let keywordScore = 50
    static let randomnessScore = 40
    static let allowlist = ["****", "xxxx", "your-api-key-here", "changeme", "example"]
    /// Characters OCR mixes up. A literal in a pattern's prefix matches any member of its group.
    /// "T" is there because Vision read Menlo's "AKIA" as "AKTA" in testing.
    static let lookAlikes = ["0Oo", "1lI|T", "5S", "-—–"]

    // KEY=value, KEY: value, --key value, "key": "value", Authorization: Bearer value. Group 1 is the value.
    private static let keyValue = try! NSRegularExpression(pattern: #"""
        (?i)[A-Za-z0-9_.\-]*(?:KEY|SECRET|TOKEN|PASSWORD|PASS|PWD|AUTH|CREDENTIAL|PRIVATE)[A-Za-z0-9_.\-]*["']?[ \t]*(?:[:=][ \t]*|[ \t]+)["']?(?:(?:Bearer|Basic|Token)[ \t]+)?([^\s"',;&]+)
        """#)

    private let patterns: [(regex: NSRegularExpression, score: Int)]

    init(patterns: [Pattern]) throws {
        self.patterns = try patterns.map { (try NSRegularExpression(pattern: Self.tolerantPrefix($0.regex)), $0.score) }
    }

    /// Loads `SecretPatterns.json` from the app bundle. Throws rather than running without patterns.
    static func bundled() throws -> SecretDetector {
        guard let url = Bundle.main.url(forResource: "SecretPatterns", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "SecretPatterns.json is missing."])
        }
        return try SecretDetector(patterns: JSONDecoder().decode([Pattern].self, from: Data(contentsOf: url)))
    }

    /// `separators[i]` joins line i and i+1: "\n" (default) for separate lines, "" when line i soft-wraps
    /// onto line i+1 mid-token, " " for two OCR boxes on the same row.
    func findSecrets(in lines: [String], separators: [String]? = nil) -> [Finding] {
        var text = ""
        var starts: [Int] = []
        for (i, line) in lines.enumerated() {
            if i > 0 { text += separators?[i - 1] ?? "\n" }
            starts.append(text.utf16.count)
            text += line
        }
        return secretRanges(in: text).flatMap { span in
            lines.indices.compactMap { i -> Finding? in
                let lineRange = NSRange(location: starts[i], length: lines[i].utf16.count)
                guard let hit = span.intersection(lineRange), hit.length > 0 else { return nil }
                return Finding(line: i, range: NSRange(location: hit.location - starts[i], length: hit.length))
            }
        }
    }

    /// Vision returns Cyrillic/Greek look-alikes inside Latin text even with `recognitionLanguages = ["en-US"]`
    /// (e.g. Cyrillic "а" in a base64 line), which breaks `[A-Za-z0-9]` classes. Each maps to one Latin UTF-16
    /// unit, so ranges in the normalised text are valid in the original.
    static let homoglyphs: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "ѕ": "s", "і": "i", "ј": "j", "к": "k",
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X",
        "Ѕ": "S", "І": "I", "Ј": "J", "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M",
        "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X", "ο": "o", "ν": "v", "г": "r", "п": "n", "т": "t", "З": "3", "б": "6",
    ]

    func secretRanges(in original: String) -> [NSRange] {
        let text = Self.glueSpuriousSpaces(String(original.map { Self.homoglyphs[$0] ?? $0 }))
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var spans: [(range: NSRange, score: Int)] = []
        for pattern in patterns {
            for match in pattern.regex.matches(in: text, range: all) {
                let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                let hasGroup = match.numberOfRanges > 1 && group.location != NSNotFound
                spans.append((hasGroup ? group : Self.toEndOfToken(match.range, in: ns), pattern.score))
            }
        }
        for match in Self.longLine.matches(in: text, range: all) where Self.isKeyMaterial(ns.substring(with: match.range(at: 1))) {
            spans.append((match.range(at: 1), Self.threshold))
        }
        for match in Self.keyValue.matches(in: text, range: all) {
            let value = match.range(at: 1)
            let random = Self.looksRandom(ns.substring(with: value))
            spans.append((value, Self.keywordScore + (random ? Self.randomnessScore : 0)))
        }
        return spans
            .filter { $0.score >= Self.threshold && !Self.isAllowlisted(ns.substring(with: $0.range)) }
            .map(\.range)
    }

    /// Vision sometimes splits a long random string with a space ("eyJzdWIiOiIx MjM0NTY3"), which would leave the
    /// part after the space unmatched. A single space between two tokens that both mix letters and digits (key
    /// material, not prose) becomes "_", which every key pattern accepts. Same length, so ranges stay valid.
    static func glueSpuriousSpaces(_ text: String) -> String {
        var chars = Array(text)
        func token(around i: Int, step: Int) -> String {
            var j = i, out = ""
            while j >= 0, j < chars.count, !chars[j].isWhitespace { out.append(chars[j]); j += step }
            return out
        }
        func keyLike(_ t: String) -> Bool { t.count >= 4 && t.contains(where: \.isNumber) && t.contains(where: \.isLetter) }
        for i in chars.indices.dropFirst().dropLast() where chars[i] == " " && !chars[i - 1].isWhitespace && !chars[i + 1].isWhitespace {
            if keyLike(token(around: i - 1, step: -1)), keyLike(token(around: i + 1, step: 1)) { chars[i] = "_" }
        }
        return String(chars)
    }

    /// A key doesn't end mid-token: if OCR misread a character ("Us®/0"), the pattern stops early, so cover the rest
    /// of the token too.
    static func toEndOfToken(_ span: NSRange, in text: NSString) -> NSRange {
        var end = span.location + span.length
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar), !"\"',;".unicodeScalars.contains(scalar) {
            end += 1
        }
        return NSRange(location: span.location, length: end - span.location)
    }

    /// A whole line (group 1, without surrounding spaces). Checked by `isKeyMaterial`.
    private static let longLine = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(\S[^\n]{30,}\S)[ \t]*$"#)

    /// A whole line of base64-like random characters is key material (e.g. a private key body whose BEGIN line has
    /// scrolled away). Tolerates a few OCR junk characters ("®", stray Cyrillic) that would break a strict regex.
    static func isKeyMaterial(_ line: String) -> Bool {
        // OCR sometimes splits one token with a space ("...uM LM"): short extra pieces that look like base64
        // fragments (uppercase, digit, + or /) are joined; anything word-like ("done", "key:") means prose.
        let tokens = line.split(whereSeparator: \.isWhitespace)
        let longest = tokens.max { $0.count < $1.count } ?? ""
        let fragmentLike = tokens.allSatisfy { t in
            t == longest || (t.count <= 4 && t.allSatisfy { $0.isLetter || $0.isNumber || "+/".contains($0) }
                             && t.contains { $0.isUppercase || $0.isNumber || "+/".contains($0) })
        }
        guard tokens.count <= 3, fragmentLike else { return false }
        let token = tokens.joined()
        guard token.count >= 32 else { return false }
        let body = token.hasSuffix("==") ? token.dropLast(2) : token.hasSuffix("=") ? token.dropLast() : Substring(token)
        guard !body.contains("://"), !body.contains("=") else { return false } // URLs and KEY=value lines are handled above
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/_-")
        let valid = body.unicodeScalars.filter { base64.contains($0) }.count
        return Double(valid) >= 0.9 * Double(body.unicodeScalars.count) && entropy(token) > 4.5
    }

    /// Lowercased, with OCR look-alikes and homoglyphs folded to one character each (same length as the input), so
    /// two OCR readings of the same secret compare equal.
    static func fold(_ s: String) -> String {
        String(s.map { c -> Character in
            let c = homoglyphs[c] ?? c
            if let group = lookAlikes.first(where: { $0.contains(c) }) { return group.first! }
            return Character(c.lowercased())
        })
    }

    /// Tokens of `lines` that are part of (or contain) a remembered secret. Tokens shorter than 8 characters count
    /// only if they contain a digit, so ordinary words don't match by chance.
    static func findRemembered(_ remembered: [String], in lines: [String]) -> [Finding] {
        guard !remembered.isEmpty else { return [] }
        let token = try! NSRegularExpression(pattern: #"\S{6,}"#)
        return lines.enumerated().flatMap { i, line in
            token.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).compactMap { m -> Finding? in
                let text = (line as NSString).substring(with: m.range)
                guard text.count >= 8 || text.contains(where: \.isNumber) else { return nil }
                let folded = fold(text)
                return remembered.contains { $0.contains(folded) || folded.contains($0) } ? Finding(line: i, range: m.range) : nil
            }
        }
    }

    static func isAllowlisted(_ value: String) -> Bool {
        let lower = value.lowercased()
        return allowlist.contains { lower.contains($0) }
    }

    /// >= 20 chars, no spaces, Shannon entropy > 4.0 bits/char. Hex (commit hashes, UUIDs) tops out at 4.0.
    static func looksRandom(_ value: String) -> Bool {
        value.count >= 20 && !value.contains(where: \.isWhitespace) && entropy(value) > 4.0
    }

    static func entropy(_ s: String) -> Double {
        let counts = Dictionary(s.map { ($0, 1) }, uniquingKeysWith: +)
        let n = Double(s.count)
        return counts.values.reduce(0) { sum, c in
            let p = Double(c) / n
            return sum - p * log2(p)
        }
    }

    /// Rewrites the literal prefix of a regex so OCR look-alikes match: `\bAKIA[...]` → `\bAK[1lI|T]A[...]`.
    static func tolerantPrefix(_ regex: String) -> String {
        var rest = Substring(regex)
        var out = ""
        if rest.hasPrefix(#"\b"#) { out = #"\b"#; rest = rest.dropFirst(2) }
        var prefix = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        rest = rest.dropFirst(prefix.count)
        if let next = rest.first, "?*+{".contains(next), let last = prefix.last { // last literal is quantified
            rest = Substring(String(last)) + rest
            prefix = prefix.dropLast()
        }
        for c in prefix {
            if let group = lookAlikes.first(where: { $0.contains(c) }) { out += "[\(group)]" } else { out.append(c) }
        }
        return out + rest
    }
}
