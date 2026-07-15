import Foundation

enum ShowKontrolExporter {
    static func generate(cuePoints: [CuePoint]) -> String? {
        let enabled = cuePoints.filter { $0.enabled }
        guard !enabled.isEmpty else { return nil }

        let lines = enabled.enumerated().map { index, cue -> String in
            let tc = secondsToTimecode(cue.start)
            // Strip commas (field separator) AND CR/LF (record separator) so a cue name
            // can't inject extra columns or rows into the .cue output.
            let cleanName = cue.name
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let name = cleanName.isEmpty ? "CUE\(index + 1)" : cleanName
            return "\(tc.formatted),\(tc.compact),\(tc.milliseconds),\(name),TAG,,,,,,"
        }

        return lines.joined(separator: "\r")
    }

    struct Timecode {
        let formatted: String   // HH:MM:SS:FF
        let compact: String     // HHMMSSFF
        let milliseconds: Int
    }

    static func secondsToTimecode(_ seconds: Double) -> Timecode {
        // Clamp to a finite, non-negative, in-range value so the Int() conversions below
        // can never trap on NaN/Inf or overflow. Cap at 99:59:59:29 (a track is never
        // ~100 hours); a hostile project file could otherwise carry 1e18 here.
        let safe = seconds.isFinite ? min(max(seconds, 0), 359_999.0) : 0
        let totalFrames = Int((safe * 30).rounded())
        let frames = totalFrames % 30
        let totalSeconds = totalFrames / 30
        let secs = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let mins = totalMinutes % 60
        let hours = totalMinutes / 60

        let formatted = String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frames)
        let compact = String(format: "%02d%02d%02d%02d", hours, mins, secs, frames)
        let ms = Int((safe * 1000).rounded())

        return Timecode(formatted: formatted, compact: compact, milliseconds: ms)
    }
}
