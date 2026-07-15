import Foundation

struct Project: Codable {
    var version: String = "3.0"
    var name: String = "Untitled Project"
    var savedAt: String?
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var selectedTrackId: String?
    var cuePoints: [CuePoint] = []
    var trackDuration: Double = 60.0
    var presetName: String = "New Envelope"
}

extension Project {
    /// Tolerant decode: a missing key falls back to its default instead of throwing
    /// `keyNotFound`, so older or partial `.cueproj` files still load. (Swift's synthesized
    /// Decodable ignores the property defaults above and requires every key.)
    /// Declared in an extension so the memberwise initializer is preserved.
    init(from decoder: Decoder) throws {
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
