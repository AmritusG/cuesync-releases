import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Builds Engine DJ SQLite fixtures in-process via the SQLite3 C API (parameterised
// inserts, no string-built SQL) instead of shelling out to the `sqlite3` CLI, so the
// test target is self-contained on windows-latest, which has no `sqlite3` binary on
// PATH by default (spec item E.28). SQLite is always available — Apple's system
// module on Darwin, the vendored CSQLite target everywhere else — so these fixtures
// compile and run identically on every platform.
enum EngineDJFixtures {

    private static let trackDDL =
        "CREATE TABLE Track(id INTEGER PRIMARY KEY, title TEXT, artist TEXT, album TEXT, genre TEXT, length INTEGER, bpmAnalyzed REAL, key INTEGER, path TEXT, filename TEXT);"

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            XCTFail("fixture SQL failed: \(message)\n\(sql)")
        }
    }

    private static func insertTrack(_ db: OpaquePointer?, id: Int64, title: String, artist: String,
                                     album: String, genre: String, length: Int, bpm: Double,
                                     key: Int, path: String, filename: String) {
        let sql = "INSERT INTO Track VALUES(?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("prepare insertTrack failed"); return
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_bind_text(stmt, 2, title, -1, transient)
        sqlite3_bind_text(stmt, 3, artist, -1, transient)
        sqlite3_bind_text(stmt, 4, album, -1, transient)
        sqlite3_bind_text(stmt, 5, genre, -1, transient)
        sqlite3_bind_int(stmt, 6, Int32(length))
        sqlite3_bind_double(stmt, 7, bpm)
        sqlite3_bind_int(stmt, 8, Int32(key))
        sqlite3_bind_text(stmt, 9, path, -1, transient)
        sqlite3_bind_text(stmt, 10, filename, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { XCTFail("insertTrack step failed") ; return }
    }

    private static func insertPerformanceBlob(_ db: OpaquePointer?, trackId: Int64, blob: [UInt8]) {
        let sql = "INSERT INTO PerformanceData VALUES(?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("prepare insertPerformanceBlob failed"); return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, trackId)
        blob.withUnsafeBufferPointer { buf in
            sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { XCTFail("insertPerformanceBlob step failed"); return }
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            XCTFail("could not create fixture db at \(url.path)")
            return nil
        }
        return db
    }

    /// Two tracks, one PerformanceData row present but empty — no quickCues blob.
    static func good(at url: URL) {
        guard let db = open(url) else { return }
        defer { sqlite3_close(db) }
        exec(db, trackDDL)
        insertTrack(db, id: 1, title: "Test Title", artist: "Test Artist", album: "Album", genre: "Genre",
                    length: 180, bpm: 128.0, key: 1, path: "/Music/", filename: "track.mp3")
        insertTrack(db, id: 2, title: "", artist: "", album: "", genre: "", length: 0, bpm: 0.0,
                    key: 0, path: "", filename: "fallback.wav")
        exec(db, "CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);")
    }

    /// Track table only — PerformanceData missing entirely.
    static func missingPerformanceTable(at url: URL) {
        guard let db = open(url) else { return }
        defer { sqlite3_close(db) }
        exec(db, trackDDL)
        insertTrack(db, id: 1, title: "X", artist: "", album: "", genre: "", length: 60, bpm: 120.0,
                    key: 1, path: "/m/", filename: "a.mp3")
    }

    /// Both tables exist, no rows in Track.
    static func empty(at url: URL) {
        guard let db = open(url) else { return }
        defer { sqlite3_close(db) }
        exec(db, trackDDL)
        exec(db, "CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);")
    }

    /// A quickCues BLOB whose declared uncompressed size cannot possibly match its
    /// (tiny) compressed payload — must decompress to nil, never crash.
    static func badBlob(at url: URL, declaredSize: UInt32, compressedGarbage: [UInt8]) {
        guard let db = open(url) else { return }
        defer { sqlite3_close(db) }
        exec(db, trackDDL)
        insertTrack(db, id: 1, title: "Blobby", artist: "", album: "", genre: "", length: 90, bpm: 120.0,
                    key: 1, path: "/m/", filename: "b.mp3")
        exec(db, "CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);")
        // parseCueBlob reads bytes 0-3 as a little-endian uint32 declared size.
        let le: [UInt8] = [
            UInt8(truncatingIfNeeded: declaredSize),
            UInt8(truncatingIfNeeded: declaredSize >> 8),
            UInt8(truncatingIfNeeded: declaredSize >> 16),
            UInt8(truncatingIfNeeded: declaredSize >> 24),
        ]
        insertPerformanceBlob(db, trackId: 1, blob: le + compressedGarbage)
    }

    /// Not a SQLite file at all — 64 deterministic pseudo-random bytes.
    static func corruptFile(at url: URL) {
        var rng = XorShift64(seed: 0xC0FF_EE00)
        try? Data(rng.bytes(64)).write(to: url)
    }
}
