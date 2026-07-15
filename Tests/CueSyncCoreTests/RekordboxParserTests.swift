import Foundation
import XCTest
@testable import CueSyncCore

final class RekordboxParserTests: XCTestCase {
    func testSampleFixtureParsesWithSaneCues() throws {
        let xml = try Samples.string("sample-rekordbox.xml")
        let result = try RekordboxParser.parse(xml: xml)
        XCTAssertFalse(result.tracks.isEmpty, "sample fixture should contain tracks")
        for t in result.tracks { assertSaneCues(t.cuePoints, "rekordbox-sample/\(t.name)") }
    }

    func testRealLibraryFixtureParsesManyTracksWithSortedCues() throws {
        let xml = try Samples.string("real-rekordbox-library.xml")
        let result = try RekordboxParser.parse(xml: xml)
        XCTAssertGreaterThan(result.tracks.count, 1, "real library fixture should contain many tracks")
        for t in result.tracks {
            assertSaneCues(t.cuePoints, "rekordbox-real/\(t.name)")
            let starts = t.cuePoints.map(\.start)
            XCTAssertEqual(starts, starts.sorted(), "cues must be sorted ascending for \(t.name)")
        }
    }

    func testMalformedNumericAttributesProduceSaneCuesNotCrashes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="1">
            <TRACK TrackID="1" Name="Bad" TotalTime="abc" AverageBpm="xyz">
              <POSITION_MARK Name="n" Type="0" Start="nan" Num="0"/>
              <POSITION_MARK Name="i" Type="0" Start="inf" Num="1"/>
              <POSITION_MARK Name="neg" Type="0" Start="-50" Num="2"/>
              <POSITION_MARK Name="huge" Type="0" Start="1e30" Num="3"/>
            </TRACK>
          </COLLECTION>
        </DJ_PLAYLISTS>
        """
        let result = try RekordboxParser.parse(xml: xml)
        for t in result.tracks {
            assertSaneCues(t.cuePoints, "rekordbox-malformed/\(t.name)")
            XCTAssertGreaterThanOrEqual(t.totalTime, 0)
            XCTAssertTrue(t.bpm.isFinite)
        }
    }

    func testUnicodeTrackAndCueNamesSurviveParsing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="1">
            <TRACK TrackID="1" Name="日本語トラック 🎧" Artist="Ünïcödé Ärtïst" TotalTime="120" AverageBpm="128">
              <POSITION_MARK Name="Intro™" Type="0" Start="0" Num="0"/>
            </TRACK>
          </COLLECTION>
        </DJ_PLAYLISTS>
        """
        let result = try RekordboxParser.parse(xml: xml)
        XCTAssertEqual(result.tracks.first?.name, "日本語トラック 🎧")
        XCTAssertEqual(result.tracks.first?.artist, "Ünïcödé Ärtïst")
        XCTAssertEqual(result.tracks.first?.cuePoints.first?.name, "Intro™")
    }

    func testEmptyCollectionParsesToNoTracksWithoutThrowing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="0"></COLLECTION></DJ_PLAYLISTS>
        """
        let result = try RekordboxParser.parse(xml: xml)
        XCTAssertTrue(result.tracks.isEmpty)
    }

    func testNonXMLInputThrows() {
        XCTAssertThrowsError(try RekordboxParser.parse(xml: "this is not xml < & >"))
    }

    func testEmptyStringInputThrows() {
        XCTAssertThrowsError(try RekordboxParser.parse(xml: ""))
    }

    func testFuzzedMutationsOfSampleNeverProduceInsaneCues() throws {
        var rng = XorShift64(seed: 0xCAFE)
        let base = try Samples.string("sample-rekordbox.xml")
        let baseBytes = Array(base.utf8)
        for _ in 0..<150 {
            var bytes = baseBytes
            let flips = Int(rng.next() % 30)
            for _ in 0..<flips where !bytes.isEmpty {
                bytes[Int(rng.next() % UInt64(bytes.count))] = rng.byte()
            }
            let s = String(decoding: bytes, as: UTF8.self)
            if let r = try? RekordboxParser.parse(xml: s) {
                for t in r.tracks { assertSaneCues(t.cuePoints, "rekordbox-fuzz") }
            }
        }
    }
}
