import Foundation
import XCTest
@testable import CueSyncCore

final class EngineDJParserTests: XCTestCase {
    func testMissingDatabaseThrows() {
        let dir = Scratch.makeDirectory("enginedj-missing")
        XCTAssertThrowsError(try EngineDJParser.parse(databaseURL: dir.appendingPathComponent("does-not-exist.db")))
    }

    #if canImport(SQLite3)

    func testTwoTracksLoadWithTitleFallbackAndKeyMapping() throws {
        let dir = Scratch.makeDirectory("enginedj-good")
        let url = dir.appendingPathComponent("engine-good.db")
        EngineDJFixtures.good(at: url)
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertEqual(tracks.count, 2)
        guard tracks.count == 2 else { return }
        XCTAssertEqual(tracks[0].name, "Test Title", "title used as name")
        XCTAssertEqual(tracks[0].tonality, "C", "key code 1 maps to C")
        XCTAssertEqual(tracks[1].name, "fallback.wav", "filename used when title empty")
        for t in tracks { assertSaneCues(t.cuePoints, "enginedj-good/\(t.name)") }
    }

    func testDatabaseMissingPerformanceDataTableThrows() {
        let dir = Scratch.makeDirectory("enginedj-no-perf")
        let url = dir.appendingPathComponent("engine-no-perf.db")
        EngineDJFixtures.missingPerformanceTable(at: url)
        XCTAssertThrowsError(try EngineDJParser.parse(databaseURL: url))
    }

    func testDatabaseWithEmptyTrackTableThrowsNoData() {
        let dir = Scratch.makeDirectory("enginedj-empty")
        let url = dir.appendingPathComponent("engine-empty.db")
        EngineDJFixtures.empty(at: url)
        XCTAssertThrowsError(try EngineDJParser.parse(databaseURL: url))
    }

    func testNonSQLiteFileThrowsInsteadOfCrashing() {
        let dir = Scratch.makeDirectory("enginedj-corrupt")
        let url = dir.appendingPathComponent("engine-corrupt.db")
        EngineDJFixtures.corruptFile(at: url)
        XCTAssertThrowsError(try EngineDJParser.parse(databaseURL: url))
    }

    func testGarbageQuickCuesBlobLoadsTrackWithNoCuesInsteadOfCrashing() throws {
        // declaredSize (100) is plausible but the "compressed" bytes are garbage —
        // zlib inflate must fail cleanly, not crash (threat model §4).
        let dir = Scratch.makeDirectory("enginedj-badblob")
        let url = dir.appendingPathComponent("engine-badblob.db")
        EngineDJFixtures.badBlob(at: url, declaredSize: 100,
                                  compressedGarbage: [0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty, "track must still be returned despite a bad blob")
        for t in tracks { assertSaneCues(t.cuePoints, "enginedj-badblob") }
    }

    /// Decompression-bomb guard (spec §4): the declared uncompressed size comes from the
    /// first 4 untrusted bytes of the blob and must never drive an unbounded allocation.
    /// A blob that declares an implausibly large size must be rejected outright — the
    /// track still loads, just with no cues — never crash or allocate gigabytes.
    func testOversizedDeclaredUncompressedSizeIsRejectedNotAllocated() throws {
        let dir = Scratch.makeDirectory("enginedj-bomb")
        let url = dir.appendingPathComponent("engine-bomb.db")
        EngineDJFixtures.badBlob(at: url, declaredSize: 0xFFFF_FFFF,
                                  compressedGarbage: [UInt8](repeating: 0x00, count: 16))
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty, "track must still be returned")
        for t in tracks { XCTAssertTrue(t.cuePoints.isEmpty, "an implausible declared size must yield no cues") }
    }

    func testDeclaredSizeExactlyAtTheCapBoundaryIsRejected() throws {
        // The cap is `uncompressedSize < 1_000_000`; a declared size of exactly one million
        // must be treated the same as "too large" (boundary is exclusive).
        let dir = Scratch.makeDirectory("enginedj-bomb-boundary")
        let url = dir.appendingPathComponent("engine-bomb-boundary.db")
        EngineDJFixtures.badBlob(at: url, declaredSize: 1_000_000,
                                  compressedGarbage: [UInt8](repeating: 0x00, count: 16))
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty)
        for t in tracks { XCTAssertTrue(t.cuePoints.isEmpty, "declared size == cap must be rejected") }
    }

    func testZeroDeclaredSizeYieldsNoCuesNotACrash() throws {
        let dir = Scratch.makeDirectory("enginedj-zero-size")
        let url = dir.appendingPathComponent("engine-zero-size.db")
        EngineDJFixtures.badBlob(at: url, declaredSize: 0, compressedGarbage: [0x01, 0x02])
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty)
        for t in tracks { XCTAssertTrue(t.cuePoints.isEmpty) }
    }

    #else

    /// On a platform where SQLite3 is unavailable (no vendored CSQLite yet — spec item
    /// B.7 / A.2), the parser must fail closed with a clear error instead of crashing or
    /// silently returning an empty result that looks like "no cues found".
    func testParseFailsClosedWhenSQLite3IsUnavailable() {
        let dir = Scratch.makeDirectory("enginedj-nosqlite")
        XCTAssertThrowsError(try EngineDJParser.parse(databaseURL: dir.appendingPathComponent("m.db")))
    }

    #endif
}
