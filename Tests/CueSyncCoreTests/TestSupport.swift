import Foundation
import XCTest
import CZlib
@testable import CueSyncCore

// Shared helpers for the CueSyncCoreTests target. Everything here must stay
// deterministic, network-free, and platform-portable (no `/tmp`, no absolute
// paths, no CLI shell-outs) since `swift test` has to pass unchanged on both
// windows-latest and macos-latest (spec §E, item 28).

// MARK: - Sample fixtures (bundled as SwiftPM resources, not absolute paths)

enum Samples {
    static func url(_ name: String) -> URL {
        // `.copy("Fixtures/Samples")` in Package.swift copies the leaf directory into the
        // resource bundle root as "Samples" (SwiftPM does not preserve intermediate path
        // components for a directory resource).
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Samples")
            ?? Bundle.module.bundleURL.appendingPathComponent(name)
    }

    static func string(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}

// MARK: - Scratch directory (FileManager temp dir, never a hardcoded /tmp path)

enum Scratch {
    /// A fresh, per-call temp directory. Callers own cleanup is not required —
    /// FileManager's temporary directory is periodically reclaimed by the OS —
    /// but tests remove their own subdirectory when they can to stay tidy.
    static func makeDirectory(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuesync-core-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UInt64.random(in: .min ... .max))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeFile(_ bytes: [UInt8], name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        try? Data(bytes).write(to: url)
        return url
    }
}

// MARK: - Deterministic PRNG for fuzz inputs (no Date/random-seeded flakiness)

struct XorShift64 {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in byte() } }
}

// MARK: - Domain assertions

extension XCTestCase {
    /// A cue that escaped a parser must always be finite, non-negative, and in-range —
    /// this is the invariant `CuePoint.sanitized()` guarantees and every parser relies on.
    func assertSaneCues(_ cues: [CuePoint], _ context: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        for cue in cues {
            XCTAssertTrue(cue.start.isFinite, "\(context): cue '\(cue.name)' start not finite (\(cue.start))", file: file, line: line)
            XCTAssertTrue(cue.start >= 0, "\(context): cue '\(cue.name)' start negative (\(cue.start))", file: file, line: line)
            XCTAssertTrue(cue.yValue.isFinite, "\(context): cue '\(cue.name)' yValue not finite", file: file, line: line)
            XCTAssertTrue((1...23).contains(cue.curve), "\(context): cue '\(cue.name)' curve out of range (\(cue.curve))", file: file, line: line)
        }
    }

    func assertApproxEqual(_ a: Double, _ b: Double, tolerance: Double = 0.01,
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(a - b) <= tolerance, "\(message) (got \(a), expected ~\(b))", file: file, line: line)
    }
}

// MARK: - Raw-DEFLATE test fixtures (vendored CZlib — available on every platform)

enum ZlibFixtures {
    /// Raw DEFLATE (no zlib/gzip header, windowBits = -15) via the vendored CZlib,
    /// symmetric with `Support/Zlib.inflate`'s vendored decode path. Used to build
    /// realistic compressed test payloads (Engine DJ `quickCues` blobs, zlib parity)
    /// without depending on an Apple-only encoder.
    static func rawDeflate(_ input: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        // CZlib is compiled with Z_PREFIX (Package.swift) so it can coexist with
        // other vendored zlib copies in the same binary; every exported symbol
        // gains a z_ prefix, e.g. deflateInit2_ -> z_deflateInit2_.
        guard CZlib.z_deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return [] }
        defer { CZlib.z_deflateEnd(&stream) }

        var output = [UInt8]()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var src = input

        src.withUnsafeMutableBufferPointer { srcBuf in
            stream.next_in = srcBuf.baseAddress
            stream.avail_in = UInt32(srcBuf.count)
            var status: Int32 = Z_OK
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { chunkBuf -> Int32 in
                    stream.next_out = chunkBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let r = CZlib.z_deflate(&stream, Z_FINISH)
                    let producedCount = chunkSize - Int(stream.avail_out)
                    if producedCount > 0 { output.append(contentsOf: chunkBuf.prefix(producedCount)) }
                    return r
                }
            } while status != Z_STREAM_END && status == Z_OK
        }
        return output
    }
}

// MARK: - Binary fixture builders (Serato / MP3 GEOB payloads — pure Swift, no CLI)

enum BinaryFixtures {
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// Serato CUE entry: "CUE"\0 + big-endian payload length + payload.
    static func cueEntry(_ payload: [UInt8]) -> [UInt8] {
        var e = Array("CUE".utf8)
        e.append(0x00)
        e += be32(UInt32(payload.count))
        e += payload
        return e
    }

    static func cuePayload(index: UInt8, posMs: UInt32,
                           r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0,
                           name: String) -> [UInt8] {
        var p: [UInt8] = [0x00, index]
        p += be32(posMs)
        p.append(0x00)
        p += [r, g, b]
        p.append(0x00)
        p += Array(name.utf8)
        p.append(0x00)
        return p
    }

    static func markers2(_ entries: [[UInt8]]) -> Data {
        var s: [UInt8] = [0x01, 0x01]
        for e in entries { s += e }
        return Data(s)
    }

    static func synchsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    /// Minimal ID3v2.3 MP3 byte stream carrying the given text frames. Non-ASCII text is
    /// declared as UTF-8 (encoding byte 0x03) so it round-trips correctly; pure-ASCII text
    /// uses ISO-8859-1 (0x00), matching what real-world Latin taggers emit.
    static func buildMP3(frames: [(id: String, text: String)]) -> [UInt8] {
        var body: [UInt8] = []
        for f in frames {
            let isASCII = f.text.utf8.allSatisfy { $0 < 0x80 }
            var data: [UInt8] = [isASCII ? 0x00 : 0x03]
            data += Array(f.text.utf8)
            var frame = Array(f.id.utf8)
            frame += be32(UInt32(data.count))
            frame += [0x00, 0x00]
            frame += data
            body += frame
        }
        var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00]
        mp3 += synchsafe(body.count)
        mp3 += body
        mp3 += [UInt8](repeating: 0x00, count: 8)
        return mp3
    }
}
