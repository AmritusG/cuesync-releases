import Foundation

struct RekordboxResult {
    let tracks: [Track]
    let playlists: [Playlist]
}

enum RekordboxParser {
    static func parse(xml: String) throws -> RekordboxResult {
        guard let data = xml.data(using: .utf8) else {
            throw ParseError.invalidFormat("Could not encode XML string")
        }
        let delegate = RekordboxXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidFormat("Failed to parse Rekordbox XML: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        return RekordboxResult(tracks: delegate.tracks, playlists: delegate.playlists)
    }
}

// MARK: - XML Delegate

private class RekordboxXMLDelegate: NSObject, XMLParserDelegate {
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    private var trackMap: [String: Track] = [:]

    // Current parsing state
    private var currentTrack: Track?
    private var currentCuePoints: [CuePoint] = []
    private var inCollection = false
    private var inPlaylists = false

    // Playlist parsing stack
    private var playlistStack: [PlaylistNode] = []

    private class PlaylistNode {
        let name: String
        let type: String // "0" = folder, "1" = playlist
        var trackIds: [String] = []
        var children: [Playlist] = []

        init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch elementName {
        case "COLLECTION":
            inCollection = true
        case "PLAYLISTS":
            inPlaylists = true
        case "TRACK":
            if inCollection {
                parseCollectionTrack(attributes)
            } else if inPlaylists, let key = attributes["Key"] {
                // Track reference in playlist
                playlistStack.last?.trackIds.append(key)
            }
        case "POSITION_MARK":
            if inCollection {
                parseCuePoint(attributes)
            }
        case "NODE":
            if inPlaylists {
                let name = attributes["Name"] ?? "Unknown"
                let type = attributes["Type"] ?? "0"
                playlistStack.append(PlaylistNode(name: name, type: type))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "COLLECTION":
            inCollection = false
        case "PLAYLISTS":
            inPlaylists = false
        case "TRACK":
            if inCollection, var track = currentTrack {
                track.cuePoints = currentCuePoints.map { $0.sanitized() }
                                                  .sorted { $0.start < $1.start }
                tracks.append(track)
                trackMap[track.id] = track
                currentTrack = nil
                currentCuePoints = []
            }
        case "NODE":
            if inPlaylists, let node = playlistStack.popLast() {
                let playlist = Playlist(
                    id: UUID().uuidString,
                    name: node.name,
                    type: node.type == "0" ? .folder : .playlist,
                    trackIds: node.trackIds,
                    children: node.children
                )
                if let parent = playlistStack.last {
                    parent.children.append(playlist)
                } else {
                    // Top-level: skip ROOT, add its children
                    if node.name == "ROOT" {
                        playlists.append(contentsOf: node.children)
                    } else {
                        playlists.append(playlist)
                    }
                }
            }
        default:
            break
        }
    }

    private func parseCollectionTrack(_ attrs: [String: String]) {
        let location = attrs["Location"] ?? ""
        let decodedLocation = location
            .replacingOccurrences(of: "file://localhost", with: "")
            .removingPercentEncoding ?? location

        currentTrack = Track(
            id: attrs["TrackID"] ?? UUID().uuidString,
            name: attrs["Name"] ?? "Unknown Track",
            artist: attrs["Artist"] ?? "",
            album: attrs["Album"] ?? "",
            genre: attrs["Genre"] ?? "",
            totalTime: Int(attrs["TotalTime"] ?? "0") ?? 0,
            bpm: Double(attrs["AverageBpm"] ?? "0") ?? 0,
            tonality: attrs["Tonality"] ?? "",
            location: decodedLocation,
            cuePoints: []
        )
        currentCuePoints = []
    }

    private func parseCuePoint(_ attrs: [String: String]) {
        let r = min(max(Int(attrs["Red"] ?? "255") ?? 255, 0), 255)
        let g = min(max(Int(attrs["Green"] ?? "0") ?? 0, 0), 255)
        let b = min(max(Int(attrs["Blue"] ?? "0") ?? 0, 0), 255)

        let cue = CuePoint(
            id: UUID().uuidString,
            start: Double(attrs["Start"] ?? "0") ?? 0,
            name: attrs["Name"] ?? "",
            color: "rgb(\(r), \(g), \(b))",
            yValue: 100.0,
            curve: 1,
            enabled: true
        )
        currentCuePoints.append(cue)
    }
}
