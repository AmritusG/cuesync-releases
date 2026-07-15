import Foundation
import XCTest
@testable import CueSyncCore

final class ResolumeParserTests: XCTestCase {
    func testSampleFixtureParsesWithSaneCues() throws {
        let xml = try Samples.string("sample-resolume-envelope.xml")
        let result = try ResolumeParser.parse(xml: xml)
        XCTAssertFalse(result.points.isEmpty)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 60)
        assertSaneCues(cues, "resolume-sample")
    }

    func testRealFixtureParsesPointsSortedByX() throws {
        let xml = try Samples.string("real-resolume-envelope.xml")
        let result = try ResolumeParser.parse(xml: xml)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 120)
        assertSaneCues(cues, "resolume-real")
        let xs = result.points.map(\.x)
        XCTAssertEqual(xs, xs.sorted(), "points must be sorted by x")
    }

    func testMalformedCoordinatesProduceSaneCues() throws {
        let xml = """
        <Preset name="Bad">
          <ModifierEnvelope>
            <points>
              <point x="nan" y="0.5" curve="1"/>
              <point x="-0.5" y="inf" curve="999"/>
              <point x="0.5" y="-2" curve="-3"/>
              <point x="1.0" y="2" curve="0"/>
            </points>
          </ModifierEnvelope>
        </Preset>
        """
        let result = try ResolumeParser.parse(xml: xml)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 60)
        assertSaneCues(cues, "resolume-malformed")
    }

    func testEnvelopeWithNoPointsThrowsNoData() {
        XCTAssertThrowsError(try ResolumeParser.parse(xml: "<Preset name=\"x\"><points></points></Preset>"))
    }

    func testUnicodePresetNamePreserved() throws {
        let xml = """
        <Preset name="Envelope™ 日本語 🎛️">
          <ModifierEnvelope><points><point x="0" y="0" curve="1"/></points></ModifierEnvelope>
        </Preset>
        """
        let result = try ResolumeParser.parse(xml: xml)
        XCTAssertEqual(result.presetName, "Envelope™ 日本語 🎛️")
    }

    func testFuzzedMutationsOfRealFixtureNeverProduceInsaneCues() throws {
        var rng = XorShift64(seed: 0x4E5E)
        let base = try Samples.string("real-resolume-envelope.xml")
        let baseBytes = Array(base.utf8)
        for _ in 0..<150 {
            var bytes = baseBytes
            let flips = Int(rng.next() % 20)
            for _ in 0..<flips where !bytes.isEmpty {
                bytes[Int(rng.next() % UInt64(bytes.count))] = rng.byte()
            }
            let s = String(decoding: bytes, as: UTF8.self)
            if let r = try? ResolumeParser.parse(xml: s) {
                let cues = ResolumeParser.convertToCuePoints(points: r.points, duration: 60)
                assertSaneCues(cues, "resolume-fuzz")
            }
        }
    }
}

final class ResolumeExporterTests: XCTestCase {
    func testExportedNonFiniteCueNeverSerializesAsNanOrInf() throws {
        let cues = [
            CuePoint(id: "a", start: 0, name: "s", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: .nan, name: "x", color: "#fff", yValue: .infinity, curve: 1, enabled: true),
            CuePoint(id: "c", start: 60, name: "e", color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "P") ?? ""
        XCTAssertTrue(out.contains("<point"))
        XCTAssertFalse(out.contains("\"nan\"") || out.contains("\"inf\"") || out.contains("\"-inf\""))
        let reparsed = try ResolumeParser.parse(xml: out)
        for p in reparsed.points {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "exported point must be finite (x=\(p.x), y=\(p.y))")
        }
    }

    func testExportUsesPlainDecimalCappedAtSixPlacesNeverScientificNotation() {
        let cues = [
            CuePoint(id: "a", start: 0,     name: "s", color: "#fff", yValue: 0,         curve: 1, enabled: true),
            CuePoint(id: "b", start: 0.001, name: "t", color: "#fff", yValue: 33.333333, curve: 1, enabled: true),
            CuePoint(id: "c", start: 20,    name: "m", color: "#fff", yValue: 60,        curve: 1, enabled: true),
            CuePoint(id: "d", start: 60,    name: "e", color: "#fff", yValue: 100,       curve: 1, enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "P") ?? ""
        let coords = pointAttributeStrings(out, "x") + pointAttributeStrings(out, "y")
        XCTAssertGreaterThanOrEqual(coords.count, 8, "expected coordinates for every point")
        for v in coords {
            XCTAssertFalse(v.lowercased().contains("e"), "no scientific notation (got \(v))")
            XCTAssertLessThanOrEqual(decimalPlaces(v), 6, "<= 6 decimal places (got \(v))")
            XCTAssertNotNil(Double(v), "coordinate must parse as a number (got \(v))")
        }
    }

    func testRoundTripExportParseConvertPreservesArrivalCurvesAndPositions() throws {
        let cues = [
            CuePoint(id: "a", start: 0,  name: "Start", color: "#fff", yValue: 10, curve: 5,  enabled: true),
            CuePoint(id: "b", start: 30, name: "Mid",   color: "#fff", yValue: 80, curve: 7,  enabled: true),
            CuePoint(id: "c", start: 60, name: "End",   color: "#fff", yValue: 40, curve: 11, enabled: true),
        ]
        let xml = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "RT")
        XCTAssertNotNil(xml)
        let parsed = try ResolumeParser.parse(xml: xml ?? "")
        let back = ResolumeParser.convertToCuePoints(points: parsed.points, duration: 60)
        XCTAssertEqual(back.count, 3)
        guard back.count == 3 else { return }
        XCTAssertEqual(back[0].curve, 1, "first curve resets to Linear (no arrival)")
        XCTAssertEqual(back[1].curve, 7, "middle arrival curve preserved")
        XCTAssertEqual(back[2].curve, 11, "end arrival curve preserved")
        assertApproxEqual(back[1].start, 30, tolerance: 0.5, "middle position preserved")
        assertApproxEqual(back[2].yValue, 40, tolerance: 1.0, "end yValue preserved")
    }

    func testOutOfRangeCurveNeverSerializesVerbatim() throws {
        let cues = [
            CuePoint(id: "a", start: 0,  name: "s", color: "#fff", yValue: 0,  curve: 1,   enabled: true),
            CuePoint(id: "b", start: 30, name: "m", color: "#fff", yValue: 50, curve: 999, enabled: true),
            CuePoint(id: "c", start: 60, name: "e", color: "#fff", yValue: 0,  curve: -7,  enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "C") ?? ""
        let reparsed = try ResolumeParser.parse(xml: out)
        for p in reparsed.points {
            XCTAssertTrue((1...23).contains(p.curve), "exported curve must be in 1...23 (got \(p.curve))")
        }
    }

    func testZeroOrNegativeDurationReturnsNil() {
        let cues = [CuePoint.makeDefault(at: 0, name: "s")]
        XCTAssertNil(ResolumeExporter.generate(cuePoints: cues, trackDuration: 0, presetName: "P"))
        XCTAssertNil(ResolumeExporter.generate(cuePoints: cues, trackDuration: -10, presetName: "P"))
    }

    func testAllDisabledCuesReturnsNil() {
        let cues = [CuePoint(id: "a", start: 0, name: "s", color: "#fff", yValue: 0, curve: 1, enabled: false)]
        XCTAssertNil(ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "P"))
    }

    func testUnicodePresetNameIsXmlEscapedAndRoundTrips() throws {
        let cues = [CuePoint.makeDefault(at: 0, name: "s")]
        let name = "My <Envelope> & \"Quotes\" 日本語"
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: name) ?? ""
        XCTAssertFalse(out.contains("<Envelope>"), "raw '<' from the name must not appear unescaped in XML")
        let parsed = try ResolumeParser.parse(xml: out)
        XCTAssertEqual(parsed.presetName, name, "escaped name round-trips back to the original string")
    }

    /// Export parity (spec §3): the same cue points and duration must always produce
    /// byte-identical XML — the only value allowed to vary run-to-run is the timestamp
    /// `uniqueId` on `ModifierEnvelope` (explicitly out of scope per the threat model,
    /// §4 "Cryptographically secure primitives"). Everything else must be a pure function
    /// of the input, with no locale- or platform-dependent formatting.
    func testExportIsDeterministicAcrossRepeatedCallsIgnoringOnlyTheTimestampUniqueId() {
        let cues = [
            CuePoint(id: "a", start: 0,     name: "Start", color: "#fff", yValue: 0,  curve: 1, enabled: true),
            CuePoint(id: "b", start: 12.34, name: "Mid",   color: "#fff", yValue: 55, curve: 9, enabled: true),
            CuePoint(id: "c", start: 60,    name: "End",   color: "#fff", yValue: 100, curve: 3, enabled: true),
        ]
        let first = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "Parity") ?? ""
        let second = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "Parity") ?? ""
        XCTAssertEqual(stripUniqueId(first), stripUniqueId(second),
                       "export must be a pure function of its inputs (aside from the timestamp uniqueId)")
    }

    // MARK: - Helpers

    private func stripUniqueId(_ xml: String) -> String {
        xml.split(separator: "\n").map { line -> String in
            guard line.contains("ModifierEnvelope") && line.contains("uniqueId") else { return String(line) }
            guard let range = line.range(of: "uniqueId=\"") else { return String(line) }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return String(line) }
            return line.replacingOccurrences(of: line[range.lowerBound...end], with: "uniqueId=\"REDACTED\"")
        }.joined(separator: "\n")
    }

    private func pointAttributeStrings(_ xml: String, _ name: String) -> [String] {
        var out: [String] = []
        for line in xml.split(separator: "\n") where line.contains("<point") {
            guard let r = line.range(of: "\(name)=\"") else { continue }
            let rest = line[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            out.append(String(rest[..<end]))
        }
        return out
    }

    private func decimalPlaces(_ s: String) -> Int {
        guard let dot = s.firstIndex(of: ".") else { return 0 }
        return s.distance(from: s.index(after: dot), to: s.endIndex)
    }
}
