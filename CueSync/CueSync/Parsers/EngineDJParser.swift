import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// parser via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see Models/CuePoint.swift.
public enum EngineDJParser {

    // MARK: - Public

    /// Default database location: ~/Music/Engine Library/Database2/m.db
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Engine Library/Database2/m.db")
    }

    /// Parse an Engine DJ SQLite database and return all tracks with their cue points.
    public static func parse(databaseURL: URL) throws -> [Track] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ParseError.invalidFormat("Engine DJ database not found at \(databaseURL.path)")
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ParseError.invalidFormat("Could not open Engine DJ database: \(msg)")
        }
        defer { sqlite3_close(db) }

        // Verify required tables exist
        try verifyTable("Track", in: db)
        try verifyTable("PerformanceData", in: db)

        // Load tracks
        var tracks = try loadTracks(from: db)
        if tracks.isEmpty {
            throw ParseError.noData
        }

        // Build lookup by engine ID for fast matching
        var trackIndexByEngineId: [Int64: Int] = [:]
        for (index, _) in tracks.enumerated() {
            if let engineId = Int64(tracks[index].id.replacingOccurrences(of: "engine-", with: "")) {
                trackIndexByEngineId[engineId] = index
            }
        }

        // Load and attach cue points
        try loadCuePoints(into: &tracks, lookup: trackIndexByEngineId, from: db)

        return tracks
    }

    // MARK: - Track Loading

    private static func loadTracks(from db: OpaquePointer) throws -> [Track] {
        let sql = "SELECT id, title, artist, album, genre, length, bpmAnalyzed, key, path, filename FROM Track"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ParseError.invalidFormat("Failed to query Track table: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var tracks: [Track] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let title = SQLiteSupport.columnText(stmt, 1)
            let artist = SQLiteSupport.columnText(stmt, 2)
            let album = SQLiteSupport.columnText(stmt, 3)
            let genre = SQLiteSupport.columnText(stmt, 4)
            let length = Int(sqlite3_column_int(stmt, 5))
            let bpm = sqlite3_column_double(stmt, 6)
            let keyCode = Int(sqlite3_column_int(stmt, 7))
            let path = SQLiteSupport.columnText(stmt, 8)
            let filename = SQLiteSupport.columnText(stmt, 9)

            let trackName: String
            if !title.isEmpty {
                trackName = title
            } else if !filename.isEmpty {
                trackName = filename
            } else {
                trackName = "Unknown"
            }

            let track = Track(
                id: "engine-\(rowId)",
                name: trackName,
                artist: artist,
                album: album,
                genre: genre,
                totalTime: length,
                bpm: bpm,
                tonality: mapKeyCodeToName(keyCode),
                location: path + filename,
                cuePoints: []
            )
            tracks.append(track)
        }

        return tracks
    }

    // MARK: - Cue Point Loading

    private static func loadCuePoints(
        into tracks: inout [Track],
        lookup: [Int64: Int],
        from db: OpaquePointer
    ) throws {
        let sql = "SELECT trackId, quickCues FROM PerformanceData"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // PerformanceData query failed - not fatal, tracks just have no cues
            return
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let trackId = sqlite3_column_int64(stmt, 0)

            guard let trackIndex = lookup[trackId] else { continue }

            // Read quickCues BLOB
            guard sqlite3_column_type(stmt, 1) == SQLITE_BLOB,
                  let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let blobSize = Int(sqlite3_column_bytes(stmt, 1))
            guard blobSize > 4 else { continue }

            let blobData = Data(bytes: blobPtr, count: blobSize)

            // Parse cue points from the compressed blob
            if let cuePoints = parseCueBlob(blobData) {
                tracks[trackIndex].cuePoints = cuePoints.sorted { $0.start < $1.start }
            }
        }
    }

    // MARK: - BLOB Parsing

    /// Parse the quickCues BLOB:
    /// Bytes 0-3: uncompressed size (little-endian uint32)
    /// Bytes 4+: zlib-compressed data
    private static func parseCueBlob(_ data: Data) -> [CuePoint]? {
        guard data.count > 4 else { return nil }

        // Read uncompressed size (little-endian uint32). loadUnaligned avoids a
        // "load from misaligned raw pointer" trap if the Data isn't 4-byte aligned.
        let uncompressedSize: UInt32 = data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }

        // Decompression-bomb guard (threat model §4): this size comes from the
        // untrusted blob itself and must never be trusted unbounded.
        guard uncompressedSize > 0, uncompressedSize < 1_000_000 else { return nil }

        // Decompress raw-DEFLATE data via the cross-platform Support/Zlib helper
        // (Apple Compression on Darwin, vendored CZlib elsewhere). The cap is the
        // declared size plus slack, never the compressed length, so a hostile
        // blob can't drive an allocation larger than the sanity gate above allows.
        let compressed = data.subdata(in: 4..<data.count)
        guard let decompressed = Zlib.inflate(compressed, cap: Int(uncompressedSize) + 256) else {
            return nil
        }

        return parseCueSlots(decompressed)
    }

    /// Parse decompressed cue data:
    /// 8-byte header (last byte = number of cue slots)
    /// Then up to 8 cue slots
    private static func parseCueSlots(_ data: Data) -> [CuePoint] {
        guard data.count > 8 else { return [] }

        let bytes = [UInt8](data)
        var cuePoints: [CuePoint] = []
        var pos = 8 // Skip 8-byte header
        var cueIndex = 0

        while pos < bytes.count - 12 && cueIndex < 8 {
            let nameLen = Int(bytes[pos])

            if nameLen == 0 {
                // Empty slot - skip 13 bytes total (1 nameLen + 8 position + 4 padding)
                pos += 13
                cueIndex += 1
                continue
            }

            // Read name
            let nameStart = pos + 1
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else { break }

            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8)
                ?? "Cue \(cueIndex + 1)"
            pos = nameEnd

            // Read position as big-endian float64 (samples at 44100 Hz)
            guard pos + 8 <= bytes.count else { break }
            let positionSamples = readBigEndianFloat64(bytes, offset: pos)
            let positionSeconds = positionSamples / 44100.0
            pos += 8

            // Skip 4 unknown/padding bytes
            pos += 4

            // positionSeconds comes from raw float64 bits, so it may be NaN/Inf/negative;
            // sanitized() guarantees a finite, non-negative start. (max(.nan, 0) is .nan.)
            let cue = CuePoint(
                id: UUID().uuidString,
                start: positionSeconds,
                name: name.isEmpty ? "Cue \(cueIndex + 1)" : name,
                color: cueColors[cueIndex % cueColors.count],
                yValue: 100.0,
                curve: 1,
                enabled: true
            ).sanitized()
            cuePoints.append(cue)
            cueIndex += 1
        }

        return cuePoints
    }

    // MARK: - Binary Helpers

    private static func readBigEndianFloat64(_ bytes: [UInt8], offset: Int) -> Double {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return Double(bitPattern: value)
    }

    private static func verifyTable(_ name: String, in db: OpaquePointer) throws {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ParseError.invalidFormat("Could not query database schema")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw ParseError.invalidFormat("Engine DJ database is missing the \(name) table")
        }
    }

    // MARK: - Engine DJ Cue Colors

    private static let cueColors: [String] = [
        "#F4D338", // 0: Yellow
        "#EF8130", // 1: Orange
        "#AA55C4", // 2: Purple
        "#CE3239", // 3: Red
        "#86C64B", // 4: Green
        "#20C670", // 5: Teal
        "#00A8A9", // 6: Cyan
        "#1571E2", // 7: Blue
    ]

    // MARK: - Key Mapping

    /// Map Engine DJ numeric key codes to musical key names.
    /// Engine DJ uses a sequential numbering: 1-24 covering all major/minor keys
    /// in Camelot wheel order.
    private static func mapKeyCodeToName(_ code: Int) -> String {
        // Engine DJ key codes: 1-24
        // Mapping follows the standard Engine DJ key numbering
        switch code {
        case 1:  return "C"         // 8B  - C Major
        case 2:  return "Db"        // 3B  - Db Major
        case 3:  return "D"         // 10B - D Major
        case 4:  return "Eb"        // 5B  - Eb Major
        case 5:  return "E"         // 12B - E Major
        case 6:  return "F"         // 7B  - F Major
        case 7:  return "Gb"        // 2B  - Gb Major
        case 8:  return "G"         // 9B  - G Major
        case 9:  return "Ab"        // 4B  - Ab Major
        case 10: return "A"         // 11B - A Major
        case 11: return "Bb"        // 6B  - Bb Major
        case 12: return "B"         // 1B  - B Major
        case 13: return "Cm"        // 5A  - C Minor
        case 14: return "Dbm"       // 12A - Db Minor
        case 15: return "Dm"        // 7A  - D Minor
        case 16: return "Ebm"       // 2A  - Eb Minor
        case 17: return "Em"        // 9A  - E Minor
        case 18: return "Fm"        // 4A  - F Minor
        case 19: return "Gbm"       // 11A - Gb Minor
        case 20: return "Gm"        // 6A  - G Minor
        case 21: return "Abm"       // 1A  - Ab Minor
        case 22: return "Am"        // 8A  - A Minor
        case 23: return "Bbm"       // 3A  - Bb Minor
        case 24: return "Bm"        // 10A - B Minor
        default: return ""
        }
    }
}
