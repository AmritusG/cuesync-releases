import Foundation

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// model via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see CuePoint.swift.
public struct Project: Codable {
    public var version: String = "3.0"
    public var name: String = "Untitled Project"
    public var savedAt: String?
    public var tracks: [Track] = []
    public var playlists: [Playlist] = []
    public var selectedTrackId: String?
    public var cuePoints: [CuePoint] = []
    public var trackDuration: Double = 60.0
    public var presetName: String = "New Envelope"

    // Swift only auto-synthesizes a memberwise initializer as `internal`, even when the
    // enclosing type and every stored property are marked public — a manual initializer,
    // marked public, is needed for `AppState.saveProject(to:)` (in the UI target) to
    // construct one. Matches the
    // property defaults exactly so zero/partial-arg construction (e.g. `Project()` in
    // CueSyncCoreTests) keeps working identically.
    public init(
        version: String = "3.0",
        name: String = "Untitled Project",
        savedAt: String? = nil,
        tracks: [Track] = [],
        playlists: [Playlist] = [],
        selectedTrackId: String? = nil,
        cuePoints: [CuePoint] = [],
        trackDuration: Double = 60.0,
        presetName: String = "New Envelope"
    ) {
        self.version = version
        self.name = name
        self.savedAt = savedAt
        self.tracks = tracks
        self.playlists = playlists
        self.selectedTrackId = selectedTrackId
        self.cuePoints = cuePoints
        self.trackDuration = trackDuration
        self.presetName = presetName
    }
}

extension Project {
    /// Tolerant decode: a missing key falls back to its default instead of throwing
    /// `keyNotFound`, so older or partial `.cueproj` files still load. (Swift's synthesized
    /// Decodable ignores the property defaults above and requires every key.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "3.0"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Project"
        savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        selectedTrackId = try c.decodeIfPresent(String.self, forKey: .selectedTrackId)
        cuePoints = try c.decodeIfPresent([CuePoint].self, forKey: .cuePoints) ?? []
        trackDuration = try c.decodeIfPresent(Double.self, forKey: .trackDuration) ?? 60.0
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName) ?? "New Envelope"
    }
}
