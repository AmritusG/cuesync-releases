import Foundation
import XCTest
@testable import CueSyncCore

// =============================================================================
// One test per acceptance criterion in spec CUESYNC-7 §3 for the new
// `Support/TextTools.swift` module (`slugify()` + `generateToken()`).
// =============================================================================

final class SlugifyTests: XCTestCase {
    func testBasicLowercasesAndJoinsWithHyphen() {
        XCTAssertEqual(TextTools.slugify("Hello World"), "hello-world")
    }

    func testRunsOfSeparatorsCollapseWithNoLeadingOrTrailingHyphen() {
        for input in ["a   b__c", "a---b"] {
            let slug = TextTools.slugify(input)
            XCTAssertFalse(slug.contains("--"), "expected no '--' run in '\(slug)' for input '\(input)'")
            XCTAssertFalse(slug.hasPrefix("-"), "expected no leading '-' in '\(slug)' for input '\(input)'")
            XCTAssertFalse(slug.hasSuffix("-"), "expected no trailing '-' in '\(slug)' for input '\(input)'")
        }
        XCTAssertEqual(TextTools.slugify("a   b__c"), "a-b-c")
        XCTAssertEqual(TextTools.slugify("a---b"), "a-b")
    }

    func testOutputIsDrawnOnlyFromLowercaseAlphanumericAndHyphen() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for input in [" spaces and punctuation! ", "café", "日本語", "🎧🎛️", "MiXeD CaSe 123"] {
            let slug = TextTools.slugify(input)
            for scalar in slug.unicodeScalars {
                XCTAssertTrue(allowed.contains(scalar), "unexpected character '\(scalar)' in slug '\(slug)' for input '\(input)'")
            }
        }
    }

    func testPathTraversalInputsProduceNoSlashBackslashOrDotDot() {
        for input in ["../../etc/passwd", "..\\..\\win.ini", "a/b\\c"] {
            let slug = TextTools.slugify(input)
            XCTAssertFalse(slug.contains("/"), "slug '\(slug)' for '\(input)' must not contain '/'")
            XCTAssertFalse(slug.contains("\\"), "slug '\(slug)' for '\(input)' must not contain '\\\\'")
            XCTAssertFalse(slug.contains(".."), "slug '\(slug)' for '\(input)' must not contain '..'")
            XCTAssertNotEqual(slug, ".")
            XCTAssertNotEqual(slug, "..")
        }
    }

    func testNULAndControlCharactersAreDropped() {
        let slug = TextTools.slugify("a\u{0}b\tc")
        for scalar in slug.unicodeScalars {
            XCTAssertFalse(scalar.value == 0 || (scalar.value < 0x20), "control/NUL character survived in '\(slug)'")
        }
        XCTAssertEqual(slug, "a-b-c")
    }

    func testWindowsReservedDeviceNamesAreEscaped() {
        let reservedNames: Set<String> = ["con", "prn", "aux", "nul", "com1", "lpt9"]
        for input in ["CON", "con", "COM1", "LPT9", "NUL.txt"] {
            let slug = TextTools.slugify(input)
            XCTAssertFalse(reservedNames.contains(slug.lowercased()),
                            "slug '\(slug)' for input '\(input)' equals a reserved device name")
        }
    }

    func testNoTrailingDotOrSpaceSurvives() {
        for input in ["name.", "name "] {
            let slug = TextTools.slugify(input)
            XCTAssertFalse(slug.hasSuffix("."), "slug '\(slug)' for '\(input)' ends in '.'")
            XCTAssertFalse(slug.hasSuffix(" "), "slug '\(slug)' for '\(input)' ends in ' '")
        }
        XCTAssertEqual(TextTools.slugify("name."), "name")
        XCTAssertEqual(TextTools.slugify("name "), "name")
    }

    func testEmptyOrDegenerateInputReturnsNonEmptyFallback() {
        for input in ["", "   ", "/// ..."] {
            XCTAssertEqual(TextTools.slugify(input), "untitled")
        }
    }

    func testCustomFallbackIsUsedWhenProvided() {
        XCTAssertEqual(TextTools.slugify("", fallback: "no-name"), "no-name")
    }

    func testResultLengthNeverExceedsMaxLengthAndTruncationHasNoTrailingHyphen() {
        let slug = TextTools.slugify("the quick brown fox jumps over the lazy dog again and again", maxLength: 10)
        XCTAssertLessThanOrEqual(slug.count, 10)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testTruncationCutsOnASeparatorBoundary() {
        // "hello-world-again" truncated to 8 chars: hard cut would be "hello-wo";
        // separator-boundary truncation must back up to the last '-' within the window.
        let slug = TextTools.slugify("hello world again", maxLength: 8)
        XCTAssertEqual(slug, "hello")
    }

    func testDeterministicAndIdempotent() {
        let inputs = ["Hello World", "../../etc/passwd", "CON", "café日本語", "  a---b  ", ""]
        for input in inputs {
            let first = TextTools.slugify(input)
            let second = TextTools.slugify(input)
            XCTAssertEqual(first, second, "slugify must be deterministic for '\(input)'")
            XCTAssertEqual(TextTools.slugify(first), first, "slugify must be idempotent for '\(input)'")
        }
    }
}

final class GenerateTokenTests: XCTestCase {
    func testDefaultLengthIs32Characters() {
        XCTAssertEqual(TextTools.generateToken().count, 32)
    }

    func testExplicitLengthsAreRespectedIncludingOddLengths() {
        for length in [1, 2, 5, 7, 16, 33, 64] {
            XCTAssertEqual(TextTools.generateToken(length: length).count, length, "expected \(length) characters")
        }
    }

    func testEveryCharacterIsLowercaseHex() {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        let token = TextTools.generateToken(length: 256)
        for scalar in token.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "unexpected character '\(scalar)' in token")
        }
    }

    func testZeroLengthReturnsEmptyString() {
        XCTAssertEqual(TextTools.generateToken(length: 0), "")
    }

    func testNegativeLengthReturnsEmptyString() {
        XCTAssertEqual(TextTools.generateToken(length: -5), "")
    }

    func testBatchOfTenThousandDefaultLengthTokensHasNoDuplicates() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            seen.insert(TextTools.generateToken())
        }
        XCTAssertEqual(seen.count, 10_000, "expected 10,000 unique tokens")
    }

    func testSuccessiveCallsReturnDifferentValues() {
        XCTAssertNotEqual(TextTools.generateToken(), TextTools.generateToken())
    }

    func testTokensAreNotMonotonicallyIncreasingAndShareNoLongCommonPrefix() {
        let tokens = (0..<50).map { _ in TextTools.generateToken() }
        XCTAssertFalse(zip(tokens, tokens.dropFirst()).allSatisfy { $0 < $1 },
                        "tokens must not be monotonically increasing — smells like a Date/counter regression")
        for i in 1..<tokens.count {
            let commonPrefixLength = zip(tokens[0], tokens[i]).prefix { $0 == $1 }.count
            XCTAssertLessThan(commonPrefixLength, 8, "tokens share a suspiciously long common prefix")
        }
    }

    func testAllSixteenHexSymbolsAreReachable() {
        var symbolsSeen = Set<Character>()
        for _ in 0..<200 {
            symbolsSeen.formUnion(TextTools.generateToken(length: 64))
        }
        XCTAssertEqual(symbolsSeen, Set("0123456789abcdef"), "expected every hex symbol to appear across a large sample")
    }
}

final class TextToolsPortComplianceTests: XCTestCase {
    /// Tests/CueSyncCoreTests/TextToolsTests.swift -> Tests/CueSyncCoreTests -> Tests -> repo root
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let textToolsURL = repoRoot.appendingPathComponent("CueSync/CueSync/Support/TextTools.swift")

    func testTextToolsImportsOnlyFoundation() throws {
        let source = try String(contentsOf: Self.textToolsURL, encoding: .utf8)
        for banned in ["import AppKit", "import SwiftUI", "import Security"] {
            XCTAssertFalse(source.contains(banned),
                            "TextTools.swift must not contain '\(banned)' — it must stay in the cross-platform core")
        }
        XCTAssertTrue(source.contains("import Foundation"))
    }

    func testTextToolsUsesSystemRandomNumberGeneratorNotTimeOrSequenceDerived() throws {
        let source = try String(contentsOf: Self.textToolsURL, encoding: .utf8)
        XCTAssertTrue(source.contains("SystemRandomNumberGenerator"),
                      "generateToken() must be backed by SystemRandomNumberGenerator")
        for banned in ["Date(", "timeIntervalSince", "arc4random_buf", "srand"] {
            XCTAssertFalse(source.contains(banned),
                            "TextTools.swift must not contain '\(banned)' — tokens must not be time/sequence derived")
        }
    }
}
