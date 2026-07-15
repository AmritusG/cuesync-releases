import Foundation
import XCTest
@testable import CueSyncCore

// =============================================================================
// Behavioral coverage for the new cross-platform Support/ layer (spec §2.C).
// PortComplianceTests only checks these files exist and stay guard-clean; the
// tests here pin their actual parsing/storage behavior so a regression in the
// pure-Swift WAV/AIFF/hex/preferences logic is caught, not just a missing file.
// =============================================================================

// MARK: - Hex / CSS color parsing

final class HexColorTests: XCTestCase {
    func testSixDigitHexWithHashParsesExactComponents() {
        let c = Hex.parseHexColor("#1ed760")
        XCTAssertNotNil(c)
        assertApproxEqual(c?.r ?? -1, 0x1e.toDoubleOver255, tolerance: 0.0001)
        assertApproxEqual(c?.g ?? -1, 0xd7.toDoubleOver255, tolerance: 0.0001)
        assertApproxEqual(c?.b ?? -1, 0x60.toDoubleOver255, tolerance: 0.0001)
    }

    func testHashIsOptional() {
        XCTAssertNotNil(Hex.parseHexColor("1ed760"))
    }

    func testThreeDigitShorthandExpandsEachNibble() {
        let c = Hex.parseHexColor("#0f0")
        assertApproxEqual(c?.r ?? -1, 0)
        assertApproxEqual(c?.g ?? -1, 1.0)
        assertApproxEqual(c?.b ?? -1, 0)
    }

    func testUppercaseAndLowercaseHexDigitsAgree() {
        XCTAssertEqual(Hex.parseHexColor("#ABCDEF")?.r, Hex.parseHexColor("#abcdef")?.r)
        XCTAssertEqual(Hex.parseHexColor("#ABCDEF")?.g, Hex.parseHexColor("#abcdef")?.g)
        XCTAssertEqual(Hex.parseHexColor("#ABCDEF")?.b, Hex.parseHexColor("#abcdef")?.b)
    }

    func testBoundaryAllZeroAndAllFComponents() {
        let black = Hex.parseHexColor("#000000")
        XCTAssertEqual(black?.r, 0); XCTAssertEqual(black?.g, 0); XCTAssertEqual(black?.b, 0)
        let white = Hex.parseHexColor("#ffffff")
        assertApproxEqual(white?.r ?? -1, 1.0); assertApproxEqual(white?.g ?? -1, 1.0); assertApproxEqual(white?.b ?? -1, 1.0)
    }

    func testWhitespaceAroundHexStringIsTrimmed() {
        XCTAssertNotNil(Hex.parseHexColor("  #ffffff  "))
    }

    func testInvalidLengthsAndNonHexCharactersReturnNil() {
        for bad in ["", "#", "#ff", "#fffff", "#fffffff", "#gggggg", "not a color", "#12 34 56"] {
            XCTAssertNil(Hex.parseHexColor(bad), "expected nil for invalid input '\(bad)'")
        }
    }

    func testRGBFunctionParsesIntegerComponents() {
        let c = Hex.parseRGBFunction("rgb(255, 128, 0)")
        assertApproxEqual(c?.r ?? -1, 1.0)
        assertApproxEqual(c?.g ?? -1, 128.0 / 255.0)
        assertApproxEqual(c?.b ?? -1, 0)
    }

    func testRGBFunctionRequiresWellFormedSyntax() {
        for bad in ["rgb(255, 128)", "rgba(255, 128, 0, 1)", "rgb 255,128,0", "rgb(a, b, c)", ""] {
            XCTAssertNil(Hex.parseRGBFunction(bad), "expected nil for invalid input '\(bad)'")
        }
    }

    func testParseCSSColorPrefersRGBFunctionOverHexWhenBothWouldMatch() {
        // "rgb(...)" never looks like valid hex, so this just proves dispatch order
        // doesn't accidentally fall through to the hex parser for a valid rgb() string.
        let c = Hex.parseCSSColor("rgb(0, 0, 255)")
        assertApproxEqual(c.b, 1.0)
    }

    func testParseCSSColorFallsBackToAccentGreenForUnrecognizedInput() {
        let fallback = Hex.parseCSSColor("not-a-color")
        assertApproxEqual(fallback.r, 30.0 / 255.0)
        assertApproxEqual(fallback.g, 215.0 / 255.0)
        assertApproxEqual(fallback.b, 96.0 / 255.0)
    }

    func testParseCSSColorHandlesEmptyStringWithoutCrashing() {
        _ = Hex.parseCSSColor("")
    }
}

private extension Int {
    var toDoubleOver255: Double { Double(self) / 255.0 }
}

// MARK: - WAV/AIFF duration parsing

final class AudioDurationTests: XCTestCase {
    private func write(_ bytes: [UInt8], name: String, _ label: String) -> URL {
        Scratch.writeFile(bytes, name: name, in: Scratch.makeDirectory(label))
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// A minimal well-formed WAV: 44.1kHz/16-bit/stereo fmt chunk (byteRate 176400)
    /// with a 176400-byte data chunk — exactly 1.0 second of audio.
    private func minimalWAV(dataSize: Int, byteRate: UInt32) -> [UInt8] {
        var bytes = Array("RIFF".utf8) + le32(36 + UInt32(dataSize)) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16)
        bytes += [0x01, 0x00]           // PCM
        bytes += [0x02, 0x00]           // 2 channels
        bytes += le32(44_100)           // sample rate
        bytes += le32(byteRate)         // byte rate
        bytes += [0x04, 0x00]           // block align
        bytes += [0x10, 0x00]           // bits per sample
        bytes += Array("data".utf8) + le32(UInt32(dataSize))
        bytes += [UInt8](repeating: 0, count: dataSize)
        return bytes
    }

    func testWAVDurationComputedFromByteRateAndDataSize() {
        let url = write(minimalWAV(dataSize: 176_400, byteRate: 176_400), name: "one-second.wav", "wav-duration")
        let duration = AudioDuration.duration(of: url)
        XCTAssertNotNil(duration)
        assertApproxEqual(duration ?? -1, 1.0, tolerance: 0.001)
    }

    func testWAVDurationForZeroLengthDataChunkIsZero() {
        let url = write(minimalWAV(dataSize: 0, byteRate: 176_400), name: "zero.wav", "wav-zero")
        assertApproxEqual(AudioDuration.duration(of: url) ?? -1, 0.0, tolerance: 0.0001)
    }

    func testWAVWithBadRIFFMagicReturnsNil() {
        let url = write([UInt8](repeating: 0x20, count: 32), name: "bad.wav", "wav-bad-magic")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testWAVMissingFmtChunkReturnsNil() {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        bytes += Array("data".utf8) + le32(4) + [0, 0, 0, 0]
        let url = write(bytes, name: "no-fmt.wav", "wav-no-fmt")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testWAVMissingDataChunkReturnsNil() {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16)
        bytes += [0x01, 0x00, 0x02, 0x00]
        bytes += le32(44_100)
        bytes += le32(176_400)
        bytes += [0x04, 0x00, 0x10, 0x00]
        let url = write(bytes, name: "no-data.wav", "wav-no-data")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testWAVZeroByteRateReturnsNilInsteadOfDividingByZero() {
        let url = write(minimalWAV(dataSize: 100, byteRate: 0), name: "zero-rate.wav", "wav-zero-rate")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    /// A chunk that claims a size running past EOF must be clamped, not over-read —
    /// same bounds discipline the Serato parser already enforces (spec §4).
    func testWAVChunkSizeBeyondEOFDoesNotCrash() {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(0xFFFF_FFF0) // implausible chunk size
        bytes += [0x01, 0x00, 0x02, 0x00]
        let url = write(bytes, name: "huge-chunk.wav", "wav-huge-chunk")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testEmptyFileReturnsNil() {
        let url = write([], name: "empty.wav", "wav-empty")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testNonexistentFileReturnsNilInsteadOfThrowing() {
        let url = Scratch.makeDirectory("wav-missing").appendingPathComponent("does-not-exist.wav")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    /// 80-bit extended-precision 44100 Hz sample rate, numSampleFrames 44100 -> 1.0s.
    /// Bytes are the well-known IEEE-754 80-bit extended encoding of 44100.0.
    private func minimalAIFF(numSampleFrames: UInt32) -> [UInt8] {
        let sampleRate44100: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        var comm: [UInt8] = [0x00, 0x02] // numChannels = 2
        comm += be32(numSampleFrames)
        comm += [0x00, 0x10] // sampleSize = 16
        comm += sampleRate44100
        var bytes = Array("FORM".utf8) + be32(UInt32(4 + 8 + comm.count)) + Array("AIFF".utf8)
        bytes += Array("COMM".utf8) + be32(UInt32(comm.count)) + comm
        return bytes
    }

    func testAIFFDurationComputedFromSampleFramesAndSampleRate() {
        let url = write(minimalAIFF(numSampleFrames: 44_100), name: "one-second.aiff", "aiff-duration")
        assertApproxEqual(AudioDuration.duration(of: url) ?? -1, 1.0, tolerance: 0.001)
    }

    func testAIFCExtensionAliasIsAccepted() {
        let url = write(minimalAIFF(numSampleFrames: 22_050), name: "half-second.aif", "aiff-aif-ext")
        assertApproxEqual(AudioDuration.duration(of: url) ?? -1, 0.5, tolerance: 0.001)
    }

    func testAIFFWithBadFORMMagicReturnsNil() {
        let url = write([UInt8](repeating: 0x20, count: 32), name: "bad.aiff", "aiff-bad-magic")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testAIFFMissingCOMMChunkReturnsNil() {
        var bytes = Array("FORM".utf8) + be32(12) + Array("AIFF".utf8)
        bytes += Array("SSND".utf8) + be32(4) + [0, 0, 0, 0]
        let url = write(bytes, name: "no-comm.aiff", "aiff-no-comm")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testAIFFTruncatedCOMMChunkReturnsNilNotOverRead() {
        var bytes = Array("FORM".utf8) + be32(30) + Array("AIFF".utf8)
        bytes += Array("COMM".utf8) + be32(18) + [0x00, 0x02, 0x00, 0x00] // far short of 18 bytes
        let url = write(bytes, name: "truncated.aiff", "aiff-truncated-comm")
        XCTAssertNil(AudioDuration.duration(of: url))
    }

    func testUnsupportedExtensionReturnsNilOrGracefulResultNeverCrashing() {
        // Off Apple platforms this always returns nil (no AVFoundation); on Apple it
        // attempts AVAudioFile on non-audio bytes, which also fails to nil. Either way
        // the call must not throw or crash.
        let url = write([0x00, 0x01, 0x02, 0x03], name: "x.xyz", "unsupported-ext")
        _ = AudioDuration.duration(of: url)
    }
}

// MARK: - Cross-platform key/value preferences

final class PreferencesTests: XCTestCase {
    /// Unique per-test keys so parallel/repeated runs never collide on the shared
    /// UserDefaults.standard / JSON-fallback-file backing store.
    private func uniqueKey(_ label: String) -> String { "cuesync-test-\(label)-\(UUID().uuidString)" }

    func testStringRoundTripsThroughSetAndGet() {
        let key = uniqueKey("string")
        defer { Preferences.set(nil, forKey: key) }
        Preferences.set("hello world", forKey: key)
        XCTAssertEqual(Preferences.string(forKey: key), "hello world")
    }

    func testUnicodeStringRoundTrips() {
        let key = uniqueKey("unicode")
        defer { Preferences.set(nil, forKey: key) }
        let value = "日本語 Ω café 🎧"
        Preferences.set(value, forKey: key)
        XCTAssertEqual(Preferences.string(forKey: key), value)
    }

    func testUnsetKeyReturnsNilString() {
        XCTAssertNil(Preferences.string(forKey: uniqueKey("never-set")))
    }

    func testSettingNilRemovesTheValue() {
        let key = uniqueKey("remove")
        Preferences.set("temporary", forKey: key)
        XCTAssertEqual(Preferences.string(forKey: key), "temporary")
        Preferences.set(nil, forKey: key)
        XCTAssertNil(Preferences.string(forKey: key))
    }

    func testBoolRoundTripsTrueAndFalse() {
        let key = uniqueKey("bool")
        defer { Preferences.set(false, forKey: key) }
        Preferences.set(true, forKey: key)
        XCTAssertTrue(Preferences.bool(forKey: key))
        Preferences.set(false, forKey: key)
        XCTAssertFalse(Preferences.bool(forKey: key))
    }

    func testUnsetBoolKeyDefaultsToFalse() {
        XCTAssertFalse(Preferences.bool(forKey: uniqueKey("never-set-bool")))
    }

    func testEmptyStringValueRoundTrips() {
        let key = uniqueKey("empty")
        defer { Preferences.set(nil, forKey: key) }
        Preferences.set("", forKey: key)
        XCTAssertEqual(Preferences.string(forKey: key), "")
    }
}
