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
        // Iterative (explicit stack) rather than recursive: untrusted Rekordbox XML can
        // nest playlist folders thousands deep, and a call-stack-per-level recursion
        // overflows the smaller default thread stack on Windows well before macOS.
        var total = 0
        var stack: [Playlist] = [self]
        while let node = stack.popLast() {
            if node.type == .playlist {
                total += node.trackIds.count
            } else {
                stack.append(contentsOf: node.children)
            }
        }
        return total
    }
}
