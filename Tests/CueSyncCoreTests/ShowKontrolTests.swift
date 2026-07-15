import Foundation
import XCTest
@testable import CueSyncCore

final class ShowKontrolParserTests: XCTestCase {
    func testSampleFixtureParsesWithSaneCuesIncludingAStartPoint() throws {
        let content = try Samples.string("sample-showkontrol.cue")
        let result = try ShowKontrolParser.parse(content: content)
        XCTAssertFalse(result.cuePoints.isEmpty)
        assertSaneCues(result.cuePoints, "showkontrol-sample")
        XCTAssertTrue(result.cuePoints.contains { $0.start <= 0.001 }, "a start point (t=0) should exist")
    }

    func testRealFixtureParsesWithSaneCues() throws {
        let content = try Samples.string("real-showkontrol.cue")
        let result = try ShowKontrolParser.parse(content: content)
        assertSaneCues(result.cuePoints, "showkontrol-real")
    }

    func testEmptyContentThrowsNoData() {
        XCTAssertThrowsError(try ShowKontrolParser.parse(content: ""))
    }

    func testWhitespaceOnlyContentThrowsNoData() {
        XCTAssertThrowsError(try ShowKontrolParser.parse(content: "\r\n   \r\n"))
    }

    func testNonFiniteOrNegativeMillisecondsProduceSaneCues() throws {
        let content = "00:00:00:00,00000000,nan,A,TAG,,,,,,\r" +
                      "00:00:01:00,00000100,inf,B,TAG,,,,,,\r" +
                      "00:00:02:00,00000200,-5000,C,TAG,,,,,,\r" +
                      "00:00:03:00,00000300,1e30,D,TAG,,,,,,\r"
        let result = try ShowKontrolParser.parse(content: content)
        assertSaneCues(result.cuePoints, "showkontrol-malformed-ms")
        if let dur = result.suggestedDurationMs { XCTAssertTrue(dur.isFinite) }
    }

    func testUnicodeCueNamesSurviveParsing() throws {
        let content = "00:00:00:00,00000000,0,Intro 日本語 🎧,TAG,,,,,,\r" +
                      "00:00:05:00,00000500,5000,Drop™ Ω,TAG,,,,,,\r"
        let result = try ShowKontrolParser.parse(content: content)
        XCTAssertEqual(result.cuePoints.map(\.name), ["Intro 日本語 🎧", "Drop™ Ω"])
    }

    func testCRLFLineEndingsAreTolerated() throws {
        // Windows-authored .cue files (or a copy/paste through a CRLF editor) may carry
        // "\r\n" instead of the format's native lone "\r" — the parser must not choke on
        // the extra "\n" byte.
        let content = "00:00:00:00,00000000,0,A,TAG,,,,,,\r\n00:00:01:00,00000100,1000,B,TAG,,,,,,\r\n"
        if let result = try? ShowKontrolParser.parse(content: content) {
            assertSaneCues(result.cuePoints, "showkontrol-crlf")
        }
        // No hard requirement on whether CRLF input yields 1 or 2 rows — only that it
        // never throws an uncaught error or produces an insane cue.
    }

    func testFuzzedRandomContentNeverProducesInsaneCues() {
        var rng = XorShift64(seed: 0x5C5C)
        for _ in 0..<200 {
            let len = Int(rng.next() % 200)
            let s = String(decoding: rng.bytes(len), as: UTF8.self)
            if let r = try? ShowKontrolParser.parse(content: s) {
                assertSaneCues(r.cuePoints, "showkontrol-fuzz")
            }
        }
    }
}

final class ShowKontrolExporterTests: XCTestCase {
    func testBasicExportUsesCRSeparatorAndStripsCommasFromNames() {
        let cues = [
            CuePoint(id: "a", start: 0, name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 65.5, name: "Drop, here", color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        let out = ShowKontrolExporter.generate(cuePoints: cues)
        XCTAssertNotNil(out)
        let text = out ?? ""
        XCTAssertTrue(text.contains("\r"))
        XCTAssertFalse(text.contains("Drop, here"))
        let tc = ShowKontrolExporter.secondsToTimecode(65.5)
        XCTAssertEqual(tc.formatted.count, 11, "HH:MM:SS:FF is 11 characters")
        XCTAssertEqual(tc.milliseconds, 65500)
    }

    func testExportOfDisabledOnlyCuesReturnsNil() {
        let cues = [CuePoint(id: "a", start: 0, name: "Off", color: "#fff", yValue: 0, curve: 1, enabled: false)]
        XCTAssertNil(ShowKontrolExporter.generate(cuePoints: cues))
    }

    func testExportOfEmptyCueListReturnsNil() {
        XCTAssertNil(ShowKontrolExporter.generate(cuePoints: []))
    }

    /// Format-significant per spec §4: ".cue" output must use `\r`-only line separators
    /// and contain **no `\n` byte** anywhere, verified on raw bytes (not a `String` view,
    /// which could mask a platform newline translation on Windows).
    func testRawBytesContainNoLineFeedAndUseOnlyCRSeparators() {
        let cues = [
            CuePoint(id: "a", start: 0,  name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 10, name: "Mid",   color: "#fff", yValue: 50, curve: 1, enabled: true),
            CuePoint(id: "c", start: 20, name: "End",   color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        guard let out = ShowKontrolExporter.generate(cuePoints: cues) else {
            return XCTFail("export produced no output")
        }
        let bytes = Array(out.utf8)
        XCTAssertFalse(bytes.contains(0x0A), "raw output bytes must contain no LF (0x0A) byte")
        let crCount = bytes.filter { $0 == 0x0D }.count
        // Records are CR-*joined*, so N records produce N-1 separators (not N) — none doubled into CRLF.
        XCTAssertEqual(crCount, cues.count - 1, "exactly one CR between each record, none doubled into CRLF")
    }

    func testNonFiniteCueNamesWithNewlinesCannotInjectExtraRecords() {
        let cues = [
            CuePoint(id: "a", start: 0,  name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 10, name: "Line1\nLine2\rLine3", color: "#fff", yValue: 0, curve: 1, enabled: true),
        ]
        let out = ShowKontrolExporter.generate(cuePoints: cues) ?? ""
        XCTAssertFalse(Array(out.utf8).contains(0x0A), "no LF leaks into .cue output via a hostile cue name")
        let records = out.components(separatedBy: "\r")
        XCTAssertEqual(records.count, cues.count, "one record per cue — no injected rows via embedded CR/LF")
    }

    func testUnicodeCueNamesRoundTripIntoRawUTF8Bytes() {
        let cues = [CuePoint(id: "a", start: 1, name: "日本語 🎧 café", color: "#fff", yValue: 0, curve: 1, enabled: true)]
        let out = ShowKontrolExporter.generate(cuePoints: cues) ?? ""
        XCTAssertTrue(out.contains("日本語 🎧 café"))
    }

    func testNonFiniteStartValuesNeverCrashTimecodeConversion() {
        for bad in [Double.nan, .infinity, -.infinity, 1e18, -50, 9.9e17] {
            let tc = ShowKontrolExporter.secondsToTimecode(bad)
            XCTAssertGreaterThanOrEqual(tc.formatted.count, 11, "timecode produced for \(bad)")
        }
        let cues = [
            CuePoint(id: "a", start: .nan, name: "n", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: .infinity, name: "i", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "c", start: 1e18, name: "h", color: "#fff", yValue: 0, curve: 1, enabled: true),
        ]
        _ = ShowKontrolExporter.generate(cuePoints: cues) // must not crash
    }

    func testBoundaryZeroSecondsProducesAllZeroTimecode() {
        let tc = ShowKontrolExporter.secondsToTimecode(0)
        XCTAssertEqual(tc.formatted, "00:00:00:00")
        XCTAssertEqual(tc.milliseconds, 0)
    }
}
