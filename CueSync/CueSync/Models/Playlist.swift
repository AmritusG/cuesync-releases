import Foundation

struct Playlist: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var type: PlaylistType
    var trackIds: [String]
    var children: [Playlist]

    enum PlaylistType: String, Codable {
        case folder
        case playlist
    }

    var isFolder: Bool { type == .folder }

    func totalTrackCount() -> Int {
        if type == .playlist {
            return trackIds.count
        }
        return children.reduce(0) { $0 + $1.totalTrackCount() }
    }
}
