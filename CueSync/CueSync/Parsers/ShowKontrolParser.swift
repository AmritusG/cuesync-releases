import Foundation

struct ShowKontrolResult {
    let cuePoints: [CuePoint]
    let suggestedDurationMs: Double?
    let durationFromCues: Bool  // true if duration was derived from cue timing data
}

enum ShowKontrolParser {
    static func parse(content: String) throws -> ShowKontrolResult {
        // ShowKontrol uses \r line endings; also handle \n and \r\n
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var cuePoints: [CuePoint] = []
        var cue0DurationMs: Double?
        var maxTimeMs: Double = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 4 else { continue }

            let rawMs = Double(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
            // Reject NaN/Inf/negative so cue starts and the derived duration stay finite & sane.
            let milliseconds = rawMs.isFinite ? max(rawMs, 0) : 0
            let cueName = parts[3].trimmingCharacters(in: .whitespaces)
            let tagOrTime = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces) : ""

            // Check for CUE0 duration metadata
            if cueName == "CUE0" && tagOrTime != "TAG" && !tagOrTime.isEmpty {
                if let dur = parseDurationString(tagOrTime) {
                    cue0DurationMs = dur
                }
            }

            // Track the maximum time across all cues
            if milliseconds > maxTimeMs {
                maxTimeMs = milliseconds
            }

            // Skip CUE0 at position 0 (metadata)
            if cueName == "CUE0" && milliseconds == 0 {
                continue
            }

            let cue = CuePoint(
                id: UUID().uuidString,
                start: milliseconds / 1000.0,
                name: cueName.isEmpty ? "Cue \(cuePoints.count + 1)" : cueName,
                color: "#ef288a",
                yValue: 0,
                curve: 1,
                enabled: true
            )
            cuePoints.append(cue)
        }

        // Add start cue if not present
        if !cuePoints.isEmpty && !cuePoints.contains(where: { $0.start <= 0.001 }) {
            cuePoints.insert(
                CuePoint(
                    id: UUID().uuidString,
                    start: 0,
                    name: "Start",
                    color: "#ef288a",
                    yValue: 0,
                    curve: 1,
                    enabled: true
                ),
                at: 0
            )
        }

        cuePoints = cuePoints.map { $0.sanitized() }.sorted { $0.start < $1.start }

        if cuePoints.isEmpty {
            throw ParseError.noData
        }

        // Determine duration:
        // 1. CUE0 metadata duration (explicit)
        // 2. Max cue time if cues span a meaningful range (> 1 second)
        // 3. Default 60s only as last resort
        let suggestedDuration: Double?
        let durationFromCues: Bool

        if let cue0 = cue0DurationMs {
            // Explicit duration from CUE0 metadata
            suggestedDuration = cue0
            durationFromCues = true
        } else if maxTimeMs > 1000 {
            // Cues have real timing data — use the max time as duration
            suggestedDuration = maxTimeMs
            durationFromCues = true
        } else {
            // No timing info — will need user input
            suggestedDuration = nil
            durationFromCues = false
        }

        return ShowKontrolResult(
            cuePoints: cuePoints,
            suggestedDurationMs: suggestedDuration,
            durationFromCues: durationFromCues
        )
    }

    private static func parseDurationString(_ str: String) -> Double? {
        let s = str.trimmingCharacters(in: .whitespaces)

        // Try MM:SS:MS
        let parts3 = s.split(separator: ":")
        if parts3.count == 3,
           let min = Double(parts3[0]),
           let sec = Double(parts3[1]),
           let ms = Double(parts3[2]) {
            let result = (min * 60 + sec) * 1000 + ms
            return result.isFinite ? result : nil
        }

        // Try MM:SS
        if parts3.count == 2,
           let min = Double(parts3[0]),
           let sec = Double(parts3[1]) {
            let result = (min * 60 + sec) * 1000
            return result.isFinite ? result : nil
        }

        return nil
    }
}
