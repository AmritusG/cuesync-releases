import Foundation

struct Track: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var genre: String
    var totalTime: Int             // Duration in seconds
    var bpm: Double
    var tonality: String
    var location: String           // File path
    var cuePoints: [CuePoint]

    var formattedDuration: String {
        let safe = max(totalTime, 0)
        let m = safe / 60
        let s = safe % 60
        return String(format: "%d:%02d", m, s)
    }

    var cueCount: Int { cuePoints.count }
}
