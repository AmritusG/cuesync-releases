import Foundation

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// model via a plain `import CueSyncCore` — SwiftPM module boundaries mean `internal`
// (the default) is invisible outside this target, unlike the Xcode build where
// App/AppState.swift compiles directly alongside this file (spec CUESYNC-7 §B.3).
public struct CuePoint: Identifiable, Codable, Equatable {
    public var id: String
    public var start: Double          // Time position in seconds
    public var name: String
    public var color: String          // CSS color string e.g. "rgb(255, 0, 0)" or "#ff0000"
    public var yValue: Double         // 0-100
    public var curve: Int             // 1-23
    public var enabled: Bool

    public init(id: String, start: Double, name: String, color: String, yValue: Double, curve: Int, enabled: Bool) {
        self.id = id
        self.start = start
        self.name = name
        self.color = color
        self.yValue = yValue
        self.curve = curve
        self.enabled = enabled
    }

    public static func makeDefault(at time: Double = 0, name: String = "") -> CuePoint {
        CuePoint(
            id: UUID().uuidString,
            start: time,
            name: name,
            color: "#1ed760",
            yValue: 0,
            curve: 1,
            enabled: true
        )
    }

    /// Normalized X for Resolume (0-1)
    public func normalizedX(duration: Double) -> Double {
        guard duration > 0, start.isFinite else { return 0 }
        return min(max(start / duration, 0), 1)
    }

    /// Normalized Y for Resolume (0-1)
    public var normalizedY: Double {
        guard yValue.isFinite else { return 0 }
        return min(max(yValue / 100.0, 0), 1)
    }

    /// Clamp to values that are always safe to render and export:
    /// a finite, non-negative `start`; a finite `yValue` in 0...100; a `curve` in 1...23.
    /// Every parser and project load runs untrusted data through this, so a corrupt or
    /// hostile file can never produce a NaN/Inf/out-of-range value that would later crash
    /// the envelope canvas (`Int(NaN)`) or the exporters (timecode overflow, `nan` in XML).
    public func sanitized() -> CuePoint {
        var c = self
        c.start = c.start.isFinite ? max(c.start, 0) : 0
        c.yValue = c.yValue.isFinite ? min(max(c.yValue, 0), 100) : 0
        c.curve = (1...23).contains(c.curve) ? c.curve : 1
        return c
    }
}
