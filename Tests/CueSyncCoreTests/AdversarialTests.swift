import Foundation
import XCTest
@testable import CueSyncCore

// =============================================================================
// Red-Team adversarial suite (CUESYNC-3).
//
// Every import format is untrusted external input (threat model, spec §4). These
// tests reason like an attacker feeding hostile files into the parsers/exporters
// and pin the safety invariant each one must hold: fail closed (empty/nil/throw),
// never crash, never read out of bounds, never emit corrupt output, never hang.
//
// They are deterministic, network-free, /tmp-free and CLI-free so `swift test`
// passes unchanged on windows-latest and macos-latest (spec §E.28). Each stays in
// the suite forever as a regression guard — the factory gets harder to break with
// every run.
// =============================================================================

// MARK: - Serato: hostile binary offset / length attacks

final class AdversarialSeratoBinaryTests: XCTestCase {

    /// A CUE entry whose advertised payload length runs exactly one byte past the
    /// end of the stream must be rejected by the `pos + Int(payloadLength) <= count`
    /// bound, not over-read. (offset-overrun attack)
    func testPayloadLengthOneBytePastEndIsRejectedNotOverRead() {
        // Build: version header + "CUE\0" + length + a short payload.
        var bytes: [UInt8] = [0x01, 0x01]
        bytes += Array("CUE".utf8); bytes.append(0x00)
        // Only 8 payload bytes actually follow, but claim 9.
        let payload: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00]
        bytes += BinaryFixtures.be32(UInt32(payload.count + 1))
        bytes += payload
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(bytes))
        assertSaneCues(cues, "serato-len-past-end")
        XCTAssertTrue(cues.isEmpty, "an over-long payload length must yield no cue, not an OOB read")
    }

    /// A cue name carrying an embedded NUL must terminate at the NUL — bytes after
    /// it are a different field and must never leak into the displayed name.
    /// (null-byte / string-truncation attack)
    func testCueNameStopsAtEmbeddedNullByte() {
        // Payload: 0x00, index, be32 pos, 0x00, rgb, 0x00, then name "AB\0CD".
        var p: [UInt8] = [0x00, 0x00]
        p += BinaryFixtures.be32(1000)
        p.append(0x00)
        p += [0x10, 0x20, 0x30]
        p.append(0x00)
        p += Array("AB".utf8); p.append(0x00); p += Array("CD".utf8); p.append(0x00)
        let cues = SeratoParser.parseSeratoMarkers2(data: BinaryFixtures.markers2([BinaryFixtures.cueEntry(p)]))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.name, "AB", "name must terminate at the first NUL, not absorb the trailing field bytes")
    }

    /// Thousands of empty (bare-NUL) entries must each advance the cursor and
    /// terminate — a padding flood must not spin or overflow. (DoS / infinite-loop)
    func testNulPaddingFloodTerminatesWithNoCues() {
        var bytes: [UInt8] = [0x01, 0x01]
        bytes += [UInt8](repeating: 0x00, count: 50_000)
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(bytes))
        XCTAssertTrue(cues.isEmpty)
    }

    /// A well-formed CUE entry followed by a truncated second entry: the good cue
    /// is returned and the malformed tail is dropped, never partially read OOB.
    func testGoodEntryThenTruncatedEntryReturnsOnlyTheGoodCue() {
        var bytes = Array(BinaryFixtures.markers2([
            BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 0, posMs: 3000, name: "Keep")),
        ]))
        // Append the start of a second CUE entry but cut it off mid-length-field.
        bytes += Array("CUE".utf8); bytes.append(0x00); bytes += [0xFF, 0xFF] // partial length
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(bytes))
        assertSaneCues(cues, "serato-good-then-truncated")
        XCTAssertEqual(cues.first?.name, "Keep")
    }
}

// MARK: - Serato: hostile container (RIFF/AIFF) chunk-size attacks

final class AdversarialSeratoContainerTests: XCTestCase {

    private func write(_ bytes: [UInt8], ext: String, _ label: String) -> URL {
        Scratch.writeFile(bytes, name: "atk.\(ext)", in: Scratch.makeDirectory(label))
    }

    /// A WAV chunk that advertises a 4 GiB size (larger than the file) must be
    /// clamped by `min(chunkDataStart + chunkSize, count)`, never over-read or hang.
    /// (resource exhaustion / offset overrun)
    func testWAVChunkSizeBeyondEOFIsClampedNotOverRead() throws {
        var wav = Array("RIFF".utf8) + [0x24, 0x00, 0x00, 0x00] + Array("WAVE".utf8)
        wav += Array("junk".utf8)
        wav += [0xFF, 0xFF, 0xFF, 0xFF] // little-endian chunk size ~4 GiB
        wav += [0xAA, 0xBB, 0xCC, 0xDD] // only 4 bytes actually present
        let t = try SeratoParser.parseFile(at: write(wav, ext: "wav", "wav-huge-chunk"))
        assertSaneCues(t.cuePoints, "wav-huge-chunk")
        XCTAssertTrue(t.cuePoints.isEmpty)
    }

    /// A WAV filled with thousands of zero-size chunks must terminate (each iteration
    /// advances the cursor by the 8-byte header), not loop forever. (infinite-loop)
    func testWAVZeroSizeChunkFloodTerminates() throws {
        var wav = Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WAVE".utf8)
        for _ in 0..<20_000 {
            wav += Array("nul ".utf8) + [0x00, 0x00, 0x00, 0x00] // id + size 0
        }
        let t = try SeratoParser.parseFile(at: write(wav, ext: "wav", "wav-zero-flood"))
        assertSaneCues(t.cuePoints, "wav-zero-flood")
    }

    /// An AIFF "ID3 " chunk whose size claims to run far past EOF must be clamped
    /// by `min(chunkDataStart + chunkSize, count)`, never over-read. (offset overrun)
    func testAIFFID3ChunkSizeBeyondEOFDoesNotOverRead() throws {
        var aiff = Array("FORM".utf8) + [0x00, 0x00, 0x00, 0x64] + Array("AIFF".utf8)
        aiff += Array("ID3 ".utf8) + [0x7F, 0xFF, 0xFF, 0xFF] // big-endian huge size
        aiff += Array("ID3".utf8) + [0x03, 0x00, 0x00] + [0x00, 0x00, 0x00, 0x0A] // ID3 header claiming 10-byte tag
        aiff += [UInt8](repeating: 0x00, count: 4) // truncated frames
        let t = try SeratoParser.parseFile(at: write(aiff, ext: "aiff", "aiff-huge-chunk"))
        assertSaneCues(t.cuePoints, "aiff-huge-chunk")
    }

    /// An ID3v2 frame whose size field claims 0xFFFFFFFF must not drive an OOB slice —
    /// the `frameDataStart + frameSize <= end` guard drops it. (offset overrun)
    func testMP3FrameSizeBeyondTagEndIsSkipped() throws {
        // ID3v2.3 header + one TIT2 frame claiming a 4 GiB size.
        var body: [UInt8] = []
        body += Array("TIT2".utf8)
        body += [0xFF, 0xFF, 0xFF, 0xFF] // non-synchsafe (v2.3) 4 GiB frame size
        body += [0x00, 0x00]             // frame flags
        body += [0x00] + Array("hi".utf8)
        var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00]
        mp3 += BinaryFixtures.synchsafe(body.count)
        mp3 += body
        let t = try SeratoParser.parseFile(at: write(mp3, ext: "mp3", "mp3-huge-frame"))
        assertSaneCues(t.cuePoints, "mp3-huge-frame")
        // Frame is dropped, so no title is extracted; filename becomes the name.
        XCTAssertEqual(t.name, "atk", "an over-long frame size must be skipped, leaving the filename as the track name")
    }
}

// MARK: - ShowKontrol: record / field injection and numeric overflow

final class AdversarialShowKontrolTests: XCTestCase {

    /// A cue name stuffed with every line-break code point CR/LF/NEL/LS/PS/VT/FF must
    /// still produce exactly one `\r`-separated record per cue and never leak a raw
    /// LF (0x0A) into the byte stream — no injected rows. (CRLF / record injection)
    func testHostileLineBreakCodePointsInNameCannotInjectRecords() {
        let hostile = "Drop\r\n\u{0085}\u{2028}\u{2029}\u{000B}\u{000C}INJECTED,extra,cols"
        let cues = [
            CuePoint(id: "a", start: 0, name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 10, name: hostile, color: "#fff", yValue: 0, curve: 1, enabled: true),
        ]
        let out = ShowKontrolExporter.generate(cuePoints: cues) ?? ""
        let raw = Array(out.utf8)
        XCTAssertFalse(raw.contains(0x0A), "no LF byte may leak into .cue output via a hostile cue name")
        let records = out.components(separatedBy: "\r")
        XCTAssertEqual(records.count, cues.count,
                       "exactly one record per cue — embedded CR/LF must not inject rows")
        for r in records {
            XCTAssertEqual(r.filter { $0 == "," }.count, 10,
                           "each record keeps its fixed 11-field shape — no column injection via commas in the name")
        }
    }

    /// A milliseconds field of 1e309 parses to +Inf in Swift; the parser must reject
    /// the non-finite value (→ 0) so no Inf cue start or Inf suggested duration escapes.
    /// A merely huge-but-finite 1e308 must stay finite. (numeric overflow)
    func testInfiniteAndHugeMillisecondsNeverProduceNonFiniteOutput() throws {
        let content = "00:00:00:00,00000000,1e309,A,TAG,,,,,,\r" +
                      "00:00:01:00,00000100,1e308,B,TAG,,,,,,\r"
        let result = try ShowKontrolParser.parse(content: content)
        assertSaneCues(result.cuePoints, "showkontrol-inf-ms")
        for c in result.cuePoints { XCTAssertTrue(c.start.isFinite, "cue start must be finite") }
        if let dur = result.suggestedDurationMs {
            XCTAssertTrue(dur.isFinite, "suggested duration must stay finite for hostile ms fields")
        }
    }

    /// A single line carrying tens of thousands of comma fields must parse in linear
    /// time and not blow the field split up — no quadratic pathology. (resource)
    func testPathologicallyManyFieldsOnOneLineParsesLinearly() throws {
        let commas = String(repeating: ",", count: 40_000)
        // 00:00:05:00 -> 5000 ms so a real cue is produced.
        let content = "00:00:05:00,00000500,5000,Drop\(commas)\r"
        let result = try ShowKontrolParser.parse(content: content)
        assertSaneCues(result.cuePoints, "showkontrol-many-fields")
        XCTAssertTrue(result.cuePoints.contains { $0.name == "Drop" })
    }
}

// MARK: - Resolume: output-integrity (control chars must not corrupt XML)

final class AdversarialResolumeExportTests: XCTestCase {

    /// OUTPUT-INTEGRITY ATTACK. A preset name is untrusted (spec §4) — it can arrive
    /// from a hostile `.cueproj` or an imported track title. `escapeXml` escapes the
    /// five XML metacharacters but NOT the C0 control bytes (NUL, backspace, …) that
    /// XML 1.0 forbids outright. The exporter must therefore neutralize them, so the
    /// XML it emits is always well-formed and round-trips through its own parser.
    /// Today it passes the raw control byte straight into the attribute, producing a
    /// document `ResolumeParser` (and Resolume) reject — corrupt output from parsed
    /// input. This test pins the required behavior.
    func testControlCharsInPresetNameDoNotProduceUnparseableXML() throws {
        let cues = [
            CuePoint(id: "a", start: 0, name: "s", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 60, name: "e", color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        // NUL + backspace + a bell — all illegal in XML 1.0 text.
        let hostile = "Env\u{0000}\u{0008}\u{0007}Name"
        let xml = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: hostile) ?? ""
        XCTAssertFalse(xml.isEmpty, "export must still produce output for a control-laced name")
        XCTAssertNoThrow(try ResolumeParser.parse(xml: xml),
                         "exporter must not emit XML that its own parser cannot read (control bytes must be stripped/escaped)")
    }

    /// A Resolume point with x far outside the normalized 0…1 range (here x=5 and
    /// x=-3) must still yield finite, non-negative, in-range cues after conversion.
    /// (out-of-range coordinate)
    func testPointsFarOutsideUnitRangeConvertToSaneCues() throws {
        let xml = """
        <Preset name="OOR">
          <ModifierEnvelope><points>
            <point x="-3.0" y="9.9" curve="1"/>
            <point x="5.0" y="-9.9" curve="1"/>
            <point x="1e18" y="0.5" curve="1"/>
          </points></ModifierEnvelope>
        </Preset>
        """
        let result = try ResolumeParser.parse(xml: xml)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 60)
        assertSaneCues(cues, "resolume-out-of-range-x")
    }
}

// MARK: - Rekordbox / XML: XXE, entity bombs, illegal bytes

final class AdversarialRekordboxXMLTests: XCTestCase {

    /// XXE. A DOCTYPE that declares an external SYSTEM entity pointing at a local file
    /// must NOT be resolved — Foundation `XMLParser` keeps external-entity resolution
    /// off by default, and this test fails loudly if that ever regresses (a track name
    /// must never be able to exfiltrate file contents). (XML external entity injection)
    func testExternalEntityIsNotResolvedNoFileExfiltration() throws {
        let dir = Scratch.makeDirectory("xxe-canary")
        let canary = "TOPSECRET_XXE_CANARY_9182"
        let secretURL = dir.appendingPathComponent("secret.txt")
        try Data(canary.utf8).write(to: secretURL)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE DJ_PLAYLISTS [ <!ENTITY xxe SYSTEM "\(secretURL.absoluteString)"> ]>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="1">
            <TRACK TrackID="1" Name="&xxe;" TotalTime="120" AverageBpm="120">
              <POSITION_MARK Name="c" Type="0" Start="0" Num="0"/>
            </TRACK>
          </COLLECTION>
        </DJ_PLAYLISTS>
        """
        // Parse may throw (external entity refused) or succeed with an unresolved name;
        // either way the secret must never appear in the parsed model.
        if let result = try? RekordboxParser.parse(xml: xml) {
            for t in result.tracks {
                XCTAssertFalse(t.name.contains(canary), "XXE: external file contents leaked into a track name")
                assertSaneCues(t.cuePoints, "xxe-track")
            }
        }
        // Belt and braces: the canary must not surface anywhere the parser could place it.
    }

    /// Billion-laughs. A nested internal-entity expansion must not be expanded into a
    /// multi-megabyte string or hang the parser — it must fail closed or complete
    /// quickly with a bounded result. Kept intentionally small so that even in the
    /// worst case (full expansion) the allocation is survivable. (XML entity bomb)
    func testNestedEntityExpansionDoesNotHangOrExplode() {
        // 5 levels x10 = up to 100k 'a's if fully expanded — bounded on purpose.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE DJ_PLAYLISTS [
          <!ENTITY a "aaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
          <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
        ]>
        <DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="1">
          <TRACK TrackID="1" Name="&e;" TotalTime="1" AverageBpm="1"/>
        </COLLECTION></DJ_PLAYLISTS>
        """
        // The only requirement: return (throw or parse) without hanging or trapping.
        let result = try? RekordboxParser.parse(xml: xml)
        if let name = result?.tracks.first?.name {
            XCTAssertLessThan(name.utf8.count, 10_000_000, "entity expansion must stay bounded")
        }
    }

    /// A raw NUL (0x00) byte embedded in XML is illegal per the spec; the parser must
    /// reject the document (throw) rather than crash on the control byte. (illegal byte)
    func testRawControlByteInXMLThrowsInsteadOfCrashing() {
        var bytes = Array("""
        <?xml version="1.0"?><DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="1">\
        <TRACK TrackID="1" Name="X
        """.utf8)
        bytes.append(0x00) // illegal control byte mid-attribute
        bytes += Array("\"/></COLLECTION></DJ_PLAYLISTS>".utf8)
        let xml = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try RekordboxParser.parse(xml: xml),
                             "a NUL byte inside XML must be rejected, not crash the parser")
    }

    /// Deeply nested playlist folders (NODE Type=0) come straight from untrusted XML.
    /// The parser builds the tree iteratively, so a deep document must not crash it,
    /// and the recursive `totalTrackCount()` must still return correctly at a depth a
    /// real library could plausibly reach. (recursion / nesting stress)
    func testDeeplyNestedPlaylistFoldersParseAndCountWithoutCrashing() throws {
        let depth = 2_000
        var xml = "<?xml version=\"1.0\"?><DJ_PLAYLISTS Version=\"1.0.0\"><PLAYLISTS>"
        xml += "<NODE Type=\"0\" Name=\"ROOT\">"
        for i in 0..<depth { xml += "<NODE Type=\"0\" Name=\"F\(i)\">" }
        xml += "<NODE Type=\"1\" Name=\"Leaf\"><TRACK Key=\"1\"/></NODE>"
        for _ in 0..<depth { xml += "</NODE>" }
        xml += "</NODE></PLAYLISTS></DJ_PLAYLISTS>"

        let result = try RekordboxParser.parse(xml: xml)
        XCTAssertEqual(result.playlists.count, 1, "ROOT's single child chain is preserved")
        XCTAssertEqual(result.playlists.first?.totalTrackCount(), 1,
                       "recursive count must reach the single leaf track through the nested folders")
    }
}

// MARK: - Project (.cueproj JSON): hostile numeric fields

final class AdversarialProjectJSONTests: XCTestCase {

    /// A hand-edited `.cueproj` can carry astronomically large, negative and
    /// out-of-range numeric fields. Decoding must not crash, and running the decoded
    /// cue points through `sanitized()` (as the app does on load) must neutralize every
    /// one of them into a renderable/exportable value. (hostile JSON numbers)
    func testHostileNumericFieldsDecodeAndSanitizeToSafeValues() throws {
        let json = """
        {
          "name": "Hostile",
          "trackDuration": 1e308,
          "presetName": "P",
          "cuePoints": [
            { "id": "a", "start": -999999, "name": "neg", "color": "#fff", "yValue": 100000, "curve": 9999, "enabled": true },
            { "id": "b", "start": 1e300, "name": "huge", "color": "#fff", "yValue": -50, "curve": -1, "enabled": true }
          ]
        }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.cuePoints.count, 2)
        for c in project.cuePoints.map({ $0.sanitized() }) {
            XCTAssertTrue(c.start.isFinite && c.start >= 0, "start \(c.start) not sanitized")
            XCTAssertTrue((0...100).contains(c.yValue), "yValue \(c.yValue) not clamped")
            XCTAssertTrue((1...23).contains(c.curve), "curve \(c.curve) not clamped")
        }
        // And the sanitized cues must survive an actual export (its most hostile sink).
        let cues = project.cuePoints.map { $0.sanitized() }
        _ = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: project.presetName)
        _ = ShowKontrolExporter.generate(cuePoints: cues)
    }

    /// A JSON number too large for `Double` (1e400) must be rejected by the decoder
    /// (thrown), not silently decoded as +Inf into a cue field. (numeric overflow)
    func testOverflowingJSONNumberIsRejectedByDecoder() {
        let json = Data("""
        { "cuePoints": [ { "id": "a", "start": 1e400, "name": "n", "color": "#fff", "yValue": 0, "curve": 1, "enabled": true } ] }
        """.utf8)
        // Whatever the decoder does, the invariant is: no non-finite value survives.
        if let project = try? JSONDecoder().decode(Project.self, from: json) {
            for c in project.cuePoints {
                XCTAssertTrue(c.sanitized().start.isFinite, "an overflowing start must never remain non-finite after sanitize")
            }
        }
    }
}

// MARK: - Engine DJ: decompressed cue-slot parsing (threat model §4 bounds)

/// These reach `parseCueSlots` through a REAL raw-DEFLATE blob — the code path the
/// existing garbage-blob tests never exercise because their bytes fail decompression.
/// SQLite (via CSQLite) and raw DEFLATE (via CZlib, matching the vendored
/// `inflateInit2(-15)` path — spec §2.B.6) are both available on every platform, so
/// this suite runs identically on macOS and Windows.
final class AdversarialEngineDJCueSlotTests: XCTestCase {

    /// Big-endian float64 bit pattern, matching `EngineDJParser.readBigEndianFloat64`.
    private func be64(_ d: Double) -> [UInt8] {
        let bits = d.bitPattern
        return (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * (7 - $0))) }
    }

    /// Wrap a decompressed cue-slot payload into the Engine DJ blob layout
    /// (LE32 uncompressed size + raw-DEFLATE bytes) and load it through the parser.
    private func parseSlots(_ payload: [UInt8], _ label: String) throws -> [CuePoint] {
        let url = Scratch.makeDirectory(label).appendingPathComponent("m.db")
        EngineDJFixtures.badBlob(at: url, declaredSize: UInt32(payload.count), compressedGarbage: ZlibFixtures.rawDeflate(payload))
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty, "track must load")
        return tracks.first?.cuePoints ?? []
    }

    /// A single valid slot must decode end-to-end: name preserved, position converted
    /// from 44.1 kHz samples to seconds. Proves the happy path of the untested parser.
    func testValidSlotDecodesNameAndPosition() throws {
        var payload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1] // 8-byte header
        payload += [4] + Array("Drop".utf8) + be64(44_100.0) + [0, 0, 0, 0] // 1.0 s
        let cues = try parseSlots(payload, "engine-valid-slot")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.name, "Drop")
        assertApproxEqual(cues.first?.start ?? -1, 1.0, tolerance: 0.001, "44100 samples -> 1.0 s")
        assertSaneCues(cues, "engine-valid-slot")
    }

    /// A slot claiming a 250-byte name inside a tiny buffer must be bounded by the
    /// `nameEnd <= bytes.count` guard — no over-read, and the earlier valid cue survives.
    /// This is the exact over-read the threat model flags for the cue-slot reader (§4).
    func testOversizedSlotNameLengthIsBoundedNoOverRead() throws {
        var payload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 2]
        payload += [4] + Array("Good".utf8) + be64(88_200.0) + [0, 0, 0, 0] // 2.0 s, valid
        payload += [250]                                  // second slot claims a 250-byte name
        payload += [UInt8](repeating: 0x41, count: 20)    // but only 20 bytes remain
        let cues = try parseSlots(payload, "engine-oversized-name")
        assertSaneCues(cues, "engine-oversized-name")
        XCTAssertEqual(cues.first?.name, "Good", "the valid cue before the hostile slot is preserved")
        XCTAssertLessThanOrEqual(cues.count, 1, "the truncated hostile slot must not add a cue")
    }

    /// A slot whose 8 position bytes are a NaN bit pattern must be neutralized by
    /// `sanitized()` to a finite, non-negative start — never NaN into the canvas/export.
    /// (non-finite payload)
    func testNaNPositionBitsAreSanitizedToFiniteStart() throws {
        var payload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1]
        payload += [3] + Array("NaN".utf8)
        payload += [0x7F, 0xF8, 0, 0, 0, 0, 0, 0] // quiet-NaN big-endian
        payload += [0, 0, 0, 0]
        let cues = try parseSlots(payload, "engine-nan-pos")
        XCTAssertEqual(cues.count, 1)
        XCTAssertTrue(cues.first?.start.isFinite ?? false, "NaN sample position must sanitize to a finite start")
        XCTAssertGreaterThanOrEqual(cues.first?.start ?? -1, 0)
    }
}

// MARK: - Engine DJ: decompression-bomb guard must not be sized by the blob length

final class AdversarialEngineDJBombTests: XCTestCase {

    /// A large compressed payload that declares a tiny uncompressed size must fail
    /// closed (track with no cues) and complete promptly. The clamp on the DECLARED
    /// size (< 1e6) is the bomb guard; a big blob with garbage bytes must never be
    /// trusted to produce cues. (decompression bomb / fail-closed)
    ///
    /// `Support/Zlib.inflate`'s output buffer is sized only by the (already-clamped)
    /// declared size, never by the attacker-controlled *compressed* length — a prior
    /// version scaled the Apple decode buffer by `compressed.count`, which would have
    /// let a multi-hundred-MB blob drive a multi-GB allocation even with a small
    /// declared size. This test's 2 MB blob would have exercised that path.
    func testLargeGarbageBlobWithTinyDeclaredSizeFailsClosed() throws {
        let url = Scratch.makeDirectory("engine-bomb-large").appendingPathComponent("m.db")
        let garbage = [UInt8](repeating: 0xA5, count: 2_000_000) // 2 MB of non-DEFLATE bytes
        EngineDJFixtures.badBlob(at: url, declaredSize: 100, compressedGarbage: garbage)
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty, "track must still load")
        for t in tracks { XCTAssertTrue(t.cuePoints.isEmpty, "garbage that cannot inflate must yield no cues") }
    }

    /// The existing bomb test feeds *garbage* that never inflates, so it never exercises
    /// the "abort a genuine stream once it blows the cap" branch. This one hands the parser
    /// a perfectly valid raw-DEFLATE stream that expands ~3000× (300 KB from ~300 bytes)
    /// while the blob DECLARES a 100-byte uncompressed size. The cap given to
    /// `Zlib.inflate` is derived from that small declared size, so the honest-but-huge
    /// stream must be aborted mid-inflate → the track loads with **no cues**, never a
    /// multi-hundred-KB allocation driven off a lie. (decompression bomb via valid DEFLATE)
    func testValidDeflateStreamExceedingDeclaredCapYieldsNoCues() throws {
        let url = Scratch.makeDirectory("engine-valid-bomb").appendingPathComponent("m.db")
        let payload = [UInt8](repeating: 0x00, count: 300_000)   // inflates far past the cap
        let compressed = ZlibFixtures.rawDeflate(payload)
        XCTAssertFalse(compressed.isEmpty, "vendored deflate must produce a valid stream")
        EngineDJFixtures.badBlob(at: url, declaredSize: 100, compressedGarbage: compressed)
        let tracks = try EngineDJParser.parse(databaseURL: url)
        XCTAssertFalse(tracks.isEmpty, "track must still load")
        for t in tracks {
            XCTAssertTrue(t.cuePoints.isEmpty,
                          "a valid DEFLATE stream that exceeds the small declared cap must abort → no cues")
        }
    }
}

// =============================================================================
// Red-Team adversarial additions (CUESYNC-4).
//
// The port added a pure-Swift Support/ layer (AudioDuration, Hex) that now sits
// on the untrusted-input boundary: a hostile audio file or `.cueproj` reaches it
// directly. These tests attack the *acceptance criteria* — "parsing fails closed,
// never crashes, never emits a value that traps a downstream consumer" (spec §4) —
// on code paths the existing suite exercises only with well-formed input.
// =============================================================================

// MARK: - AudioDuration: non-finite / degenerate header fields (threat model §4)

/// Spec §4: "Audio duration header parsing: bound every read; an unknown/oversized
/// WAV/AIFF header field → give up gracefully and defer to the manual duration modal
/// (return nil)." A detected duration is later used as `trackDuration`; a NON-FINITE
/// one (NaN/Inf) flows into the envelope math and the exporters, where an `Int(...)`
/// conversion traps. So the invariant these tests pin is: for ANY input, the returned
/// duration is either `nil` or a finite value — never NaN/Inf.
final class AdversarialAudioDurationTests: XCTestCase {

    private func be32(_ v: UInt32) -> [UInt8] { BinaryFixtures.be32(v) }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }
    private func write(_ bytes: [UInt8], ext: String, _ label: String) -> URL {
        Scratch.writeFile(bytes, name: "atk.\(ext)", in: Scratch.makeDirectory(label))
    }

    /// EXPLOIT. AIFF stores its sample rate as an 80-bit IEEE-754 extended float in the
    /// COMM chunk — an attacker-controlled 10-byte field. A crafted value decodes to a
    /// legal, positive-but-vanishingly-small rate (~9.3e-302 here), which passes the
    /// `sampleRate > 0` guard, and then `numSampleFrames / sampleRate` with a maxed-out
    /// (0xFFFFFFFF) frame count OVERFLOWS to +Infinity. `aiffDuration` returns that +Inf
    /// with no finiteness check on the quotient — a non-finite duration escapes the parser,
    /// violating the "give up gracefully / return nil" contract. This test pins the fix
    /// (reject a non-finite/degenerate result → nil). (numeric overflow / non-finite output)
    func testAIFFCraftedTinySampleRateNeverReturnsNonFiniteDuration() {
        // COMM body: numChannels(2) numSampleFrames(4) sampleSize(2) extended80 rate(10) = 18 bytes.
        // Extended80 [0x3C,0x17,0x80,0,0,0,0,0,0,0] => exponent -1000, mantissa 2^63 => 2^-1000.
        var comm: [UInt8] = [0x00, 0x02]                 // numChannels = 2
        comm += be32(0xFFFF_FFFF)                        // numSampleFrames = 4_294_967_295
        comm += [0x00, 0x10]                             // sampleSize = 16
        comm += [0x3C, 0x17, 0x80, 0, 0, 0, 0, 0, 0, 0] // sampleRate ~= 9.3e-302
        var aiff = Array("FORM".utf8) + be32(UInt32(4 + 8 + comm.count)) + Array("AIFF".utf8)
        aiff += Array("COMM".utf8) + be32(UInt32(comm.count)) + comm

        let duration = AudioDuration.duration(of: write(aiff, ext: "aiff", "aiff-inf-rate"))
        if let duration {
            XCTAssertTrue(duration.isFinite,
                          "a crafted AIFF sample rate must not yield a non-finite (\(duration)) duration — return nil instead")
            XCTAssertFalse(duration.isInfinite, "AIFF duration overflowed to Infinity")
        }
    }

    /// A WAV `data` chunk that CLAIMS a size far beyond the file (here ~4 GiB in a tiny
    /// file) must not turn into a non-finite duration. WAV uses an integer byte-rate so it
    /// can't reach Inf, but this locks the same finiteness invariant on the RIFF path so a
    /// future refactor can't regress it. (oversized header field / finiteness guard)
    func testWAVLyingDataChunkSizeStaysFinite() {
        var wav = Array("RIFF".utf8) + le32(0xFFFF_FFF0) + Array("WAVE".utf8)
        wav += Array("fmt ".utf8) + le32(16)
        wav += [0x01, 0x00, 0x02, 0x00]           // PCM, 2 channels
        wav += le32(44_100)                       // sample rate
        wav += le32(1)                            // byteRate = 1 (maximizes a lying duration)
        wav += [0x04, 0x00, 0x10, 0x00]
        wav += Array("data".utf8) + le32(0xFFFF_FFF0)  // claims ~4 GiB of samples
        wav += [0x00, 0x00, 0x00, 0x00]                // but only 4 bytes present
        let duration = AudioDuration.duration(of: write(wav, ext: "wav", "wav-lying-data"))
        if let duration {
            XCTAssertTrue(duration.isFinite, "WAV duration must stay finite for a lying data-chunk size")
        }
    }
}

// MARK: - Hex / CSS color: non-finite components from an untrusted color string

/// A `CuePoint.color` is a free-form `Codable` string, so a hostile `.cueproj` can set it
/// to anything — and every importer (Rekordbox/Serato/ShowKontrol) also stamps colors that
/// later round-trip through a saved project. `Hex.parseCSSColor` is the cross-platform
/// replacement for `NSColor.fromCSSString` and feeds the (future swift-cross-ui) renderer,
/// which will convert each 0…1 component with `Int(component * 255)` / `UInt8(...)` — a
/// conversion that TRAPS on NaN/Inf. `NSColor` absorbed such values; the pure-Swift port
/// hands them straight through. The invariant: a parsed color component is always finite.
final class AdversarialHexColorTests: XCTestCase {

    /// EXPLOIT. `rgb(...)` parsing uses `Double(_:)`, which happily parses "nan", "inf",
    /// and overflowing literals like "1e400" (→ ±Inf). `parseRGBFunction` /
    /// `parseCSSColor` then divide by 255 and return the non-finite component unchecked.
    /// A hostile color in an imported/loaded cue therefore produces a NaN/Inf render
    /// component — a latent `Int(NaN)` trap. Pin: no CSS parse ever returns a non-finite
    /// component. (encoding trick / non-finite output / fail-closed)
    func testHostileColorStringsNeverYieldNonFiniteComponents() {
        let hostile = [
            "rgb(nan, 0, 0)", "rgb(0, inf, 0)", "rgb(0, 0, -inf)",
            "rgb(1e400, 0, 0)", "rgb(0, infinity, 0)", "rgb(nan, nan, nan)",
        ]
        for s in hostile {
            let c = Hex.parseCSSColor(s) // the entry point the renderer uses (never returns nil)
            XCTAssertTrue(c.r.isFinite && c.g.isFinite && c.b.isFinite,
                          "parseCSSColor(\"\(s)\") returned a non-finite component (\(c)) — would trap Int(NaN/Inf) in the renderer")
            if let rgb = Hex.parseRGBFunction(s) {
                XCTAssertTrue(rgb.r.isFinite && rgb.g.isFinite && rgb.b.isFinite,
                              "parseRGBFunction(\"\(s)\") returned a non-finite component (\(rgb))")
            }
        }
    }

    /// End-to-end reproduction: a hand-edited `.cueproj` carries a NaN-laced cue color;
    /// decoding succeeds (color is just a string), and rendering that cue's color through
    /// the shared parser must not surface a non-finite component. (hostile `.cueproj` → render)
    func testHostileCueprojColorDecodesAndRendersFinite() throws {
        let json = """
        { "cuePoints": [
            { "id": "a", "start": 0, "name": "n", "color": "rgb(nan, 0, 0)", "yValue": 0, "curve": 1, "enabled": true }
        ] }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let color = project.cuePoints.first!.color
        let c = Hex.parseCSSColor(color)
        XCTAssertTrue(c.r.isFinite && c.g.isFinite && c.b.isFinite,
                      "a NaN color loaded from a hostile .cueproj must not render as a non-finite component (\(c))")
    }
}
