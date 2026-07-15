import Foundation
import XCTest
@testable import CueSyncCore

final class SeratoMarkers2Tests: XCTestCase {
    func testBasicTwoCueStream() {
        let stream = BinaryFixtures.markers2([
            BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 0, posMs: 2500, r: 0xCC, g: 0, b: 0, name: "Intro")),
            BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 1, posMs: 60000, name: "Drop")),
        ])
        let cues = SeratoParser.parseSeratoMarkers2(data: stream)
        XCTAssertEqual(cues.count, 2)
        assertSaneCues(cues, "serato-basic")
        guard cues.count == 2 else { return }
        assertApproxEqual(cues[0].start, 2.5, "first cue at 2.5s")
        assertApproxEqual(cues[1].start, 60.0, "second cue at 60s")
        XCTAssertEqual(cues[0].name, "Intro")
    }

    func testCueIndex255WithEmptyNameDoesNotOverflowUInt8() {
        var p = [UInt8](repeating: 0, count: 13)
        p[1] = 0xFF // cue index 255
        p[4] = 0x10 // position bytes -> 4096 ms
        let cues = SeratoParser.parseSeratoMarkers2(data: BinaryFixtures.markers2([BinaryFixtures.cueEntry(p)]))
        assertSaneCues(cues, "serato-index-255")
        XCTAssertEqual(cues.count, 1)
    }

    func testBase64WrappedStreamWithNewlineAndNullPadding() {
        let raw = BinaryFixtures.markers2([BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 2, posMs: 1000, name: "B64"))])
        let b64 = raw.base64EncodedString()
        var wrapped = Array(b64.utf8)
        wrapped.append(0x0A)
        wrapped.append(0x00)
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(wrapped))
        assertSaneCues(cues, "serato-base64")
        XCTAssertEqual(cues.count, 1)
    }

    func testTruncationAtEveryByteBoundaryNeverCrashes() {
        let full = Array(BinaryFixtures.markers2([BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 0, posMs: 1000, name: "X"))]))
        for cut in 0...full.count {
            let cues = SeratoParser.parseSeratoMarkers2(data: Data(full.prefix(cut)))
            assertSaneCues(cues, "serato-truncated-\(cut)")
        }
    }

    func testHugeAdvertisedPayloadLengthIsRejectedNotOverread() {
        var bad: [UInt8] = [0x01, 0x01]
        bad += Array("CUE".utf8); bad.append(0x00)
        bad += BinaryFixtures.be32(0xFFFFFF00)
        bad += [0x00, 0x00, 0x00]
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(bad))
        assertSaneCues(cues, "serato-huge-len")
    }

    func testUnicodeCueNames() {
        for name in ["日本語キュー", "Ünïcödé 🎧", "café — drøp"] {
            let cues = SeratoParser.parseSeratoMarkers2(data: BinaryFixtures.markers2([
                BinaryFixtures.cueEntry(BinaryFixtures.cuePayload(index: 0, posMs: 0, name: name)),
            ]))
            XCTAssertEqual(cues.first?.name, name, "unicode cue name '\(name)' must round-trip")
        }
    }

    func testEmptyDataProducesNoCues() {
        XCTAssertTrue(SeratoParser.parseSeratoMarkers2(data: Data()).isEmpty)
    }

    func testFuzzedRandomBytesNeverProduceInsaneCues() {
        var rng = XorShift64(seed: 0x5E4A)
        for _ in 0..<400 {
            let len = Int(rng.next() % 300)
            var bytes = rng.bytes(len)
            if len >= 2 && (rng.byte() & 1 == 0) { bytes[0] = 0x01; bytes[1] = 0x01 }
            let cues = SeratoParser.parseSeratoMarkers2(data: Data(bytes))
            assertSaneCues(cues, "serato-fuzz")
        }
    }
}

final class SeratoParseFileTests: XCTestCase {
    func testUnsupportedExtensionThrows() {
        let dir = Scratch.makeDirectory("serato-ext")
        let url = Scratch.writeFile([0x00], name: "x.txt", in: dir)
        XCTAssertThrowsError(try SeratoParser.parseFile(at: url))
    }

    func testEmptyMP3Throws() {
        let dir = Scratch.makeDirectory("serato-empty")
        let url = Scratch.writeFile([], name: "x.mp3", in: dir)
        XCTAssertThrowsError(try SeratoParser.parseFile(at: url))
    }

    func testTinyMP3BelowMinimumSizeThrows() {
        let dir = Scratch.makeDirectory("serato-tiny")
        let url = Scratch.writeFile([0x49, 0x44, 0x33], name: "x.mp3", in: dir)
        XCTAssertThrowsError(try SeratoParser.parseFile(at: url))
    }

    func testWAVWithBadMagicThrows() {
        let dir = Scratch.makeDirectory("serato-wav-bad")
        let url = Scratch.writeFile([UInt8](repeating: 0x20, count: 32), name: "x.wav", in: dir)
        XCTAssertThrowsError(try SeratoParser.parseFile(at: url))
    }

    func testAIFFWithBadMagicThrows() {
        let dir = Scratch.makeDirectory("serato-aiff-bad")
        let url = Scratch.writeFile([UInt8](repeating: 0x20, count: 32), name: "x.aiff", in: dir)
        XCTAssertThrowsError(try SeratoParser.parseFile(at: url))
    }

    func testExtensionMatchingIsCaseInsensitive() throws {
        // Windows and macOS filesystems are both case-insensitive by default; a ".MP3" or
        // ".Wav" extension from a Windows file picker must be accepted identically to the
        // lowercase form.
        let dir = Scratch.makeDirectory("serato-case")
        var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        mp3 += [UInt8](repeating: 0x00, count: 16)
        for ext in ["MP3", "Mp3", "mp3"] {
            let url = Scratch.writeFile(mp3, name: "track.\(ext)", in: dir)
            let track = try SeratoParser.parseFile(at: url)
            assertSaneCues(track.cuePoints, "serato-case-\(ext)")
        }
    }

    func testMinimalValidContainersParseWithoutCuesOrCrashing() throws {
        let dir = Scratch.makeDirectory("serato-minimal")

        var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        mp3 += [UInt8](repeating: 0x00, count: 16)
        let t1 = try SeratoParser.parseFile(at: Scratch.writeFile(mp3, name: "a.mp3", in: dir))
        assertSaneCues(t1.cuePoints, "serato-min-mp3")

        var wav = Array("RIFF".utf8)
        wav += [0x24, 0x00, 0x00, 0x00]
        wav += Array("WAVE".utf8)
        wav += Array("fmt ".utf8) + [0x10, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16)
        let t2 = try SeratoParser.parseFile(at: Scratch.writeFile(wav, name: "b.wav", in: dir))
        assertSaneCues(t2.cuePoints, "serato-min-wav")

        let aiff = Array("FORM".utf8) + [0x00, 0x00, 0x00, 0x04] + Array("AIFF".utf8)
        let t3 = try SeratoParser.parseFile(at: Scratch.writeFile(aiff, name: "c.aiff", in: dir))
        assertSaneCues(t3.cuePoints, "serato-min-aiff")
    }

    func testParseFilesSwallowsPerFileErrorsAndNeverCrashes() {
        var rng = XorShift64(seed: 0xF11E)
        let exts = ["mp3", "wav", "aiff"]
        let dir = Scratch.makeDirectory("serato-parsefiles-fuzz")
        var urls: [URL] = []
        for i in 0..<60 {
            let len = Int(rng.next() % 400) + 12
            var bytes = rng.bytes(len)
            if rng.byte() & 1 == 0 {
                let magic = i % 2 == 0 ? Array("RIFF".utf8) : Array("FORM".utf8)
                for j in 0..<min(4, bytes.count) { bytes[j] = magic[j] }
            }
            urls.append(Scratch.writeFile(bytes, name: "f\(i).\(exts[i % exts.count])", in: dir))
        }
        let result = SeratoParser.parseFiles(at: urls)
        for t in result.tracks { assertSaneCues(t.cuePoints, "serato-parsefiles-fuzz") }
    }

    func testParseFilesOfEmptyListReturnsEmptyResult() {
        XCTAssertTrue(SeratoParser.parseFiles(at: []).tracks.isEmpty)
    }

    // MARK: - Audit-driven regressions (ID3 edge cases)

    func testMP3ID3MetadataParsesTitleArtistAndDuration() throws {
        let mp3 = BinaryFixtures.buildMP3(frames: [("TIT2", "My Title"), ("TPE1", "My Artist"), ("TLEN", "180000")])
        let dir = Scratch.makeDirectory("serato-id3-meta")
        let t = try SeratoParser.parseFile(at: Scratch.writeFile(mp3, name: "x.mp3", in: dir))
        XCTAssertEqual(t.name, "My Title")
        XCTAssertEqual(t.artist, "My Artist")
        XCTAssertEqual(t.totalTime, 180)
        assertSaneCues(t.cuePoints, "serato-mp3-id3")
    }

    func testTLENNonFiniteOrHugeValuesDoNotCrashDurationConversion() throws {
        let dir = Scratch.makeDirectory("serato-tlen")
        for (i, bad) in ["nan", "inf", "999999999999999999999", "1e308"].enumerated() {
            let mp3 = BinaryFixtures.buildMP3(frames: [("TIT2", "T"), ("TLEN", bad)])
            let t = try SeratoParser.parseFile(at: Scratch.writeFile(mp3, name: "tlen\(i).mp3", in: dir))
            XCTAssertGreaterThanOrEqual(t.totalTime, 0, "TLEN \(bad) must not crash; duration must stay sane")
            XCTAssertEqual(t.name, "T", "title still parsed alongside bad TLEN")
        }
    }

    func testTBPMNonFiniteValueKeepsBPMFinite() throws {
        let mp3 = BinaryFixtures.buildMP3(frames: [("TIT2", "T"), ("TBPM", "nan")])
        let dir = Scratch.makeDirectory("serato-tbpm")
        let t = try SeratoParser.parseFile(at: Scratch.writeFile(mp3, name: "x.mp3", in: dir))
        XCTAssertTrue(t.bpm.isFinite)
    }

    func testMP3UnicodeID3TitleRoundTrips() throws {
        let mp3 = BinaryFixtures.buildMP3(frames: [("TIT2", "日本語タイトル")])
        let dir = Scratch.makeDirectory("serato-unicode-id3")
        let t = try SeratoParser.parseFile(at: Scratch.writeFile(mp3, name: "x.mp3", in: dir))
        XCTAssertEqual(t.name, "日本語タイトル")
    }

    func testAIFFZeroSizeChunkDoesNotAbortIteration() throws {
        var aiff = Array("FORM".utf8) + [0x00, 0x00, 0x00, 0x18] + Array("AIFF".utf8)
        aiff += Array("TEST".utf8) + [0x00, 0x00, 0x00, 0x00] // zero-size chunk
        aiff += Array("NONE".utf8) + [0x00, 0x00, 0x00, 0x02] + [0x01, 0x02]
        let dir = Scratch.makeDirectory("serato-aiff-zero-chunk")
        let t = try SeratoParser.parseFile(at: Scratch.writeFile(aiff, name: "x.aiff", in: dir))
        assertSaneCues(t.cuePoints, "serato-aiff-zero-chunk")
    }
}
