import Foundation
import HAPKit

enum RepeatMode: String, CaseIterable {
    case off, all, one

    /// The REPEAT button cycles off → all → one → off.
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// "Play album" and friends: the player can only be told to play one track at a time from the
/// Mac (NOTES.md), so the app keeps the list and starts the next track when one ends. Shuffle
/// and repeat live here too (the player's own shuffle/repeat only know the current song).
struct AppQueue: Equatable {
    /// The list as it was started (shuffle off goes back to this order).
    let original: [Track]
    /// The order songs are played in (shuffled or the original).
    private(set) var tracks: [Track]
    var index: Int
    let title: String
    /// The current track has been seen playing (so a later stop means it ended).
    var sawPlaying = false
    var lastPosition = 0.0
    var startedAt = Date()

    var current: Track { tracks[index] }

    /// How much of the list is played, by playing time: the songs before the current one
    /// plus `position` seconds into it (0…1; 0 when the songs have no lengths).
    func progress(position: Double) -> Double {
        let total = Double(tracks.compactMap(\.duration).reduce(0, +))
        guard total > 0 else { return 0 }
        let done = Double(tracks[..<index].compactMap(\.duration).reduce(0, +)) + position
        return min(max(done / total, 0), 1)
    }

    /// Starts at `start`; shuffled, that song comes first and the rest follow in random order.
    init(songs: [Track], start: Int, title: String, shuffled: Bool, shuffle: (inout [Track]) -> Void) {
        original = songs
        self.title = title
        if shuffled {
            var rest = songs
            let first = rest.remove(at: start)
            shuffle(&rest)
            tracks = [first] + rest
            index = 0
        } else {
            tracks = songs
            index = start
        }
    }

    /// Shuffle on: the current song keeps playing and the songs still to come are shuffled.
    /// Shuffle off: back to the list order, carrying on after the current song.
    mutating func setShuffle(_ on: Bool, shuffle: (inout [Track]) -> Void) {
        let playing = current
        if on {
            var rest = Array(tracks[(index + 1)...])
            shuffle(&rest)
            tracks = Array(tracks[...index]) + rest
        } else {
            tracks = original
            index = original.firstIndex { $0.trackid == playing.trackid } ?? 0
        }
    }

    /// The current song ended: what plays next? false = the list is over.
    mutating func advanceAfterSongEnded(repeat mode: RepeatMode, shuffled: Bool, shuffle: (inout [Track]) -> Void) -> Bool {
        if mode == .one {
            resetForNewSong()
            return true
        }
        return skipForward(repeat: mode, shuffled: shuffled, shuffle: shuffle)
    }

    /// ⏭ / the dial: the next song, even with repeat one; at the end only repeat all wraps
    /// around (freshly shuffled when shuffle is on).
    mutating func skipForward(repeat mode: RepeatMode, shuffled: Bool, shuffle: (inout [Track]) -> Void) -> Bool {
        if index + 1 < tracks.count {
            index += 1
        } else if mode == .all {
            if shuffled {
                var again = original
                shuffle(&again)
                tracks = again
            }
            index = 0
        } else {
            return false
        }
        resetForNewSong()
        return true
    }

    /// ⏮: near the start of a song go back one, otherwise restart this song.
    mutating func skipBack(position: Double) {
        if position < 3, index > 0 { index -= 1 }
        resetForNewSong()
    }

    private mutating func resetForNewSong() {
        sawPlaying = false
        startedAt = Date()
    }
}
