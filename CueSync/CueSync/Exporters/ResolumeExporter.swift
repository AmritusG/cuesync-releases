import Foundation

enum ResolumeExporter {
    static func generate(cuePoints: [CuePoint], trackDuration: Double, presetName: String) -> String? {
        guard trackDuration > 0 else { return nil }

        var envPoints = cuePoints
            .filter { $0.enabled }
            .map { cue -> (x: Double, y: Double, curve: Int) in
                (
                    x: cue.normalizedX(duration: trackDuration),
                    y: cue.normalizedY,
                    curve: cue.curve
                )
            }

        guard !envPoints.isEmpty else { return nil }

        // Ensure points at x=0 and x=1 (symmetric tolerance so a near-boundary point
        // isn't duplicated by an exact-equality check on one side only).
        if !envPoints.contains(where: { $0.x < 0.0001 }) {
            envPoints.insert((x: 0, y: 0, curve: 1), at: 0)
        }
        if !envPoints.contains(where: { abs($0.x - 1.0) < 0.0001 }) {
            envPoints.append((x: 1, y: 0, curve: 1))
        }

        envPoints.sort { $0.x < $1.x }

        let uniqueId = "\(Int(Date().timeIntervalSince1970 * 1000))"
        let escapedName = escapeXml(presetName)

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<Preset name=\"\(escapedName)\" uniqueId=\"MOD_ENVELOPE\" className=\"Envelope\" default=\"0\">\n"
        xml += "\t<versionInfo name=\"Resolume Arena\" majorVersion=\"7\" minorVersion=\"23\" microVersion=\"2\" revision=\"51094\"/>\n"
        xml += "\t<ModifierEnvelope name=\"ModifierEnvelope\" altName=\"Envelope\" uniqueId=\"\(uniqueId)\">\n"
        xml += "\t\t<points>\n"

        // In our model, curve = "how to arrive at this point" (prev → this).
        // In Resolume XML, curve = "how to go from this point to next" (this → next).
        // So shift: exported point[i].curve = internal point[i+1].curve
        for (i, p) in envPoints.enumerated() {
            let xStr = formatDouble(p.x)
            let yStr = formatDouble(p.y)
            let nextCurve = (i + 1 < envPoints.count) ? envPoints[i + 1].curve : 1
            let resolveCurve = (1...23).contains(nextCurve) ? nextCurve : 1
            xml += "\t\t\t<point x=\"\(xStr)\" y=\"\(yStr)\" curve=\"\(resolveCurve)\"/>\n"
        }

        xml += "\t\t</points>\n"
        xml += "\t</ModifierEnvelope>\n"
        xml += "</Preset>"

        return xml
    }

    private static func escapeXml(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func formatDouble(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        // Resolume envelope coordinates are plain decimals (never scientific notation).
        // Swift's String(Double) emits up to ~17 sig-figs and switches to scientific for
        // small values (e.g. a cue 1 ms into a 60 s track -> "1.6e-05"), which a strict
        // Resolume parser may reject. Emit fixed 6-decimal plain notation — ample precision
        // (1e-6 of normalized position) — then trim trailing zeros: 0.5 -> "0.5", 1 -> "1".
        var s = String(format: "%.6f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
