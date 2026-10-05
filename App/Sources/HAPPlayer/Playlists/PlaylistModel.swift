import Foundation
import HAPKit

/// The user's own playlists, kept on the Mac (nothing is written to the player).

/// One song in a hand-picked playlist. The track id finds it; title, artist and album let the
/// app find it again if the player ever gives the song a new id.
struct PlaylistEntry: Codable, Equatable {
    var trackID: Int
    var title: String
    var artist: String
    var album: String
}

extension PlaylistEntry {
    init(track: Track) {
        self.init(trackID: track.trackid, title: track.name,
                  artist: track.artist?.name ?? "", album: track.album?.name ?? "")
    }
}

enum Quality: String, Codable, CaseIterable {
    case hiRes, cd, dsd
}

/// One rule of an automatic playlist.
enum PlaylistRule: Codable, Equatable {
    case year(from: Int, to: Int)
    case quality(Quality)
    case neverPlayed
    case playedAtLeast(Int)
    /// Among the N songs added last (the player numbers songs in the order it adds them).
    case newest(Int)
    case genres([String])
    /// Artist names as shown; matched spelling-insensitively, guests included.
    case artists([String])
}

enum MatchMode: String, Codable {
    case all, any
}

enum PlaylistOrder: String, Codable, CaseIterable {
    case shuffled, newest, mostPlayed, artistAlbum, year
}

struct PlaylistRules: Codable, Equatable {
    var match: MatchMode
    var rules: [PlaylistRule]
    /// At most this many songs; nil = all that match.
    var limit: Int?
    var order: PlaylistOrder
}

enum PlaylistKind: Codable, Equatable {
    case handPicked([PlaylistEntry])
    case automatic(PlaylistRules)
}

struct SavedPlaylist: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: PlaylistKind

    var isAutomatic: Bool {
        if case .automatic = kind { return true }
        return false
    }
}
