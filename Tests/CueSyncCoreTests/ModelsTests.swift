import Foundation
import XCTest
@testable import CueSyncCore

final class CurveTypeTests: XCTestCase {
    func testEvaluateIsAlwaysFiniteAcrossDomainIncludingOutOfRangeInputs() {
        let ts: [Double] = [-1, 0, 0.0001, 0.25, 0.5, 0.75, 0.9999, 1, 2, .infinity, -.infinity, .nan]
        for curve in 0...25 { // includes the out-of-range boundaries 0, 24, 25
            for t in ts {
                let v = CurveType.evaluate(curve, t: t)
                XCTAssertTrue(v.isFinite, "curve \(curve) at t=\(t) produced non-finite \(v)")
            }
        }
    }

    func testKnownMidpointValues() {
        assertApproxEqual(CurveType.evaluate(1, t: 0.5), 0.5, "linear midpoint")
        assertApproxEqual(CurveType.evaluate(2, t: 0.5), 0.25, "quad-in midpoint")
        assertApproxEqual(CurveType.evaluate(3, t: 0.5), 0.75, "quad-out midpoint")
        assertApproxEqual(CurveType.evaluate(7, t: 0.5), 0.5, "sine in/out midpoint")
        XCTAssertEqual(CurveType.evaluate(23, t: 0.7), 0.0, "hold is always 0")
    }

    func testEveryCurveHasANonEmptyName() {
        for id in 1...23 {
            XCTAssertFalse(CurveType.name(for: id).isEmpty, "curve \(id) has no name")
        }
    }

    func testOutOfRangeCurveIdsFallBackToLinearName() {
        for id in [0, -1, 24, 999, Int.max, Int.min] {
            XCTAssertEqual(CurveType.name(for: id), "Linear", "curve id \(id) should fall back to Linear")
        }
    }

    func testGroupingCoversAllTwentyThreeCurvesExactlyOnce() {
        let grouped = CurveType.grouped.flatMap { $0.curves }
        XCTAssertEqual(grouped.count, 23, "grouping must cover all 23 curves")
        XCTAssertEqual(Set(grouped.map(\.id)).count, 23, "no curve id duplicated across categories")
    }
}

final class CuePointTests: XCTestCase {
    func testNormalizedXAtMidpoint() {
        let c = CuePoint.makeDefault(at: 30, name: "x")
        assertApproxEqual(c.normalizedX(duration: 60), 0.5, "normalizedX midpoint")
    }

    func testNormalizedXWithZeroDurationIsZeroNotNaN() {
        let c = CuePoint.makeDefault(at: 30, name: "x")
        XCTAssertEqual(c.normalizedX(duration: 0), 0, "zero duration must not produce NaN via 0-division")
    }

    func testNormalizedXClampsNegativeStartToNonNegative() {
        let bad = CuePoint.makeDefault(at: -10, name: "neg")
        XCTAssertGreaterThanOrEqual(bad.normalizedX(duration: 60), 0)
    }

    func testNormalizedYClampsOutOfRangeYValue() {
        var bad = CuePoint.makeDefault(at: 0, name: "y")
        bad.yValue = 250
        XCTAssertTrue((0...1).contains(bad.normalizedY), "yValue 250 must clamp normalizedY into 0...1")
    }

    func testSanitizedGuaranteesFiniteNonNegativeStartYValue0to100Curve1to23() {
        let cases: [(start: Double, y: Double, curve: Int)] = [
            (.nan, .nan, 0), (.infinity, .infinity, 99), (-.infinity, -5, -1),
            (-10, 150, 24), (1e18, 50, 12), (5, 50, 1),
        ]
        for (start, y, curve) in cases {
            var c = CuePoint.makeDefault()
            c.start = start; c.yValue = y; c.curve = curve
            let s = c.sanitized()
            XCTAssertTrue(s.start.isFinite && s.start >= 0, "start \(start) -> \(s.start) not sane")
            XCTAssertTrue(s.yValue.isFinite && (0...100).contains(s.yValue), "yValue \(y) -> \(s.yValue) not sane")
            XCTAssertTrue((1...23).contains(s.curve), "curve \(curve) -> \(s.curve) not sane")
        }
    }

    func testSanitizedPreservesAlreadyValidValues() {
        var ok = CuePoint.makeDefault(at: 5, name: "ok")
        ok.yValue = 42; ok.curve = 7
        let s = ok.sanitized()
        XCTAssertEqual(s.start, 5)
        XCTAssertEqual(s.yValue, 42)
        XCTAssertEqual(s.curve, 7)
    }

    func testSanitizedPreservesUnicodeAndEmptyNames() {
        for name in ["", "Düsseldorf Örgü 🎧", "日本語キューポイント", String(repeating: "a", count: 500)] {
            let c = CuePoint.makeDefault(at: 1, name: name).sanitized()
            XCTAssertEqual(c.name, name, "sanitized() must not mutate the name field")
        }
    }
}

final class TrackTests: XCTestCase {
    private func track(totalTime: Int) -> Track {
        Track(id: "1", name: "n", artist: "a", album: "", genre: "", totalTime: totalTime, bpm: 0, tonality: "", location: "", cuePoints: [])
    }

    func testFormattedDurationForOrdinaryLength() {
        XCTAssertEqual(track(totalTime: 125).formattedDuration, "2:05")
    }

    func testFormattedDurationForZeroLength() {
        XCTAssertEqual(track(totalTime: 0).formattedDuration, "0:00")
    }

    func testFormattedDurationClampsNegativeLength() {
        XCTAssertEqual(track(totalTime: -5).formattedDuration, "0:00")
    }

    func testFormattedDurationDoesNotUseLocaleSensitiveSeparators() {
        // Guards against a `String(format:)` regression that could format seconds with a
        // locale decimal/grouping separator instead of a fixed `M:SS` — output must be
        // byte-identical regardless of the host's locale (export/UI parity, spec §3).
        let formatted = track(totalTime: 3725).formattedDuration
        XCTAssertEqual(formatted, "62:05")
        XCTAssertFalse(formatted.contains(","), "no thousands separator should ever appear")
    }
}

final class PlaylistTests: XCTestCase {
    func testLeafPlaylistTrackCount() {
        let leaf = Playlist(id: "p1", name: "P", type: .playlist, trackIds: ["a", "b", "c"], children: [])
        XCTAssertEqual(leaf.totalTrackCount(), 3)
    }

    func testFolderRecursesIntoChildren() {
        let leaf = Playlist(id: "p1", name: "P", type: .playlist, trackIds: ["a", "b", "c"], children: [])
        let folder = Playlist(id: "f1", name: "F", type: .folder, trackIds: [], children: [leaf])
        XCTAssertEqual(folder.totalTrackCount(), 3)
    }

    func testEmptyFolderCountsZero() {
        let folder = Playlist(id: "f1", name: "F", type: .folder, trackIds: [], children: [])
        XCTAssertEqual(folder.totalTrackCount(), 0)
    }

    func testDeeplyNestedFoldersRecurseCorrectly() {
        var node = Playlist(id: "leaf", name: "Leaf", type: .playlist, trackIds: ["x", "y"], children: [])
        for depth in 0..<20 {
            node = Playlist(id: "f\(depth)", name: "F\(depth)", type: .folder, trackIds: [], children: [node])
        }
        XCTAssertEqual(node.totalTrackCount(), 2)
    }
}

final class ProjectCodableTests: XCTestCase {
    func testPartialJSONDecodesWithDefaultsInsteadOfThrowing() throws {
        let json = Data("{\"name\":\"Partial\"}".utf8)
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.name, "Partial")
        XCTAssertEqual(p.trackDuration, 60.0)
        XCTAssertEqual(p.presetName, "New Envelope")
        XCTAssertTrue(p.cuePoints.isEmpty)
    }

    func testEmptyObjectDecodesWithAllDefaults() throws {
        let json = Data("{}".utf8)
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.name, "Untitled Project")
        XCTAssertEqual(p.version, "3.0")
        XCTAssertTrue(p.tracks.isEmpty)
        XCTAssertTrue(p.playlists.isEmpty)
    }

    func testRoundTripPreservesCuePointsAndDuration() throws {
        var p = Project()
        p.name = "RT"
        p.cuePoints = [CuePoint.makeDefault(at: 0, name: "S"), CuePoint.makeDefault(at: 60, name: "E")]
        p.trackDuration = 90
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.name, "RT")
        XCTAssertEqual(back.cuePoints.count, 2)
        XCTAssertEqual(back.trackDuration, 90)
    }

    func testRoundTripPreservesUnicodeNamesAndEmbeddedCRLF() throws {
        // Windows-authored project files may carry CRLF inside free-text fields (track/cue
        // names, preset name); JSON string encoding must round-trip them byte-for-byte.
        var p = Project()
        p.name = "日本語 Ω café\r\nLine2"
        p.presetName = "Envelope™ 🎛️"
        p.cuePoints = [CuePoint.makeDefault(at: 0, name: "emoji 🎧\ttab")]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.name, p.name)
        XCTAssertEqual(back.presetName, p.presetName)
        XCTAssertEqual(back.cuePoints.first?.name, "emoji 🎧\ttab")
    }

    func testRoundTripWithEmptyCollectionsStaysEmpty() throws {
        let p = Project()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertTrue(back.tracks.isEmpty)
        XCTAssertTrue(back.playlists.isEmpty)
        XCTAssertTrue(back.cuePoints.isEmpty)
    }

    func testMalformedJSONThrowsRatherThanCrashing() {
        let malformed = Data("{not valid json".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: malformed))
    }

    func testSampleProjectFixtureDecodes() throws {
        let data = try Samples.data("sample-project.cueproj")
        let project = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertFalse(project.presetName.isEmpty)
        XCTAssertGreaterThan(project.trackDuration, 0)
    }
}
