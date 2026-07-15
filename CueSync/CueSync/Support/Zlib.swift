import Foundation
#if canImport(Compression)
import Compression
#else
import CZlib
#endif

/// Cross-platform raw-DEFLATE (no zlib/gzip header) inflate for the Engine DJ
/// `quickCues` blob (threat model §4: the blob is untrusted, and its declared
/// uncompressed size must never drive an unbounded allocation). Apple's
/// `Compression` framework decodes `COMPRESSION_ZLIB` as raw DEFLATE; everywhere
/// else the vendored `CZlib` is driven with `inflateInit2(&strm, -15)` (negative
/// windowBits selects raw DEFLATE), so both paths decode byte-identically. `cap`
/// bounds the output on both paths — the call aborts once it would be exceeded
/// instead of trusting the untrusted declared size.
enum Zlib {
    static func inflate(_ src: Data, cap: Int) -> Data? {
        guard cap > 0, !src.isEmpty else { return nil }
        #if canImport(Compression)
        return appleInflate(src, cap: cap)
        #else
        return vendoredInflate(src, cap: cap)
        #endif
    }

    #if canImport(Compression)
    /// Fixed-size destination buffer sized only by `cap`, never by the (attacker
    /// controlled) compressed length — a prior version scaled the buffer by
    /// `compressed.count`, which let a large hostile blob drive a multi-GB
    /// allocation even with a small declared size.
    ///
    /// `compression_decode_buffer` has no "truncated" signal — it just stops once
    /// the destination is full and returns however many bytes it wrote, which would
    /// equal `cap` for both "decoded exactly `cap` bytes" and "decoded more than
    /// `cap` bytes but got cut off". Allocating one byte of slack past `cap`
    /// disambiguates: a genuine `cap`-sized result leaves that extra byte unused
    /// (`decodedCount <= cap`), while anything larger fills it too
    /// (`decodedCount == cap + 1`), which is treated as exceeding the cap.
    private static func appleInflate(_ src: Data, cap: Int) -> Data? {
        let bufferSize = cap + 1
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        let decodedCount = src.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, bufferSize, base, src.count, nil, COMPRESSION_ZLIB)
        }
        guard decodedCount > 0, decodedCount <= cap else { return nil }
        return Data(bytes: destination, count: decodedCount)
    }
    #else
    /// Streams through a fixed-size chunk buffer, checking the running output
    /// total against `cap` after every chunk so a decompression bomb aborts mid
    /// stream instead of growing `output` without bound.
    private static func vendoredInflate(_ src: Data, cap: Int) -> Data? {
        var stream = z_stream()
        guard CZlib.inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { CZlib.inflateEnd(&stream) }

        var output = [UInt8]()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var srcBytes = [UInt8](src)

        let finalStatus: Int32 = srcBytes.withUnsafeMutableBufferPointer { srcBuf -> Int32 in
            stream.next_in = srcBuf.baseAddress
            stream.avail_in = UInt32(srcBuf.count)

            var status: Int32 = Z_OK
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { chunkBuf -> Int32 in
                    stream.next_out = chunkBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let r = CZlib.inflate(&stream, Z_NO_FLUSH)
                    let producedCount = chunkSize - Int(stream.avail_out)
                    if producedCount > 0 { output.append(contentsOf: chunkBuf.prefix(producedCount)) }
                    return r
                }
                if output.count > cap { return Z_BUF_ERROR }
            } while status == Z_OK && stream.avail_out == 0
            return status
        }

        guard finalStatus == Z_STREAM_END, output.count <= cap else { return nil }
        return Data(output)
    }
    #endif
}
