import XCTest
@testable import SecretShield

/// All keys below are FAKE: random-looking filler in real formats.
final class SecretDetectorTests: XCTestCase {
    let detector = try! SecretDetector.bundled()
    static let filler = "Q7vB2mXk9LpR4tYw8ZcN3hJd6FgT1aEuWq5rVn0sKx8bMz2yHc4jPf7gDl9eAo3iUt6"

    static func fake(_ n: Int) -> String { String(filler.prefix(n)) }

    /// The substrings of a single line that would be covered.
    func redacted(_ line: String) -> [String] {
        detector.findSecrets(in: [line]).map { (line as NSString).substring(with: $0.range) }
    }

    func assertRedactsExactly(_ secret: String, in line: String, file: StaticString = #filePath, line number: UInt = #line) {
        let hits = redacted(line)
        XCTAssertFalse(hits.isEmpty, "not redacted: \(line)", file: file, line: number)
        XCTAssertTrue(hits.allSatisfy { $0 == secret }, "redacted \(hits) in \(line)", file: file, line: number)
    }

    // MARK: True positives

    func testEveryServicePattern() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.\(Self.fake(30))"
        let keys = [
            "sk-\(Self.fake(48))",
            "sk-proj-\(Self.fake(48))",
            "sk-ant-api03-\(Self.fake(60))",
            "AKIA\(Self.fake(16).uppercased())",
            "ghp_\(Self.fake(36))",
            "github_pat_\(Self.fake(22))_\(Self.fake(40))",
            "sk_live_\(Self.fake(30))",
            "rk_live_\(Self.fake(30))",
            "xoxb-123456789012-1234567890123-\(Self.fake(24))",
            "AIza\(Self.fake(35))",
            jwt,
            "eyJhbGciOiJIUzI1NiJ9eyJzdWIiOiIxMjM0NTY3ODkwIn0", // OCR lost the dots
            "rzp_live_\(Self.fake(14))",
        ]
        for key in keys {
            assertRedactsExactly(key, in: "found \(key) in logs") // no keyword: the pattern alone must catch it
        }
    }

    func testPrivateKeyBlockCoversEveryLine() {
        let lines = ["-----BEGIN RSA PRIVATE KEY-----", "MIIEow\(Self.fake(58))", "\(Self.fake(64))", "-----END RSA PRIVATE KEY-----"]
        XCTAssertEqual(Set(detector.findSecrets(in: lines).map(\.line)), [0, 1, 2, 3])
    }

    func testPrivateKeyBodyWithoutHeaderIsCovered() { // BEGIN line scrolled out of view
        let body = "MIIEow" + Self.fake(58)
        assertRedactsExactly(body, in: body)
        for ocrd in ["1ccJo/0lY054704itdYA3v6u3ij+vDGuQnkSaivxksUsD7SqzkSks6аZW3+4Ndx3", // Cyrillic "а", as Vision returned it
                     "xe0srNdVVFeFLHoGpxZcsPGSreDxYfJqBJnY/WNlk+Eauvihz/gN4rAfnZqUs®/0",  // and "®"
                     "gpLTTR09JVCM1KNogXI0f9Gwn4J3F7E2VaQhC/Cn5NY8kwbtM8my5BNeRqsyuM LM"] { // and a stray space
            assertRedactsExactly(ocrd, in: ocrd)
        }
        XCTAssertEqual(redacted("xeosmavvrerlnoopxzesrosreuxttsgbomwwckfcduwsnzgnrarzqusob"), []) // garbled lowercase, low entropy
    }

    func testMisreadCharacterDoesNotEndTheKeyEarly() {
        let key = "sk-proj-\(Self.fake(20))®\(Self.fake(20))"
        assertRedactsExactly(key, in: "found \(key) here")
    }

    func testSpuriousOCRSpaceInsideAKeyDoesNotSplitIt() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIx MjM0NTY3ODkwIn0.\(Self.fake(30))"
        assertRedactsExactly(jwt, in: jwt)
        let line = "export SESSION_SECRET=\(Self.fake(20)) \(Self.fake(28))"
        XCTAssertEqual(redacted(line).map(\.count).max(), 49) // both halves, plus the space
        XCTAssertEqual(SecretDetector.glueSpuriousSpaces("git checkout -b feature/login-page v2"), "git checkout -b feature/login-page v2")
    }

    func testDatabaseURLRedactsOnlyThePassword() {
        assertRedactsExactly("S3cretPassw0rdQx7", in: "DATABASE_URL=postgres://app:S3cretPassw0rdQx7@db.internal:5432/app")
    }

    func testKeyValueRedactsOnlyTheValue() {
        let value = Self.fake(32)
        let line = "export API_KEY=\(value)"
        let findings = detector.findSecrets(in: [line])
        XCTAssertFalse(findings.isEmpty)
        for f in findings { XCTAssertEqual(f.range, NSRange(location: 15, length: value.utf16.count)) } // "API_KEY=" stays
    }

    func testKeyValueVariants() {
        let value = Self.fake(30)
        for line in ["DB_PASSWORD: \(value)", "\"client_secret\": \"\(value)\"", "--auth-token \(value)",
                     "Authorization: Bearer \(value)", "https://api.test/v1?api_key=\(value)&x=1"] {
            assertRedactsExactly(value, in: line)
        }
    }

    func testLookAlikesInPrefixes() {
        assertRedactsExactly("AKlA\(Self.fake(16).uppercased())", in: "id AKlA\(Self.fake(16).uppercased())")
        assertRedactsExactly("A1za\(Self.fake(35))", in: "key A1za\(Self.fake(35))")
        assertRedactsExactly("x0xb-1234-\(Self.fake(24))", in: "x0xb-1234-\(Self.fake(24))")
        assertRedactsExactly("sk_1ive_\(Self.fake(30))", in: "sk_1ive_\(Self.fake(30))")
        XCTAssertEqual(SecretDetector.tolerantPrefix(#"\bAKIA[0-9A-Za-z]{16}"#), #"\bAK[1lI|T]A[0-9A-Za-z]{16}"#)
        XCTAssertEqual(SecretDetector.tolerantPrefix(#"\bxox[bp]-"#), #"\bx[0Oo]x[bp]-"#)
        assertRedactsExactly("sk—proj-\(Self.fake(40))", in: "key: sk—proj-\(Self.fake(40))") // OCR read "-" as an em dash
        XCTAssertEqual(SecretDetector.tolerantPrefix("ab?c"), "ab?c") // quantified literal is left alone
    }

    func testWrappedLineIsJoinedAndBothPartsCovered() {
        let key = "sk-proj-" + Self.fake(48)
        let first = "export OPENAI_API_KEY=" + key.prefix(20), second = String(key.dropFirst(20))
        let findings = detector.findSecrets(in: [first, second], separators: [""])
        XCTAssertTrue(findings.contains { $0.line == 0 && $0.range == NSRange(location: 22, length: 20) })
        XCTAssertTrue(findings.contains { $0.line == 1 && $0.range == NSRange(location: 0, length: second.utf16.count) })
    }

    // MARK: True negatives

    func testPlaceholdersAndMaskedValuesAreAllowed() {
        for line in ["OPENAI_API_KEY=sk-proj-your-api-key-here", "API_KEY=changeme", "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
                     "OPENAI_API_KEY=sk-proj-****************abcd", "STRIPE_KEY=sk_" + "live_xxxxxxxxxxxxxxxxxxxxxxxx" /* split: GitHub push protection */,
                     "TOKEN=example-\(Self.fake(30))"] {
            XCTAssertEqual(redacted(line), [], line)
        }
    }

    func testNormalTerminalOutputIsLeftAlone() {
        for line in [
            "commit 3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e5b7d9f0a",
            "id: 550e8400-e29b-41d4-a716-446655440000",
            "sha256: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "let total = items.reduce(0, +)",
            "npm install --save-dev typescript",
            "git checkout -b feature/login-page",
            "Author: Jane Doe <jane@test.dev>",
            "PASSWORD=hunter2", // keyword alone (+50) stays below 60, per CLAUDE.md's scoring
            "drwxr-xr-x  5 dev  staff  160 Nov 24 10:54 node_modules",
        ] {
            XCTAssertEqual(redacted(line), [], line)
        }
    }

    func testRandomnessAloneNeverRedacts() {
        XCTAssertTrue(SecretDetector.looksRandom(Self.fake(40)))
        XCTAssertEqual(redacted("build \(Self.fake(40)) done"), [])
    }

    func testEntropy() {
        XCTAssertEqual(SecretDetector.entropy("aaaa"), 0)
        XCTAssertEqual(SecretDetector.entropy("abcd"), 2, accuracy: 1e-9)
        XCTAssertFalse(SecretDetector.looksRandom("3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e5b7d9f0a")) // hex can't exceed 4.0
    }
}
