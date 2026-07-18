import Foundation

// MARK: - Result Types

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// parser via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see Models/CuePoint.swift.
public struct SeratoResult {
    public let tracks: [Track]
}

// MARK: - Serato Default Colors

enum SeratoColor {
    static let defaultColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0xCC, 0x00, 0x00), // 0: Red
        (0xCC, 0x88, 0x00), // 1: Orange
        (0xCC, 0xCC, 0x00), // 2: Yellow
        (0x00, 0xCC, 0x00), // 3: Green
        (0x00, 0xCC, 0xCC), // 4: Cyan
        (0x00, 0x00, 0xCC), // 5: Blue
        (0xCC, 0x00, 0xCC), // 6: Purple
        (0xCC, 0x00, 0x88), // 7: Pink
    ]

    static func colorString(r: UInt8, g: UInt8, b: UInt8) -> String {
        "rgb(\(r), \(g), \(b))"
    }

    static func defaultColorString(forIndex index: UInt8) -> String {
        let idx = Int(index) % defaultColors.count
        let c = defaultColors[idx]
        return colorString(r: c.r, g: c.g, b: c.b)
    }
}

// MARK: - Serato Parser

public enum SeratoParser {

    /// Supported audio file extensions for Serato parsing (P1).
    static let supportedExtensions: Set<String> = ["mp3", "aif", "aiff", "wav"]

    /// Parse a single audio file and extract Serato cue points and metadata.
    static func parseFile(at url: URL) throws -> Track {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ParseError.invalidFormat("Unsupported file type: .\(ext). Supported: mp3, aif, aiff, wav")
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw ParseError.noData
        }

        let metadata: ID3Metadata
        let markers2Data: Data?

        switch ext {
        case "mp3":
            let result = try parseMP3(data: data)
            metadata = result.metadata
            markers2Data = result.markers2

        case "aif", "aiff":
            let result = try parseAIFF(data: data)
            metadata = result.metadata
            markers2Data = result.markers2

        case "wav":
            let result = try parseWAV(data: data)
            metadata = result.metadata
            markers2Data = result.markers2

        default:
            throw ParseError.invalidFormat("Unsupported file type: .\(ext)")
        }

        var cuePoints: [CuePoint] = []
        if let markersData = markers2Data {
            cuePoints = parseSeratoMarkers2(data: markersData)
        }

        cuePoints.sort { $0.start < $1.start }

        let trackName = metadata.title ?? url.deletingPathExtension().lastPathComponent

        return Track(
            id: UUID().uuidString,
            name: trackName,
            artist: metadata.artist ?? "",
            album: metadata.album ?? "",
            genre: metadata.genre ?? "",
            totalTime: metadata.duration ?? 0,
            bpm: metadata.bpm ?? 0,
            tonality: metadata.key ?? "",
            location: url.path,
            cuePoints: cuePoints
        )
    }

    /// Parse multiple audio files from a directory or file list.
    public static func parseFiles(at urls: [URL]) -> SeratoResult {
        var tracks: [Track] = []
        for url in urls {
            guard let track = try? parseFile(at: url) else { continue }
            tracks.append(track)
        }
        return SeratoResult(tracks: tracks)
    }

    // MARK: - Serato Markers2 Binary Parsing

    /// Parse the Serato Markers2 payload into CuePoint array.
    static func parseSeratoMarkers2(data: Data) -> [CuePoint] {
        guard data.count >= 2 else { return [] }

        let bytes = Array(data)
        let stream: [UInt8]

        // Check if data starts with version header 0x01 0x01
        if bytes.count >= 2 && bytes[0] == 0x01 && bytes[1] == 0x01 {
            stream = bytes
        } else {
            // Try base64 decoding: strip nulls and newlines first
            guard let decoded = decodeBase64Markers(data) else { return [] }
            let decodedBytes = Array(decoded)
            guard decodedBytes.count >= 2 && decodedBytes[0] == 0x01 && decodedBytes[1] == 0x01 else {
                return []
            }
            stream = decodedBytes
        }

        var cuePoints: [CuePoint] = []
        var pos = 2 // Skip version header

        while pos < stream.count - 1 {
            // Read null-terminated entry type string
            guard let (entryType, nextPos) = readNullTerminatedString(from: stream, at: pos) else {
                break
            }
            pos = nextPos

            // If we hit an empty string, this could be padding at the end
            if entryType.isEmpty {
                // Skip the null byte and try again; Serato sometimes pads with nulls
                continue
            }

            // Read payload length (4 bytes, big-endian)
            guard pos + 4 <= stream.count else { break }
            let payloadLength = readBigEndianUInt32(from: stream, at: pos)
            pos += 4

            guard payloadLength > 0 else { continue }
            guard pos + Int(payloadLength) <= stream.count else { break }

            let payload = Array(stream[pos..<pos + Int(payloadLength)])
            pos += Int(payloadLength)

            if entryType == "CUE" && payloadLength >= 13 {
                if let cue = parseCuePayload(payload) {
                    cuePoints.append(cue)
                }
            }
            // LOOP, BPMLOCK, COLOR, etc. are ignored for now
        }

        return cuePoints.map { $0.sanitized() }
    }

    /// Parse a single CUE entry payload.
    private static func parseCuePayload(_ payload: [UInt8]) -> CuePoint? {
        guard payload.count >= 11 else { return nil }

        // Byte 0: always 0x00 (skip)
        let cueIndex = payload[1]

        // Bytes 2-5: position in milliseconds (big-endian uint32)
        let positionMs = readBigEndianUInt32(from: payload, at: 2)
        let positionSeconds = Double(positionMs) / 1000.0

        // Byte 6: always 0x00 (skip)

        // Bytes 7-9: RGB color
        let r = payload[7]
        let g = payload[8]
        let b = payload[9]

        // Byte 10: always 0x00 (skip)

        // Byte 11+: null-terminated UTF-8 name
        var name = ""
        if payload.count > 11 {
            if let (parsed, _) = readNullTerminatedString(from: payload, at: 11) {
                name = parsed
            }
        }

        if name.isEmpty {
            // Int() promotion avoids a UInt8 overflow trap when cueIndex == 255.
            name = "Cue \(Int(cueIndex) + 1)"
        }

        // Determine color: use the embedded color if non-zero, otherwise fall back to default
        let color: String
        if r == 0 && g == 0 && b == 0 {
            color = SeratoColor.defaultColorString(forIndex: cueIndex)
        } else {
            color = SeratoColor.colorString(r: r, g: g, b: b)
        }

        return CuePoint(
            id: UUID().uuidString,
            start: positionSeconds,
            name: name,
            color: color,
            yValue: 100.0,
            curve: 1,
            enabled: true
        )
    }

    /// Decode base64-encoded Serato markers data, stripping nulls and newlines.
    private static func decodeBase64Markers(_ data: Data) -> Data? {
        // Strip null bytes and newlines, then base64 decode
        let filtered = data.filter { byte in
            byte != 0x00 && byte != 0x0A && byte != 0x0D
        }
        guard let base64String = String(data: Data(filtered), encoding: .utf8) else {
            return nil
        }
        return Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
    }

    // MARK: - MP3 (ID3v2) Parsing

    private struct TagParseResult {
        let metadata: ID3Metadata
        let markers2: Data?
    }

    /// Parse an MP3 file: find ID3v2 tag, extract metadata and Serato Markers2 GEOB frame.
    private static func parseMP3(data: Data) throws -> TagParseResult {
        let bytes = Array(data)
        guard bytes.count >= 10 else {
            throw ParseError.invalidFormat("File too small to contain ID3v2 tag")
        }

        // ID3v2 header: "ID3" + version (2 bytes) + flags (1 byte) + size (4 bytes synchsafe)
        guard bytes[0] == 0x49, // 'I'
              bytes[1] == 0x44, // 'D'
              bytes[2] == 0x33  // '3'
        else {
            // No ID3v2 tag found; return empty metadata
            return TagParseResult(metadata: ID3Metadata(), markers2: nil)
        }

        let majorVersion = bytes[3]
        let flags = bytes[5]
        let tagSize = readSynchsafeInt(from: bytes, at: 6)

        guard tagSize > 0 && 10 + tagSize <= bytes.count else {
            return TagParseResult(metadata: ID3Metadata(), markers2: nil)
        }

        // Check for extended header
        var frameStart = 10
        if flags & 0x40 != 0 && majorVersion >= 3 {
            // Extended header present
            if frameStart + 4 <= bytes.count {
                let extSize: Int
                if majorVersion == 4 {
                    extSize = readSynchsafeInt(from: bytes, at: frameStart)
                } else {
                    extSize = Int(readBigEndianUInt32(from: bytes, at: frameStart))
                }
                frameStart += extSize
            }
        }

        let tagEnd = min(10 + tagSize, bytes.count)
        return parseID3v2Frames(bytes: bytes, from: frameStart, to: tagEnd, version: majorVersion)
    }

    /// Parse ID3v2 frames to extract metadata and Serato GEOB tag.
    private static func parseID3v2Frames(bytes: [UInt8], from start: Int, to end: Int, version: UInt8) -> TagParseResult {
        var metadata = ID3Metadata()
        var markers2Data: Data?
        var pos = start

        // ID3v2.2 uses 3-byte frame IDs + 3-byte size; ID3v2.3/2.4 use 4-byte frame IDs + 4-byte size
        let isV22 = version == 2
        let frameHeaderSize = isV22 ? 6 : 10

        while pos + frameHeaderSize <= end {
            // Read frame ID
            let frameIdBytes: [UInt8]
            if isV22 {
                frameIdBytes = Array(bytes[pos..<pos + 3])
            } else {
                frameIdBytes = Array(bytes[pos..<pos + 4])
            }

            // Check for padding (all zeros)
            if frameIdBytes.allSatisfy({ $0 == 0 }) { break }

            guard let frameId = String(bytes: frameIdBytes, encoding: .ascii),
                  frameId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                break
            }

            // Read frame size
            let frameSize: Int
            if isV22 {
                frameSize = (Int(bytes[pos + 3]) << 16) | (Int(bytes[pos + 4]) << 8) | Int(bytes[pos + 5])
            } else if version == 4 {
                frameSize = readSynchsafeInt(from: bytes, at: pos + 4)
            } else {
                frameSize = Int(readBigEndianUInt32(from: bytes, at: pos + 4))
            }

            let frameDataStart = pos + frameHeaderSize
            pos = frameDataStart + frameSize

            guard frameSize > 0 && frameDataStart + frameSize <= end else { continue }

            let frameData = Array(bytes[frameDataStart..<frameDataStart + frameSize])

            // Parse text frames for metadata
            switch frameId {
            case "TIT2", "TT2":
                metadata.title = parseID3TextFrame(frameData)
            case "TPE1", "TP1":
                metadata.artist = parseID3TextFrame(frameData)
            case "TALB", "TAL":
                metadata.album = parseID3TextFrame(frameData)
            case "TCON", "TCO":
                metadata.genre = parseID3TextFrame(frameData)
            case "TBPM", "TBP":
                if let text = parseID3TextFrame(frameData), let bpm = Double(text), bpm.isFinite {
                    metadata.bpm = bpm
                }
            case "TKEY", "TKE":
                metadata.key = parseID3TextFrame(frameData)
            case "TLEN", "TLE":
                // Guard before Int(): Double("nan"/"inf") parses, and a huge value would
                // overflow Int — both trap. Cap at ~31 years of milliseconds.
                if let text = parseID3TextFrame(frameData), let ms = Double(text),
                   ms.isFinite, ms >= 0, ms < 1e15 {
                    metadata.duration = Int(ms / 1000.0)
                }
            case "GEOB", "GEO":
                // General Encapsulated Object - check for Serato Markers2
                if let seratoData = parseGEOBFrame(frameData, isV22: isV22) {
                    markers2Data = seratoData
                }
            default:
                break
            }
        }

        return TagParseResult(metadata: metadata, markers2: markers2Data)
    }

    /// Parse a GEOB frame and return the object data if it's a Serato Markers2 tag.
    private static func parseGEOBFrame(_ data: [UInt8], isV22: Bool) -> Data? {
        guard data.count > 4 else { return nil }

        let encoding = data[0]
        var pos = 1

        // Read MIME type (null-terminated in the encoding indicated by byte 0,
        // but MIME is always Latin-1/ASCII per spec)
        guard let (_, mimeEnd) = readNullTerminatedString(from: data, at: pos) else { return nil }
        pos = mimeEnd

        // Read filename (null-terminated; encoding depends on byte 0)
        guard let (_, filenameEnd) = readNullTerminatedStringEncoded(from: data, at: pos, encoding: encoding) else {
            return nil
        }
        pos = filenameEnd

        // Read content description (null-terminated; encoding depends on byte 0)
        guard let (description, descEnd) = readNullTerminatedStringEncoded(from: data, at: pos, encoding: encoding) else {
            return nil
        }
        pos = descEnd

        // Check if this is the Serato Markers2 GEOB
        guard description == "Serato Markers2" else { return nil }

        // Remaining bytes are the encapsulated object data
        guard pos < data.count else { return nil }
        return Data(data[pos..<data.count])
    }

    // MARK: - AIFF (ID3v2 in ID3 chunk) Parsing

    /// Parse an AIFF file: find the ID3 chunk, then extract metadata and Serato Markers2.
    private static func parseAIFF(data: Data) throws -> TagParseResult {
        let bytes = Array(data)

        // AIFF files start with FORM....AIFF or FORM....AIFC
        guard bytes.count >= 12,
              bytes[0] == 0x46, bytes[1] == 0x4F, bytes[2] == 0x52, bytes[3] == 0x4D // "FORM"
        else {
            throw ParseError.invalidFormat("Not a valid AIFF file")
        }

        let formType = String(bytes: Array(bytes[8..<12]), encoding: .ascii) ?? ""
        guard formType == "AIFF" || formType == "AIFC" else {
            throw ParseError.invalidFormat("Not a valid AIFF file (form type: \(formType))")
        }

        // Iterate chunks starting at offset 12
        var pos = 12
        while pos + 8 <= bytes.count {
            let chunkId = String(bytes: Array(bytes[pos..<pos + 4]), encoding: .ascii) ?? ""
            let chunkSize = Int(readBigEndianUInt32(from: bytes, at: pos + 4))
            let chunkDataStart = pos + 8

            // A zero-size chunk must be skipped, not break the scan — the ID3 chunk
            // (with Serato markers) often comes after other chunks.
            if chunkSize == 0 {
                pos = chunkDataStart
                continue
            }

            if chunkId == "ID3 " || chunkId == "ID3" {
                // Found ID3 chunk; parse as ID3v2
                let chunkEnd = min(chunkDataStart + chunkSize, bytes.count)
                let id3Bytes = Array(bytes[chunkDataStart..<chunkEnd])

                guard id3Bytes.count >= 10,
                      id3Bytes[0] == 0x49, id3Bytes[1] == 0x44, id3Bytes[2] == 0x33 else {
                    // Chunk labeled ID3 but doesn't contain valid ID3v2
                    break
                }

                let version = id3Bytes[3]
                let flags = id3Bytes[5]
                let tagSize = readSynchsafeInt(from: id3Bytes, at: 6)

                var frameStart = 10
                if flags & 0x40 != 0 && version >= 3 {
                    if frameStart + 4 <= id3Bytes.count {
                        let extSize = version == 4
                            ? readSynchsafeInt(from: id3Bytes, at: frameStart)
                            : Int(readBigEndianUInt32(from: id3Bytes, at: frameStart))
                        frameStart += extSize
                    }
                }

                let tagEnd = min(10 + tagSize, id3Bytes.count)
                return parseID3v2Frames(bytes: id3Bytes, from: frameStart, to: tagEnd, version: version)
            }

            // Advance to next chunk (AIFF chunks are padded to even byte boundaries)
            pos = chunkDataStart + chunkSize
            if chunkSize % 2 != 0 { pos += 1 }
        }

        // No ID3 chunk found
        return TagParseResult(metadata: ID3Metadata(), markers2: nil)
    }

    // MARK: - WAV (RIFF) Parsing

    /// Parse a WAV file: find "serato_markers2" chunk in the RIFF structure.
    private static func parseWAV(data: Data) throws -> TagParseResult {
        let bytes = Array(data)

        // WAV files start with RIFF....WAVE
        guard bytes.count >= 12,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 // "RIFF"
        else {
            throw ParseError.invalidFormat("Not a valid WAV file")
        }

        let formType = String(bytes: Array(bytes[8..<12]), encoding: .ascii) ?? ""
        guard formType == "WAVE" else {
            throw ParseError.invalidFormat("Not a valid WAV file (form type: \(formType))")
        }

        var metadata = ID3Metadata()
        var markers2Data: Data?

        // Iterate chunks starting at offset 12
        // WAV uses little-endian chunk sizes
        var pos = 12
        while pos + 8 <= bytes.count {
            let chunkId = String(bytes: Array(bytes[pos..<pos + 4]), encoding: .ascii) ?? ""
            let chunkSize = Int(readLittleEndianUInt32(from: bytes, at: pos + 4))
            let chunkDataStart = pos + 8

            guard chunkSize >= 0 && chunkDataStart <= bytes.count else { break }

            let safeChunkEnd = min(chunkDataStart + chunkSize, bytes.count)

            // Some WAV files have an ID3 chunk
            if chunkId == "ID3 " || chunkId == "id3 " || chunkId == "ID3" {
                let id3Bytes = Array(bytes[chunkDataStart..<safeChunkEnd])
                if id3Bytes.count >= 10 && id3Bytes[0] == 0x49 && id3Bytes[1] == 0x44 && id3Bytes[2] == 0x33 {
                    let version = id3Bytes[3]
                    let flags = id3Bytes[5]
                    let tagSize = readSynchsafeInt(from: id3Bytes, at: 6)
                    var frameStart = 10
                    if flags & 0x40 != 0 && version >= 3 {
                        if frameStart + 4 <= id3Bytes.count {
                            let extSize = version == 4
                                ? readSynchsafeInt(from: id3Bytes, at: frameStart)
                                : Int(readBigEndianUInt32(from: id3Bytes, at: frameStart))
                            frameStart += extSize
                        }
                    }
                    let tagEnd = min(10 + tagSize, id3Bytes.count)
                    let result = parseID3v2Frames(bytes: id3Bytes, from: frameStart, to: tagEnd, version: version)
                    metadata = result.metadata
                    if result.markers2 != nil {
                        markers2Data = result.markers2
                    }
                }
            }

            // Serato in WAV embeds markers in a LIST chunk or custom sub-chunks.
            // Look for the Serato Markers2 signature inside LIST chunks.
            if chunkId == "LIST" && chunkSize > 4 {
                // Iterate sub-chunks inside the LIST (skip 4-byte list type identifier)
                var subPos = chunkDataStart + 4
                while subPos + 8 <= safeChunkEnd {
                    let _ = String(bytes: Array(bytes[subPos..<subPos + 4]), encoding: .ascii) ?? ""
                    let subSize = Int(readLittleEndianUInt32(from: bytes, at: subPos + 4))
                    let subDataStart = subPos + 8

                    guard subSize >= 0 && subDataStart <= safeChunkEnd else { break }

                    let safeSubEnd = min(subDataStart + subSize, safeChunkEnd)

                    // Check if the sub-chunk data contains "Serato Markers2"
                    if let found = findSeratoMarkers2InChunk(bytes: bytes, from: subDataStart, to: safeSubEnd) {
                        markers2Data = found
                    }

                    subPos = subDataStart + subSize
                    if subSize % 2 != 0 { subPos += 1 }
                }

                // Also check the LIST data directly
                if markers2Data == nil {
                    if let found = findSeratoMarkers2InChunk(bytes: bytes, from: chunkDataStart, to: safeChunkEnd) {
                        markers2Data = found
                    }
                }
            }

            // Direct custom chunk: Serato may use a chunk whose data starts with "Serato Markers2".
            // Skip the audio "data"/"fmt " chunks — markers are never there, and brute-force
            // scanning a multi-MB audio payload byte-by-byte is needlessly slow.
            if markers2Data == nil && chunkSize > 0 && chunkId != "data" && chunkId != "fmt " {
                if let found = findSeratoMarkers2InChunk(bytes: bytes, from: chunkDataStart, to: safeChunkEnd) {
                    markers2Data = found
                }
            }

            // Advance to next chunk (RIFF chunks are padded to even byte boundaries)
            pos = chunkDataStart + chunkSize
            if chunkSize % 2 != 0 { pos += 1 }
        }

        return TagParseResult(metadata: metadata, markers2: markers2Data)
    }

    /// Search a chunk region for "Serato Markers2" signature and return the payload data after it.
    private static func findSeratoMarkers2InChunk(bytes: [UInt8], from start: Int, to end: Int) -> Data? {
        let needle: [UInt8] = Array("Serato Markers2".utf8)
        guard end - start > needle.count else { return nil }

        let region = Array(bytes[start..<end])

        // Look for the marker string
        for i in 0..<(region.count - needle.count) {
            if region[i..<i + needle.count].elementsEqual(needle) {
                // Found it. The payload follows after the null terminator of the string.
                var payloadStart = i + needle.count
                // Skip null terminator if present
                if payloadStart < region.count && region[payloadStart] == 0x00 {
                    payloadStart += 1
                }
                guard payloadStart < region.count else { return nil }
                return Data(region[payloadStart..<region.count])
            }
        }

        return nil
    }

    // MARK: - ID3 Text Frame Parsing

    /// Parse an ID3v2 text frame (TIT2, TPE1, etc.) returning the text content.
    private static func parseID3TextFrame(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }

        let encoding = data[0]
        let textBytes = Array(data[1...])
        return decodeID3String(textBytes, encoding: encoding)
    }

    /// Decode a string from ID3v2 frame data using the specified encoding byte.
    private static func decodeID3String(_ bytes: [UInt8], encoding: UInt8) -> String? {
        guard !bytes.isEmpty else { return nil }

        // Remove trailing nulls
        var cleaned = bytes
        while let last = cleaned.last, last == 0x00 {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty else { return nil }

        switch encoding {
        case 0x00:
            // ISO-8859-1 (Latin-1)
            return String(bytes: cleaned, encoding: .isoLatin1)
        case 0x01:
            // UTF-16 with BOM
            return decodeUTF16(cleaned)
        case 0x02:
            // UTF-16BE without BOM
            return String(bytes: cleaned, encoding: .utf16BigEndian)
        case 0x03:
            // UTF-8
            return String(bytes: cleaned, encoding: .utf8)
        default:
            // Try UTF-8, then Latin-1 as fallback
            return String(bytes: cleaned, encoding: .utf8) ?? String(bytes: cleaned, encoding: .isoLatin1)
        }
    }

    /// Decode UTF-16 data that may have a BOM.
    private static func decodeUTF16(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }

        // Check BOM
        if bytes[0] == 0xFF && bytes[1] == 0xFE {
            // UTF-16LE
            let payload = Array(bytes[2...])
            // Remove trailing nulls (UTF-16 null = 0x00 0x00)
            var cleaned = payload
            while cleaned.count >= 2 && cleaned[cleaned.count - 1] == 0x00 && cleaned[cleaned.count - 2] == 0x00 {
                cleaned.removeLast(2)
            }
            return String(bytes: cleaned, encoding: .utf16LittleEndian)
        } else if bytes[0] == 0xFE && bytes[1] == 0xFF {
            // UTF-16BE
            let payload = Array(bytes[2...])
            var cleaned = payload
            while cleaned.count >= 2 && cleaned[cleaned.count - 1] == 0x00 && cleaned[cleaned.count - 2] == 0x00 {
                cleaned.removeLast(2)
            }
            return String(bytes: cleaned, encoding: .utf16BigEndian)
        }

        // No BOM, assume UTF-16LE (common on Windows/Serato)
        return String(bytes: bytes, encoding: .utf16LittleEndian)
    }

    // MARK: - Binary Helpers

    /// Read a null-terminated ASCII/UTF-8 string from a byte array.
    /// Returns the string and the position immediately after the null terminator.
    private static func readNullTerminatedString(from bytes: [UInt8], at offset: Int) -> (String, Int)? {
        guard offset < bytes.count else { return nil }

        var end = offset
        while end < bytes.count && bytes[end] != 0x00 {
            end += 1
        }

        let strBytes = Array(bytes[offset..<end])
        let string = String(bytes: strBytes, encoding: .utf8) ?? String(bytes: strBytes, encoding: .isoLatin1) ?? ""

        // Skip past the null terminator
        let nextPos = end < bytes.count ? end + 1 : end
        return (string, nextPos)
    }

    /// Read a null-terminated string with ID3 encoding awareness.
    /// For UTF-16 encodings, the null terminator is two zero bytes.
    private static func readNullTerminatedStringEncoded(from bytes: [UInt8], at offset: Int, encoding: UInt8) -> (String, Int)? {
        guard offset < bytes.count else { return nil }

        let isUTF16 = encoding == 0x01 || encoding == 0x02

        if isUTF16 {
            // UTF-16: null terminator is 0x00 0x00
            var end = offset
            while end + 1 < bytes.count {
                if bytes[end] == 0x00 && bytes[end + 1] == 0x00 {
                    break
                }
                end += 2
            }
            let strBytes = Array(bytes[offset..<min(end, bytes.count)])
            let string = decodeID3String(strBytes, encoding: encoding) ?? ""
            let nextPos = min(end + 2, bytes.count)
            return (string, nextPos)
        } else {
            // Single-byte encoding: null terminator is one 0x00
            return readNullTerminatedString(from: bytes, at: offset)
        }
    }

    /// Read a big-endian uint32 from a byte array.
    private static func readBigEndianUInt32(from bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    /// Read a little-endian uint32 from a byte array.
    private static func readLittleEndianUInt32(from bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Read a synchsafe integer (ID3v2 format: 7 bits per byte, MSB always 0).
    private static func readSynchsafeInt(from bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return (Int(bytes[offset] & 0x7F) << 21)
            | (Int(bytes[offset + 1] & 0x7F) << 14)
            | (Int(bytes[offset + 2] & 0x7F) << 7)
            | Int(bytes[offset + 3] & 0x7F)
    }
}

// MARK: - ID3 Metadata Container

private struct ID3Metadata {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var bpm: Double?
    var key: String?
    var duration: Int?
}
