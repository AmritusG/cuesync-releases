import Foundation

// Test suite for CueSync's standalone-compilable surface: Models, Parsers, Exporters.
// The runner + assertion helpers + XorShift64 + loadSample live in main.swift.
// SwiftUI types (AppState, Views) are not part of this build.

// MARK: - Binary fixture helpers

private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24),
     UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8),
     UInt8(truncatingIfNeeded: v)]
}

/// Build a Serato CUE entry: "CUE"\0 + big-endian payload length + payload.
private func cueEntry(_ payload: [UInt8]) -> [UInt8] {
    var e = Array("CUE".utf8)
    e.append(0x00)
    e += be32(UInt32(payload.count))
    e += payload
    return e
}

/// Build a well-formed CUE payload (>= 13 bytes when name non-empty).
private func cuePayload(index: UInt8, posMs: UInt32,
                        r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0,
                        name: String) -> [UInt8] {
    var p: [UInt8] = [0x00, index]
    p += be32(posMs)        // bytes 2..5 position
    p.append(0x00)          // byte 6
    p += [r, g, b]          // bytes 7,8,9 color
    p.append(0x00)          // byte 10
    p += Array(name.utf8)   // byte 11+ name
    p.append(0x00)          // null terminator
    return p
}

private func markers2(_ entries: [[UInt8]]) -> Data {
    var s: [UInt8] = [0x01, 0x01]
    for e in entries { s += e }
    return Data(s)
}

private func synchsafe(_ n: Int) -> [UInt8] {
    [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
}

/// Build a minimal ID3v2.3 MP3 byte stream carrying the given Latin-1 text frames.
private func buildMP3(frames: [(id: String, text: String)]) -> [UInt8] {
    var body: [UInt8] = []
    for f in frames {
        var data: [UInt8] = [0x00]              // text encoding: ISO-8859-1
        data += Array(f.text.utf8)
        var frame = Array(f.id.utf8)            // 4-byte frame ID
        frame += be32(UInt32(data.count))       // frame size (big-endian in v2.3)
        frame += [0x00, 0x00]                    // frame flags
        frame += data
        body += frame
    }
    var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00]  // v2.3.0, no header flags
    mp3 += synchsafe(body.count)
    mp3 += body
    mp3 += [UInt8](repeating: 0x00, count: 8)   // trailing padding
    return mp3
}

private let fixturesDir = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["CUESYNC_FIXTURES"] ?? "/tmp/cuesync-test-fixtures")

private func writeTemp(_ bytes: [UInt8], ext: String) -> URL {
    let url = tmpDir.appendingPathComponent("fix-\(bytes.count)-\(ext).\(ext)")
    try? Data(bytes).write(to: url)
    return url
}

private func approxEq(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool {
    abs(a - b) <= tol
}

/// Raw string value of attribute `name` from every `<point …>` line of an envelope XML.
private func pointAttrStrings(_ xml: String, _ name: String) -> [String] {
    var out: [String] = []
    for line in xml.split(separator: "\n") where line.contains("<point") {
        guard let r = line.range(of: "\(name)=\"") else { continue }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        out.append(String(rest[..<end]))
    }
    return out
}

private func decimalPlaces(_ s: String) -> Int {
    guard let dot = s.firstIndex(of: ".") else { return 0 }
    return s.distance(from: s.index(after: dot), to: s.endIndex)
}

// MARK: - Tests

let allTests: [(name: String, fn: () throws -> Void)] = [

    // ---------------------------------------------------------------- Models

    ("curve-evaluate-finite", {
        // Every curve must produce a finite value across the whole domain,
        // including out-of-range t (which the function clamps).
        let ts: [Double] = [-1, 0, 0.0001, 0.25, 0.5, 0.75, 0.9999, 1, 2, .infinity, -.infinity, .nan]
        for c in 0...25 {            // includes out-of-range 0, 24, 25
            for t in ts {
                let v = CurveType.evaluate(c, t: t)
                expect(v.isFinite, "curve \(c) at t=\(t) not finite (\(v))")
            }
        }
    }),

    ("curve-known-values", {
        expect(approxEq(CurveType.evaluate(1, t: 0.5), 0.5), "linear midpoint")
        expect(approxEq(CurveType.evaluate(2, t: 0.5), 0.25), "quad-in midpoint")
        expect(approxEq(CurveType.evaluate(3, t: 0.5), 0.75), "quad-out midpoint")
        expect(approxEq(CurveType.evaluate(7, t: 0.5), 0.5), "sine in/out midpoint")
        expectEq(CurveType.evaluate(23, t: 0.7), 0.0, "hold is always 0")
        // Endpoints land on 0/1 for the non-overshooting families.
        for c in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 23] {
            expect(approxEq(CurveType.evaluate(c, t: 0), c == 23 ? 0 : 0), "curve \(c) starts ~0")
        }
    }),

    ("curve-names-and-grouping", {
        for id in 1...23 {
            expect(!CurveType.name(for: id).isEmpty, "curve \(id) has a name")
        }
        expectEq(CurveType.name(for: 0), "Linear", "out-of-range curve name falls back to Linear")
        expectEq(CurveType.name(for: 999), "Linear", "out-of-range curve name falls back to Linear")
        let grouped = CurveType.grouped.flatMap { $0.curves }
        expectEq(grouped.count, 23, "grouping covers all 23 curves")
    }),

    ("cuepoint-normalize", {
        let c = CuePoint.makeDefault(at: 30, name: "x")
        expect(approxEq(c.normalizedX(duration: 60), 0.5), "normalizedX midpoint")
        expectEq(c.normalizedX(duration: 0), 0, "normalizedX with zero duration is 0")
        // Out-of-range / non-finite inputs must stay clamped & finite.
        var bad = CuePoint.makeDefault(at: -10, name: "neg")
        expect(bad.normalizedX(duration: 60) >= 0, "negative start clamps to >= 0")
        bad.yValue = 250
        expect(bad.normalizedY <= 1 && bad.normalizedY >= 0, "yValue clamps into 0...1")
    }),

    ("cuepoint-sanitize", {
        // sanitized() must guarantee finite, non-negative start; yValue 0...100; curve 1...23.
        let cases: [(Double, Double, Int)] = [
            (.nan, .nan, 0), (.infinity, .infinity, 99), (-.infinity, -5, -1),
            (-10, 150, 24), (1e18, 50, 12), (5, 50, 1),
        ]
        for (start, y, curve) in cases {
            var c = CuePoint.makeDefault()
            c.start = start; c.yValue = y; c.curve = curve
            let s = c.sanitized()
            expect(s.start.isFinite && s.start >= 0, "sanitized start finite & >= 0 (was \(start) -> \(s.start))")
            expect(s.yValue.isFinite && s.yValue >= 0 && s.yValue <= 100, "sanitized yValue in 0...100 (was \(y) -> \(s.yValue))")
            expect((1...23).contains(s.curve), "sanitized curve in 1...23 (was \(curve) -> \(s.curve))")
        }
        // A valid cue is unchanged.
        var ok = CuePoint.makeDefault(at: 5, name: "ok")
        ok.yValue = 42; ok.curve = 7
        let s = ok.sanitized()
        expectEq(s.start, 5, "valid start preserved")
        expectEq(s.yValue, 42, "valid yValue preserved")
        expectEq(s.curve, 7, "valid curve preserved")
    }),

    ("track-and-playlist", {
        var t = Track(id: "1", name: "n", artist: "a", album: "", genre: "", totalTime: 125, bpm: 0, tonality: "", location: "", cuePoints: [])
        expectEq(t.formattedDuration, "2:05", "formatted duration")
        t.totalTime = 0
        expectEq(t.formattedDuration, "0:00", "zero duration formats cleanly")
        t.totalTime = -5
        expectEq(t.formattedDuration, "0:00", "negative duration clamps to 0:00")
        let leaf = Playlist(id: "p1", name: "P", type: .playlist, trackIds: ["a", "b", "c"], children: [])
        expectEq(leaf.totalTrackCount(), 3, "leaf track count")
        let folder = Playlist(id: "f1", name: "F", type: .folder, trackIds: [], children: [leaf])
        expectEq(folder.totalTrackCount(), 3, "folder recursive track count")
    }),

    // ------------------------------------------------------------ Rekordbox

    ("rekordbox-sample", {
        let xml = try loadSample("sample-rekordbox.xml")
        let result = try RekordboxParser.parse(xml: xml)
        expect(!result.tracks.isEmpty, "sample has tracks")
        for t in result.tracks { expectSaneCues(t.cuePoints, "rekordbox-sample/\(t.name)") }
    }),

    ("rekordbox-real-library", {
        let xml = try loadSample("real-rekordbox-library.xml")
        let result = try RekordboxParser.parse(xml: xml)
        expect(result.tracks.count > 1, "real library has many tracks (\(result.tracks.count))")
        var cueTotal = 0
        for t in result.tracks {
            expectSaneCues(t.cuePoints, "rekordbox-real/\(t.name)")
            cueTotal += t.cuePoints.count
        }
        // Cues should be sorted ascending within each track.
        for t in result.tracks {
            let starts = t.cuePoints.map(\.start)
            expectEq(starts, starts.sorted(), "cues sorted for \(t.name)")
        }
        expect(cueTotal >= 0, "parsed cue total \(cueTotal)")
    }),

    ("rekordbox-malformed-values", {
        // nan/inf/negative Start, garbage numerics must not yield insane cues.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="1">
            <TRACK TrackID="1" Name="Bad" TotalTime="abc" AverageBpm="xyz">
              <POSITION_MARK Name="n" Type="0" Start="nan" Num="0"/>
              <POSITION_MARK Name="i" Type="0" Start="inf" Num="1"/>
              <POSITION_MARK Name="neg" Type="0" Start="-50" Num="2"/>
              <POSITION_MARK Name="huge" Type="0" Start="1e30" Num="3"/>
            </TRACK>
          </COLLECTION>
        </DJ_PLAYLISTS>
        """
        let result = try RekordboxParser.parse(xml: xml)
        for t in result.tracks {
            expectSaneCues(t.cuePoints, "rekordbox-malformed/\(t.name)")
            expect(t.totalTime >= 0, "totalTime non-negative")
            expect(t.bpm.isFinite, "bpm finite")
        }
    }),

    ("rekordbox-invalid-xml", {
        expectThrows("non-XML input throws") {
            _ = try RekordboxParser.parse(xml: "this is not xml < & >")
        }
    }),

    ("rekordbox-fuzz", {
        var rng = XorShift64(seed: 0xCAFE)
        let base = (try? loadSample("sample-rekordbox.xml")) ?? "<x/>"
        let baseBytes = Array(base.utf8)
        for _ in 0..<150 {
            // Mutate a copy of the sample at random byte offsets.
            var bytes = baseBytes
            let flips = Int(rng.next() % 30)
            for _ in 0..<flips where !bytes.isEmpty {
                bytes[Int(rng.next() % UInt64(bytes.count))] = rng.byte()
            }
            let s = String(decoding: bytes, as: UTF8.self)
            if let r = try? RekordboxParser.parse(xml: s) {
                for t in r.tracks { expectSaneCues(t.cuePoints, "rekordbox-fuzz") }
            }
        }
    }),

    // ---------------------------------------------------------- ShowKontrol

    ("showkontrol-sample", {
        let content = try loadSample("sample-showkontrol.cue")
        let result = try ShowKontrolParser.parse(content: content)
        expect(!result.cuePoints.isEmpty, "sample has cues")
        expectSaneCues(result.cuePoints, "showkontrol-sample")
        expect(result.cuePoints.contains { $0.start <= 0.001 }, "a start point exists")
    }),

    ("showkontrol-real", {
        let content = try loadSample("real-showkontrol.cue")
        let result = try ShowKontrolParser.parse(content: content)
        expectSaneCues(result.cuePoints, "showkontrol-real")
    }),

    ("showkontrol-empty", {
        expectThrows("empty content throws noData") {
            _ = try ShowKontrolParser.parse(content: "")
        }
        expectThrows("whitespace-only throws noData") {
            _ = try ShowKontrolParser.parse(content: "\r\n   \r\n")
        }
    }),

    ("showkontrol-malformed-ms", {
        // Non-finite / negative milliseconds must produce sane cues.
        let content = "00:00:00:00,00000000,nan,A,TAG,,,,,,\r" +
                      "00:00:01:00,00000100,inf,B,TAG,,,,,,\r" +
                      "00:00:02:00,00000200,-5000,C,TAG,,,,,,\r" +
                      "00:00:03:00,00000300,1e30,D,TAG,,,,,,\r"
        let result = try ShowKontrolParser.parse(content: content)
        expectSaneCues(result.cuePoints, "showkontrol-malformed-ms")
        if let dur = result.suggestedDurationMs { expect(dur.isFinite, "suggested duration finite") }
    }),

    ("showkontrol-fuzz", {
        var rng = XorShift64(seed: 0x5C5C)
        for _ in 0..<200 {
            let len = Int(rng.next() % 200)
            let s = String(decoding: rng.bytes(len), as: UTF8.self)
            if let r = try? ShowKontrolParser.parse(content: s) {
                expectSaneCues(r.cuePoints, "showkontrol-fuzz")
            }
        }
    }),

    // -------------------------------------------------- ShowKontrol export

    ("showkontrol-export-basic", {
        let cues = [
            CuePoint(id: "a", start: 0, name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 65.5, name: "Drop, here", color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        let out = ShowKontrolExporter.generate(cuePoints: cues)
        expect(out != nil, "export produced output")
        let text = out ?? ""
        expect(text.contains("\r"), "uses CR separator")
        expect(!text.contains("Drop, here"), "commas stripped from names")
        let tc = ShowKontrolExporter.secondsToTimecode(65.5)
        expectEq(tc.formatted.count, 11, "HH:MM:SS:FF is 11 chars")
        expectEq(tc.milliseconds, 65500, "milliseconds correct")
    }),

    ("showkontrol-export-nonfinite", {
        // NaN/Inf/huge/negative starts must NOT crash the Int() timecode conversion.
        for bad in [Double.nan, .infinity, -.infinity, 1e18, -50, 9.9e17] {
            let tc = ShowKontrolExporter.secondsToTimecode(bad)
            expect(tc.formatted.count >= 11, "timecode produced for \(bad)")
            expect(tc.milliseconds >= 0 || bad < 0, "ms sane for \(bad)")
        }
        let cues = [
            CuePoint(id: "a", start: .nan, name: "n", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: .infinity, name: "i", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "c", start: 1e18, name: "h", color: "#fff", yValue: 0, curve: 1, enabled: true),
        ]
        _ = ShowKontrolExporter.generate(cuePoints: cues) // must not crash
        expect(true, "export of non-finite cues did not crash")
    }),

    // ------------------------------------------------------------- Resolume

    ("resolume-sample", {
        let xml = try loadSample("sample-resolume-envelope.xml")
        let result = try ResolumeParser.parse(xml: xml)
        expect(!result.points.isEmpty, "sample has points")
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 60)
        expectSaneCues(cues, "resolume-sample")
    }),

    ("resolume-real", {
        let xml = try loadSample("real-resolume-envelope.xml")
        let result = try ResolumeParser.parse(xml: xml)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 120)
        expectSaneCues(cues, "resolume-real")
        // x values must be sorted ascending.
        let xs = result.points.map(\.x)
        expectEq(xs, xs.sorted(), "points sorted by x")
    }),

    ("resolume-malformed", {
        let xml = """
        <Preset name="Bad">
          <ModifierEnvelope>
            <points>
              <point x="nan" y="0.5" curve="1"/>
              <point x="-0.5" y="inf" curve="999"/>
              <point x="0.5" y="-2" curve="-3"/>
              <point x="1.0" y="2" curve="0"/>
            </points>
          </ModifierEnvelope>
        </Preset>
        """
        let result = try ResolumeParser.parse(xml: xml)
        let cues = ResolumeParser.convertToCuePoints(points: result.points, duration: 60)
        expectSaneCues(cues, "resolume-malformed")
    }),

    ("resolume-export-nonfinite", {
        // A cue carrying NaN/Inf must never appear as nan/inf in the XML.
        let cues = [
            CuePoint(id: "a", start: 0, name: "s", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: .nan, name: "x", color: "#fff", yValue: .infinity, curve: 1, enabled: true),
            CuePoint(id: "c", start: 60, name: "e", color: "#fff", yValue: 100, curve: 1, enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "P") ?? ""
        expect(out.contains("<point"), "produced points")
        // No point coordinate may serialize as nan/inf (would be invalid in Resolume).
        expect(!out.contains("\"nan\"") && !out.contains("\"inf\"") && !out.contains("\"-inf\""),
               "no non-finite coordinate tokens in XML")
        // Re-parsing the output must yield only finite coordinates.
        let reparsed = try ResolumeParser.parse(xml: out)
        for p in reparsed.points {
            expect(p.x.isFinite && p.y.isFinite, "exported point finite (x=\(p.x), y=\(p.y))")
        }
    }),

    ("resolume-export-decimal-precision", {
        // Output must be plain decimal (no scientific notation) and capped at 6 decimals,
        // including a cue 1 ms into a 60 s track which previously emitted "...e-05".
        let cues = [
            CuePoint(id: "a", start: 0,     name: "s", color: "#fff", yValue: 0,         curve: 1, enabled: true),
            CuePoint(id: "b", start: 0.001, name: "t", color: "#fff", yValue: 33.333333, curve: 1, enabled: true),
            CuePoint(id: "c", start: 20,    name: "m", color: "#fff", yValue: 60,        curve: 1, enabled: true),
            CuePoint(id: "d", start: 60,    name: "e", color: "#fff", yValue: 100,       curve: 1, enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "P") ?? ""
        let coords = pointAttrStrings(out, "x") + pointAttrStrings(out, "y")
        expect(coords.count >= 8, "exported coordinates for every point (got \(coords.count))")
        for v in coords {
            expect(!v.contains("e") && !v.contains("E"), "no scientific notation (got \(v))")
            expect(decimalPlaces(v) <= 6, "<= 6 decimal places (got \(v))")
            expect(Double(v) != nil, "coordinate parses as a number (got \(v))")
        }
    }),

    ("resolume-roundtrip-curves", {
        // Export -> parse -> convert must preserve curves[1...]; curve[0] resets to Linear.
        let cues = [
            CuePoint(id: "a", start: 0,  name: "Start", color: "#fff", yValue: 10, curve: 5,  enabled: true),
            CuePoint(id: "b", start: 30, name: "Mid",   color: "#fff", yValue: 80, curve: 7,  enabled: true),
            CuePoint(id: "c", start: 60, name: "End",   color: "#fff", yValue: 40, curve: 11, enabled: true),
        ]
        let xml = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "RT")
        expect(xml != nil, "export ok")
        let parsed = try ResolumeParser.parse(xml: xml ?? "")
        let back = ResolumeParser.convertToCuePoints(points: parsed.points, duration: 60)
        expectEq(back.count, 3, "round-trip preserves point count")
        if back.count == 3 {
            expectEq(back[0].curve, 1, "first curve resets to Linear (no arrival)")
            expectEq(back[1].curve, 7, "middle arrival curve preserved")
            expectEq(back[2].curve, 11, "end arrival curve preserved")
            expect(approxEq(back[1].start, 30, 0.5), "middle position preserved")
            expect(approxEq(back[2].yValue, 40, 1.0), "end yValue preserved")
        }
    }),

    ("resolume-empty", {
        expectThrows("envelope with no points throws noData") {
            _ = try ResolumeParser.parse(xml: "<Preset name=\"x\"><points></points></Preset>")
        }
    }),

    ("resolume-fuzz", {
        var rng = XorShift64(seed: 0x4E5E)
        let base = (try? loadSample("real-resolume-envelope.xml")) ?? "<x/>"
        let baseBytes = Array(base.utf8)
        for _ in 0..<150 {
            var bytes = baseBytes
            let flips = Int(rng.next() % 20)
            for _ in 0..<flips where !bytes.isEmpty {
                bytes[Int(rng.next() % UInt64(bytes.count))] = rng.byte()
            }
            let s = String(decoding: bytes, as: UTF8.self)
            if let r = try? ResolumeParser.parse(xml: s) {
                let cues = ResolumeParser.convertToCuePoints(points: r.points, duration: 60)
                expectSaneCues(cues, "resolume-fuzz")
            }
        }
    }),

    // ---------------------------------------------------------------- Serato

    ("serato-markers2-basic", {
        let stream = markers2([
            cueEntry(cuePayload(index: 0, posMs: 2500, r: 0xCC, g: 0, b: 0, name: "Intro")),
            cueEntry(cuePayload(index: 1, posMs: 60000, name: "Drop")),
        ])
        let cues = SeratoParser.parseSeratoMarkers2(data: stream)
        expectEq(cues.count, 2, "parsed 2 cues")
        expectSaneCues(cues, "serato-basic")
        if cues.count == 2 {
            expect(approxEq(cues[0].start, 2.5), "first cue at 2.5s")
            expect(approxEq(cues[1].start, 60.0), "second cue at 60s")
            expectEq(cues[0].name, "Intro", "name parsed")
        }
    }),

    ("serato-markers2-index-255", {
        // Cue index byte 0xFF with an empty name previously overflowed UInt8 (cueIndex + 1).
        var p = [UInt8](repeating: 0, count: 13)
        p[1] = 0xFF          // cue index 255
        p[4] = 0x10          // position bytes -> 4096 ms
        let cues = SeratoParser.parseSeratoMarkers2(data: markers2([cueEntry(p)]))
        expectSaneCues(cues, "serato-index-255")
        expect(cues.count == 1, "one cue parsed from index-255 entry")
    }),

    ("serato-markers2-base64", {
        let raw = markers2([cueEntry(cuePayload(index: 2, posMs: 1000, name: "B64"))])
        let b64 = raw.base64EncodedString()
        // Serato stores base64 sometimes split by newlines and padded with nulls.
        var wrapped = Array(b64.utf8)
        wrapped.append(0x0A)
        wrapped.append(0x00)
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(wrapped))
        expectSaneCues(cues, "serato-base64")
        expect(cues.count == 1, "decoded base64 cue")
    }),

    ("serato-markers2-truncated", {
        // Truncated streams and absurd length fields must not crash; return what's safe.
        let full = Array(markers2([cueEntry(cuePayload(index: 0, posMs: 1000, name: "X"))]))
        for cut in 0...full.count {
            let cues = SeratoParser.parseSeratoMarkers2(data: Data(full.prefix(cut)))
            expectSaneCues(cues, "serato-truncated-\(cut)")
        }
        // CUE entry advertising a huge payload length.
        var bad: [UInt8] = [0x01, 0x01]
        bad += Array("CUE".utf8); bad.append(0x00)
        bad += be32(0xFFFFFF00)
        bad += [0x00, 0x00, 0x00]
        let cues = SeratoParser.parseSeratoMarkers2(data: Data(bad))
        expectSaneCues(cues, "serato-huge-len")
    }),

    ("serato-markers2-fuzz", {
        var rng = XorShift64(seed: 0x5E4A)
        for _ in 0..<400 {
            let len = Int(rng.next() % 300)
            var bytes = rng.bytes(len)
            // Bias half the inputs to look like a real stream so we exercise the entry loop.
            if len >= 2 && (rng.byte() & 1 == 0) { bytes[0] = 0x01; bytes[1] = 0x01 }
            let cues = SeratoParser.parseSeratoMarkers2(data: Data(bytes))
            expectSaneCues(cues, "serato-fuzz")
        }
    }),

    ("serato-parsefile-errors", {
        expectThrows("unsupported extension throws") {
            _ = try SeratoParser.parseFile(at: writeTemp([0x00], ext: "txt"))
        }
        expectThrows("empty mp3 throws noData") {
            _ = try SeratoParser.parseFile(at: writeTemp([], ext: "mp3"))
        }
        expectThrows("tiny mp3 (< 10 bytes) throws") {
            _ = try SeratoParser.parseFile(at: writeTemp([0x49, 0x44, 0x33], ext: "mp3"))
        }
        expectThrows("wav with bad magic throws") {
            _ = try SeratoParser.parseFile(at: writeTemp([UInt8](repeating: 0x20, count: 32), ext: "wav"))
        }
        expectThrows("aiff with bad magic throws") {
            _ = try SeratoParser.parseFile(at: writeTemp([UInt8](repeating: 0x20, count: 32), ext: "aiff"))
        }
    }),

    ("serato-parsefile-minimal", {
        // Minimal-but-valid containers should parse without cues and without crashing.
        var mp3 = Array("ID3".utf8) + [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        mp3 += [UInt8](repeating: 0x00, count: 16)
        let t1 = try SeratoParser.parseFile(at: writeTemp(mp3, ext: "mp3"))
        expectSaneCues(t1.cuePoints, "serato-min-mp3")

        var wav = Array("RIFF".utf8)
        wav += [0x24, 0x00, 0x00, 0x00]                 // RIFF chunk size (LE)
        wav += Array("WAVE".utf8)
        wav += Array("fmt ".utf8) + [0x10, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16)
        let t2 = try SeratoParser.parseFile(at: writeTemp(wav, ext: "wav"))
        expectSaneCues(t2.cuePoints, "serato-min-wav")

        let aiff = Array("FORM".utf8) + [0x00, 0x00, 0x00, 0x04] + Array("AIFF".utf8)
        let t3 = try SeratoParser.parseFile(at: writeTemp(aiff, ext: "aiff"))
        expectSaneCues(t3.cuePoints, "serato-min-aiff")
    }),

    ("serato-parsefiles-fuzz", {
        var rng = XorShift64(seed: 0xF11E)
        let exts = ["mp3", "wav", "aiff"]
        var urls: [URL] = []
        for i in 0..<60 {
            let len = Int(rng.next() % 400) + 12
            var bytes = rng.bytes(len)
            // Half get a valid-ish magic so we reach deeper parsing paths.
            if rng.byte() & 1 == 0 {
                let magic = i % 2 == 0 ? Array("RIFF".utf8) : Array("FORM".utf8)
                for j in 0..<min(4, bytes.count) { bytes[j] = magic[j] }
            }
            urls.append(writeTemp(bytes, ext: exts[i % exts.count]))
        }
        // parseFiles must swallow per-file errors and never crash.
        let result = SeratoParser.parseFiles(at: urls)
        for t in result.tracks { expectSaneCues(t.cuePoints, "serato-parsefiles-fuzz") }
    }),

    // -------------------------------------------------------------- Engine DJ

    ("enginedj-not-found", {
        expectThrows("missing database throws") {
            _ = try EngineDJParser.parse(databaseURL: fixturesDir.appendingPathComponent("does-not-exist.db"))
        }
    }),

    ("enginedj-good", {
        let url = fixturesDir.appendingPathComponent("engine-good.db")
        let tracks = try EngineDJParser.parse(databaseURL: url)
        expectEq(tracks.count, 2, "two tracks loaded")
        if tracks.count == 2 {
            expectEq(tracks[0].name, "Test Title", "title used as name")
            expectEq(tracks[0].tonality, "C", "key code 1 maps to C")
            expectEq(tracks[1].name, "fallback.wav", "filename used when title empty")
            for t in tracks { expectSaneCues(t.cuePoints, "enginedj-good/\(t.name)") }
        }
    }),

    ("enginedj-missing-table", {
        expectThrows("db missing PerformanceData throws") {
            _ = try EngineDJParser.parse(databaseURL: fixturesDir.appendingPathComponent("engine-no-perf.db"))
        }
    }),

    ("enginedj-empty", {
        expectThrows("db with empty Track table throws noData") {
            _ = try EngineDJParser.parse(databaseURL: fixturesDir.appendingPathComponent("engine-empty.db"))
        }
    }),

    ("enginedj-corrupt-file", {
        expectThrows("non-sqlite file throws (no crash)") {
            _ = try EngineDJParser.parse(databaseURL: fixturesDir.appendingPathComponent("engine-corrupt.db"))
        }
    }),

    ("enginedj-garbage-blob", {
        // A track whose quickCues BLOB is garbage must load without crashing (cues empty).
        let url = fixturesDir.appendingPathComponent("engine-badblob.db")
        let tracks = try EngineDJParser.parse(databaseURL: url)
        expect(!tracks.isEmpty, "track still returned despite bad blob")
        for t in tracks { expectSaneCues(t.cuePoints, "enginedj-badblob") }
    }),

    // ----------------------------------------------- Audit-driven regressions

    ("serato-mp3-id3-metadata", {
        let mp3 = buildMP3(frames: [("TIT2", "My Title"), ("TPE1", "My Artist"), ("TLEN", "180000")])
        let t = try SeratoParser.parseFile(at: writeTemp(mp3, ext: "mp3"))
        expectEq(t.name, "My Title", "TIT2 title parsed")
        expectEq(t.artist, "My Artist", "TPE1 artist parsed")
        expectEq(t.totalTime, 180, "TLEN 180000ms -> 180s")
        expectSaneCues(t.cuePoints, "serato-mp3-id3")
    }),

    ("serato-tlen-nonfinite", {
        // TLEN "nan"/"inf"/huge previously trapped at Int(ms / 1000.0).
        for bad in ["nan", "inf", "999999999999999999999", "1e308"] {
            let mp3 = buildMP3(frames: [("TIT2", "T"), ("TLEN", bad)])
            let t = try SeratoParser.parseFile(at: writeTemp(mp3, ext: "mp3"))
            expect(t.totalTime >= 0, "TLEN \(bad) did not crash; duration sane (\(t.totalTime))")
            expectEq(t.name, "T", "title still parsed alongside bad TLEN")
        }
    }),

    ("serato-tbpm-nonfinite", {
        let mp3 = buildMP3(frames: [("TIT2", "T"), ("TBPM", "nan")])
        let t = try SeratoParser.parseFile(at: writeTemp(mp3, ext: "mp3"))
        expect(t.bpm.isFinite, "bpm stays finite despite TBPM nan")
    }),

    ("serato-aiff-zero-chunk", {
        // A zero-size chunk must not abort iteration (was an early `break`).
        var aiff = Array("FORM".utf8) + [0x00, 0x00, 0x00, 0x18] + Array("AIFF".utf8)
        aiff += Array("TEST".utf8) + [0x00, 0x00, 0x00, 0x00]            // zero-size chunk
        aiff += Array("NONE".utf8) + [0x00, 0x00, 0x00, 0x02] + [0x01, 0x02]
        let t = try SeratoParser.parseFile(at: writeTemp(aiff, ext: "aiff"))
        expectSaneCues(t.cuePoints, "serato-aiff-zero-chunk")
    }),

    ("showkontrol-export-name-newline", {
        let cues = [
            CuePoint(id: "a", start: 0,  name: "Start", color: "#fff", yValue: 0, curve: 1, enabled: true),
            CuePoint(id: "b", start: 10, name: "Line1\nLine2\rLine3", color: "#fff", yValue: 0, curve: 1, enabled: true),
        ]
        let out = ShowKontrolExporter.generate(cuePoints: cues) ?? ""
        expect(!out.contains("\n"), "no LF leaks into .cue output")
        let records = out.components(separatedBy: "\r")
        expectEq(records.count, cues.count, "one record per cue (no injected rows)")
    }),

    ("resolume-export-curve-clamped", {
        // Out-of-range curve on a cue must never serialize verbatim into the XML.
        let cues = [
            CuePoint(id: "a", start: 0,  name: "s", color: "#fff", yValue: 0,  curve: 1,   enabled: true),
            CuePoint(id: "b", start: 30, name: "m", color: "#fff", yValue: 50, curve: 999, enabled: true),
            CuePoint(id: "c", start: 60, name: "e", color: "#fff", yValue: 0,  curve: -7,  enabled: true),
        ]
        let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "C") ?? ""
        let reparsed = try ResolumeParser.parse(xml: out)
        for p in reparsed.points {
            expect((1...23).contains(p.curve), "exported curve in 1...23 (got \(p.curve))")
        }
    }),

    ("project-tolerant-decode", {
        // A partial .cueproj (missing most keys) must load with defaults, not throw keyNotFound.
        let json = Data("{\"name\":\"Partial\"}".utf8)
        let p = try JSONDecoder().decode(Project.self, from: json)
        expectEq(p.name, "Partial", "present key decoded")
        expectEq(p.trackDuration, 60.0, "missing trackDuration uses default")
        expectEq(p.presetName, "New Envelope", "missing presetName uses default")
        expect(p.cuePoints.isEmpty, "missing cuePoints defaults to empty")
    }),

    // ---------------------------------------------------------------- Project

    ("project-decode-sample", {
        let data = try Data(contentsOf: samplesDir.appendingPathComponent("sample-project.cueproj"))
        let project = try JSONDecoder().decode(Project.self, from: data)
        expect(!project.presetName.isEmpty, "preset name present")
        expect(project.trackDuration > 0, "duration positive")
    }),

    ("project-roundtrip", {
        var p = Project()
        p.name = "RT"
        p.cuePoints = [CuePoint.makeDefault(at: 0, name: "S"), CuePoint.makeDefault(at: 60, name: "E")]
        p.trackDuration = 90
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        expectEq(back.name, "RT", "name round-trips")
        expectEq(back.cuePoints.count, 2, "cues round-trip")
        expectEq(back.trackDuration, 90, "duration round-trips")
    }),
]
