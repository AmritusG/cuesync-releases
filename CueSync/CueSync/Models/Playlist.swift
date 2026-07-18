import Foundation

// `public` so the CueSync (swift-cross-ui) executable target can consume this shared
// model via a plain `import CueSyncCore` (spec CUESYNC-7 §B.3) — see CuePoint.swift.
// No custom initializer is added: only the parsers (same module) construct `Playlist` values; the UI
// target only ever reads them.
public struct Playlist: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var type: PlaylistType
    public var trackIds: [String]
    public var children: [Playlist]

    public enum PlaylistType: String, Codable {
        case folder
        case playlist
    }

    public var isFolder: Bool { type == .folder }

    public func totalTrackCount() -> Int {
        if type == .playlist {
            return trackIds.count
        }
        return children.reduce(0) { $0 + $1.totalTrackCount() }
    }
}
