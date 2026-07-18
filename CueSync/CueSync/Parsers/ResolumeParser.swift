import Foundation
// XMLParser/XMLParserDelegate live in Foundation on Apple platforms but in the
// separate FoundationXML module on Linux/Windows. Import it where it exists so
// the XML parsing compiles cross-platform; the macOS path is unchanged.
#if canImport(FoundationXML)
import FoundationXML
#endif

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// parser via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see Models/CuePoint.swift.
// `ResolumePoint`'s fields stay internal: the UI target only ever passes the opaque
// array straight through to `convertToCuePoints`, never reads `x`/`y`/`curve` directly.
public struct ResolumePoint {
    let x: Double
    let y: Double
    let curve: Int
}

public struct ResolumeParseResult {
    public let presetName: String
    public let points: [ResolumePoint]
}

public enum ResolumeParser {
    public static func parse(xml: String) throws -> ResolumeParseResult {
        guard let data = xml.data(using: .utf8) else {
            throw ParseError.invalidFormat("Could not encode XML string")
        }
        let delegate = ResolumeXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidFormat("Failed to parse Resolume XML")
        }
        guard !delegate.points.isEmpty else {
            throw ParseError.noData
        }
        return ResolumeParseResult(
            presetName: delegate.presetName,
            points: delegate.points.sorted { $0.x < $1.x }
        )
    }

    public static func convertToCuePoints(points: [ResolumePoint], duration: Double) -> [CuePoint] {
        // In Resolume XML, point[i].curve = "from point[i] to point[i+1]".
        // In our model, cue[i].curve = "from previous to point[i]" (arrival curve).
        // So our cue[i].curve = xml_points[i-1].curve. First point gets Linear.
        points.enumerated().map { i, point in
            let name: String
            if i == 0 { name = "Start" }
            else if i == points.count - 1 { name = "End" }
            else { name = "Point \(i)" }

            let arrivalCurve = i > 0 ? clampCurve(points[i - 1].curve) : 1

            return CuePoint(
                id: UUID().uuidString,
                start: point.x * duration,
                name: name,
                color: "#ffd700",
                yValue: point.y * 100.0,
                curve: arrivalCurve,
                enabled: true
            ).sanitized()
        }
    }

    /// Clamp curve ID to valid 1-23 range
    private static func clampCurve(_ id: Int) -> Int {
        if id >= 1 && id <= 23 { return id }
        return 1 // Default to Linear for out-of-range values
    }
}

// MARK: - XML Delegate

private class ResolumeXMLDelegate: NSObject, XMLParserDelegate {
    var presetName = "Imported Envelope"
    var points: [ResolumePoint] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch elementName {
        case "Preset":
            presetName = attributes["name"] ?? "Imported Envelope"
        case "point":
            let x = Double(attributes["x"] ?? "0") ?? 0
            let y = Double(attributes["y"] ?? "0") ?? 0
            let curve = Int(attributes["curve"] ?? "1") ?? 1
            points.append(ResolumePoint(x: x, y: y, curve: curve))
        default:
            break
        }
    }
}
