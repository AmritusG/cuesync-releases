import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Pure-Swift audio-duration probing for formats whose header can be read directly
/// (WAV, AIFF) so duration detection works on every platform. On Apple, other
/// extensions (mp3, m4a, ...) still resolve via `AVAudioFile`; elsewhere they
/// return `nil` and the UI falls back to the manual duration modal.
enum AudioDuration {
    static func duration(of url: URL) -> Double? {
        switch url.pathExtension.lowercased() {
        case "wav": return wavDuration(url: url)
        case "aiff", "aif": return aiffDuration(url: url)
        default:
            #if canImport(AVFoundation)
            return avFoundationDuration(url: url)
            #else
            return nil
            #endif
        }
    }

    // MARK: - WAV (RIFF)

    private static func wavDuration(url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, // "RIFF"
              bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 // "WAVE"
        else { return nil }

        var pos = 12
        var byteRate: UInt32?
        var dataSize: Int?

        while pos + 8 <= bytes.count, byteRate == nil || dataSize == nil {
            let chunkId = String(bytes: bytes[pos..<pos + 4], encoding: .ascii) ?? ""
            let chunkSize = Int(readLE32(bytes, pos + 4))
            let chunkDataStart = pos + 8
            guard chunkSize >= 0, chunkDataStart <= bytes.count else { break }
            let chunkDataEnd = min(chunkDataStart + chunkSize, bytes.count)

            if chunkId == "fmt ", chunkDataEnd - chunkDataStart >= 16 {
                byteRate = readLE32(bytes, chunkDataStart + 8)
            } else if chunkId == "data" {
                dataSize = chunkSize
            }
            // RIFF chunks are padded to an even byte boundary.
            pos = chunkDataStart + chunkSize + (chunkSize % 2)
        }

        guard let rate = byteRate, rate > 0, let size = dataSize else { return nil }
        return Double(size) / Double(rate)
    }

    // MARK: - AIFF (FORM)

    private static func aiffDuration(url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0] == 0x46, bytes[1] == 0x4F, bytes[2] == 0x52, bytes[3] == 0x4D, // "FORM"
              let formType = String(bytes: bytes[8..<12], encoding: .ascii),
              formType == "AIFF" || formType == "AIFC"
        else { return nil }

        var pos = 12
        while pos + 8 <= bytes.count {
            let chunkId = String(bytes: bytes[pos..<pos + 4], encoding: .ascii) ?? ""
            let chunkSize = Int(readBE32(bytes, pos + 4))
            let chunkDataStart = pos + 8
            guard chunkSize >= 0, chunkDataStart <= bytes.count else { break }
            let chunkDataEnd = min(chunkDataStart + chunkSize, bytes.count)

            if chunkId == "COMM", chunkDataEnd - chunkDataStart >= 18 {
                let numSampleFrames = readBE32(bytes, chunkDataStart + 2)
                let sampleRateBytes = Array(bytes[(chunkDataStart + 8)..<(chunkDataStart + 18)])
                guard let sampleRate = parseExtended80(sampleRateBytes), sampleRate > 0 else { return nil }
                return Double(numSampleFrames) / sampleRate
            }
            // AIFF chunks are padded to an even byte boundary.
            pos = chunkDataStart + chunkSize + (chunkSize % 2)
        }
        return nil
    }

    /// 80-bit IEEE 754 extended precision (AIFF's `COMM` sample-rate field) → Double.
    private static func parseExtended80(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 10 else { return nil }
        let signAndExponent = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let sign: Double = (signAndExponent & 0x8000) != 0 ? -1.0 : 1.0
        let exponent = Int(signAndExponent & 0x7FFF) - 16383
        var mantissa: UInt64 = 0
        for i in 0..<8 { mantissa = (mantissa << 8) | UInt64(bytes[2 + i]) }
        guard mantissa > 0 else { return 0 }
        return sign * Double(mantissa) * pow(2.0, Double(exponent - 63))
    }

    // MARK: - Bounded reads

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    #if canImport(AVFoundation)
    private static func avFoundationDuration(url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(audioFile.length) / sampleRate
    }
    #endif
}
