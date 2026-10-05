import Foundation
import HAPKit

/// A hand-picked playlist as it can be played now: the songs the player still has.
struct ResolvedPlaylist {
    let tracks: [Track]
    /// `entryIndexes[i]` is where `tracks[i]` is stored in the playlist (hidden songs are
    /// skipped), so moving or removing a shown row changes the right stored entry.
    let entryIndexes: [Int]
    /// The entries with corrected track ids, when a song was found again by its name; nil
    /// when nothing needs saving.
    let updatedEntries: [PlaylistEntry]?
    let hiddenCount: Int
}

/// Finds a playlist's saved songs in the current library: by track id, or else by title +
/// artist + album (spelling-insensitive, only if exactly one song fits). Songs not found are
/// hidden but stay saved, so they come back if the song returns.
enum PlaylistResolver {
    static func resolve(_ entries: [PlaylistEntry], in library: [Track]) -> ResolvedPlaylist {
        let byID = Dictionary(library.map { ($0.trackid, $0) }, uniquingKeysWith: { first, _ in first })
        // The name index is only needed when a track id is missing (rare), so build it then.
        var byName: [String: [Track]]?
        var tracks: [Track] = [], indexes: [Int] = [], updated = entries, changed = false
        for (index, entry) in entries.enumerated() {
            var found = byID[entry.trackID]
            if found == nil, !library.isEmpty {
                byName = byName ?? Dictionary(grouping: library) { key($0.name, $0.artist?.name, $0.album?.name) }
            }
            if found == nil, let candidates = byName?[key(entry.title, entry.artist, entry.album)], candidates.count == 1 {
                found = candidates[0]
                updated[index].trackID = candidates[0].trackid
                changed = true
            }
            // The same song twice (an old entry found again by name, plus a new one) shows once.
            if let found, !tracks.contains(where: { $0.trackid == found.trackid }) {
                tracks.append(found)
                indexes.append(index)
            }
        }
        return ResolvedPlaylist(tracks: tracks, entryIndexes: indexes, updatedEntries: changed ? updated : nil,
                                hiddenCount: entries.count - tracks.count)
    }

    private static func key(_ title: String, _ artist: String?, _ album: String?) -> String {
        [title, artist ?? "", album ?? ""].map(ArtistCredit.key).joined(separator: "|")
    }
}
