import Foundation

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// model via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see CuePoint.swift.
// No custom initializer is added: only the parsers (same module) construct `Track` values; the UI
// target only ever reads them.
public struct Track: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var artist: String
    public var album: String
    public var genre: String
    public var totalTime: Int             // Duration in seconds
    public var bpm: Double
    public var tonality: String
    public var location: String           // File path
    public var cuePoints: [CuePoint]

    public var formattedDuration: String {
        let safe = max(totalTime, 0)
        let m = safe / 60
        let s = safe % 60
        return String(format: "%d:%02d", m, s)
    }

    public var cueCount: Int { cuePoints.count }
}
