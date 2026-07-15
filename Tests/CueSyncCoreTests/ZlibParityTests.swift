import Foundation
import XCTest
#if canImport(Compression)
import Compression
#endif
@testable import CueSyncCore

/// Round-trip / cross-implementation parity for `Support/Zlib.inflate` — exercises
/// the new inflate implementation directly, independent of a real Engine DJ blob
/// (spec §2.E.19). A known buffer is compressed with the vendored `CZlib` (raw
/// DEFLATE, windowBits = -15) and the production `Zlib.inflate` must recover it
/// byte-for-byte; on Apple, `compression_decode_buffer` must agree with the same
/// vendored-encoded bytes, proving the two decoders are interchangeable.
final class ZlibParityTests: XCTestCase {
    private func knownBuffer() -> [UInt8] {
        var rng = XorShift64(seed: 0x5A17_1B00)
        // A mix of repeated and random bytes gives DEFLATE's Huffman/LZ77 stages
        // something realistic to do, unlike an all-zero or all-random buffer.
        var bytes = [UInt8](repeating: 0x2A, count: 512)
        bytes += rng.bytes(2048)
        bytes += Array("CueSync raw-DEFLATE parity fixture".utf8)
        return bytes
    }

    func testVendoredDeflateThenSupportInflateRoundTrips() throws {
        let original = knownBuffer()
        let compressed = ZlibFixtures.rawDeflate(original)
        XCTAssertFalse(compressed.isEmpty, "vendored deflate must produce output")

        let decompressed = Zlib.inflate(Data(compressed), cap: original.count + 256)
        XCTAssertEqual(decompressed, Data(original),
                       "Support/Zlib.inflate must recover the exact bytes deflateInit2(-15) produced")
    }

    func testInflateReturnsNilForCorruptInput() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        XCTAssertNil(Zlib.inflate(garbage, cap: 4096), "corrupt input must fail closed, not crash")
    }

    func testInflateHonorsOutputCap() {
        let original = knownBuffer() // 2048 + 512 + fixture text bytes, well over 64
        let compressed = ZlibFixtures.rawDeflate(original)
        XCTAssertNil(Zlib.inflate(Data(compressed), cap: 64),
                     "a cap smaller than the true decompressed size must abort, not truncate silently")
    }

    #if canImport(Compression)
    /// On Apple, the production path (`compression_decode_buffer`) must decode the
    /// same vendored-encoder bytes identically to the vendored `CZlib` path used
    /// everywhere else — this is the direct cross-implementation check spec item 19
    /// asks for ("on Apple, that the Compression path yields identical bytes").
    func testAppleCompressionPathAgreesWithVendoredEncoderOutput() throws {
        let original = knownBuffer()
        let compressed = ZlibFixtures.rawDeflate(original)

        let cap = original.count + 256
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { destination.deallocate() }
        let decodedCount = compressed.withUnsafeBufferPointer { srcBuf -> Int in
            guard let base = srcBuf.baseAddress else { return 0 }
            return compression_decode_buffer(destination, cap, base, compressed.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(decodedCount, 0)
        let appleDecoded = Data(bytes: destination, count: decodedCount)

        XCTAssertEqual(appleDecoded, Data(original), "Apple's decoder must agree with the vendored encoder's output")

        let supportDecoded = Zlib.inflate(Data(compressed), cap: cap)
        XCTAssertEqual(supportDecoded, appleDecoded, "Support/Zlib.inflate (Apple path) must match the raw Compression decode")
    }
    #endif
}
