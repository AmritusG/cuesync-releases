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

    // MARK: - maxLength boundary sizes

    func testMaxLengthZeroReturnsFallback() {
        XCTAssertEqual(TextTools.slugify("hello world", maxLength: 0), "untitled")
    }

    func testMaxLengthNegativeReturnsFallback() {
        XCTAssertEqual(TextTools.slugify("hello world", maxLength: -5), "untitled")
    }

    func testMaxLengthExactlyEqualsSlugLengthIsNotTruncated() {
        // "hello-world" is exactly 11 characters; maxLength == count is the off-by-one
        // boundary between "unchanged" and "truncate" — must not cut a character here.
        let slug = TextTools.slugify("hello world", maxLength: 11)
        XCTAssertEqual(slug, "hello-world")
    }

    func testMaxLengthOfOneHardCutsWhenNoSeparatorFitsInWindow() {
        // Window is a single character, so there is no '-' to back up to; the
        // implementation must fall back to a hard cut rather than returning empty.
        XCTAssertEqual(TextTools.slugify("hello world", maxLength: 1), "h")
    }

    func testLongUnbrokenWordWithNoSeparatorHardCutsWithinWindow() {
        let slug = TextTools.slugify(String(repeating: "a", count: 16), maxLength: 5)
        XCTAssertEqual(slug, "aaaaa")
        XCTAssertEqual(slug.count, 5)
    }

    // MARK: - Platform-quirk separators: CRLF and Unicode line/paragraph separators

    func testCRLFAndUnicodeLineSeparatorsActAsSingleSeparatorsNotLiteralCharacters() {
        // "\r\n" (Windows), lone "\r" / "\n", and the Unicode NEL/LS/PS/VT/FF separators
        // a Windows- or cross-platform-authored text file may carry must each collapse to
        // exactly one '-' — including the two-character "\r\n" pair, which must not emit
        // a doubled "--".
        let input = "line1\r\nline2\rline3\nline4\u{0085}line5\u{2028}line6\u{2029}line7\u{000B}line8\u{000C}line9"
        let slug = TextTools.slugify(input)
        XCTAssertEqual(slug, "line1-line2-line3-line4-line5-line6-line7-line8-line9")
        XCTAssertFalse(slug.contains("--"))
    }

    // MARK: - Case-insensitive-filesystem quirk: full reserved-device-name matrix

    private static func alternatingCase(_ s: String) -> String {
        String(s.enumerated().map { index, char in
            index % 2 == 0 ? Character(char.uppercased()) : Character(char.lowercased())
        })
    }

    func testFullMatrixOfWindowsReservedDeviceNamesAcrossCasingAreEscapedWithUnderscorePrefix() {
        var reservedBaseNames = ["con", "prn", "aux", "nul"]
        for n in 1...9 {
            reservedBaseNames.append("com\(n)")
            reservedBaseNames.append("lpt\(n)")
        }
        XCTAssertEqual(reservedBaseNames.count, 22, "sanity check: 4 fixed names + COM1-9 + LPT1-9")

        for name in reservedBaseNames {
            let variants = [name, name.uppercased(), Self.alternatingCase(name)]
            for variant in variants {
                let slug = TextTools.slugify(variant)
                XCTAssertEqual(slug, "_" + name,
                                "expected reserved name '\(variant)' to be escaped to '_\(name)', got '\(slug)'")
            }
        }
    }

    // MARK: - Unicode edge cases beyond the basic accented/CJK/emoji sample

    func testBidiOverrideZeroWidthAndUnicodeWhitespaceAreNeverEmittedLiterally() {
        // U+202E (RIGHT-TO-LEFT OVERRIDE) is the "RTLO trick" used to disguise a
        // dangerous extension as a harmless one (e.g. rendering "gnp.exe" reversed);
        // U+200B/U+200D are invisible zero-width characters; U+00A0/U+2003 are non-ASCII
        // whitespace. None are in [a-z0-9], so all must be stripped, never survive verbatim.
        let input = "evil\u{202E}gnp.exe\u{200B}\u{200D}name\u{00A0}here\u{2003}end"
        let slug = TextTools.slugify(input)
        let bannedScalars: [Unicode.Scalar] = ["\u{202E}", "\u{200B}", "\u{200D}", "\u{00A0}", "\u{2003}"]
        for banned in bannedScalars {
            XCTAssertFalse(slug.unicodeScalars.contains(banned),
                            "slug '\(slug)' must not contain U+\(String(format: "%04X", banned.value))")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for scalar in slug.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "unexpected character '\(scalar)' in slug '\(slug)'")
        }
    }

    func testDecomposedAndPrecomposedAccentedInputBothProduceValidASCIIOnlySlugs() {
        let precomposed = "café"        // é is a single scalar, U+00E9
        let decomposed = "cafe\u{0301}" // "e" + combining acute accent, U+0301
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for input in [precomposed, decomposed] {
            let slug = TextTools.slugify(input)
            XCTAssertFalse(slug.isEmpty, "slug for '\(input)' must not be empty")
            for scalar in slug.unicodeScalars {
                XCTAssertTrue(allowed.contains(scalar), "unexpected character in slug '\(slug)' for input '\(input)'")
            }
        }
        // The implementation walks unicodeScalars without Unicode-normalizing first (by
        // design — see spec §5), so canonically-equivalent NFC/NFD spellings of the same
        // visible text are allowed to slugify differently: the decomposed form's
        // combining accent is dropped as a lone separator, leaving the base "e" behind,
        // while the precomposed "é" is dropped as a single non-ASCII unit.
        XCTAssertEqual(TextTools.slugify(precomposed), "caf")
        XCTAssertEqual(TextTools.slugify(decomposed), "cafe")
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

    func testVeryLargeLengthProducesExactCharacterCountWithoutCrashing() {
        let token = TextTools.generateToken(length: 10_000)
        XCTAssertEqual(token.count, 10_000)
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        for scalar in token.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar))
        }
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
        for banned in ["import AppKit", "import SwiftUI", "import Security", "import Combine"] {
            XCTAssertFalse(source.contains(banned),
                            "TextTools.swift must not contain '\(banned)' — it must stay in the cross-platform core")
        }
        XCTAssertTrue(source.contains("import Foundation"))
    }

    func testTextToolsUsesSystemRandomNumberGeneratorNotTimeOrSequenceDerived() throws {
        let source = try String(contentsOf: Self.textToolsURL, encoding: .utf8)
        XCTAssertTrue(source.contains("SystemRandomNumberGenerator"),
                      "generateToken() must be backed by SystemRandomNumberGenerator")
        for banned in ["Date(", "timeIntervalSince", "arc4random_buf", "srand", "ProcessInfo", "getpid("] {
            XCTAssertFalse(source.contains(banned),
                            "TextTools.swift must not contain '\(banned)' — tokens must not be time/PID/sequence derived")
        }
    }

    func testTextToolsHasNoFilesystemSideEffects() throws {
        // Threat model §4: "No filesystem side effects in the module." slugify() and
        // generateToken() must return strings only — never touch disk.
        let source = try String(contentsOf: Self.textToolsURL, encoding: .utf8)
        for banned in ["FileManager", "contentsOf", ".write(to:", "fileURLWithPath"] {
            XCTAssertFalse(source.contains(banned),
                            "TextTools.swift must not contain '\(banned)' — the module must have no filesystem side effects")
        }
    }
}
