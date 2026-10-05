import Foundation
import HAPKit

/// Fills an automatic playlist: the songs of the library that match its rules, in its order,
/// cut to its limit. Run again whenever the library changes, so new songs join by themselves.
enum RuleEngine {
    static func tracks(for rules: PlaylistRules, in library: [Track], artists: ArtistIndex,
                       shuffle: (inout [Track]) -> Void = { $0.shuffle() }) -> [Track] {
        guard !rules.rules.isEmpty, rules.limit != 0 else { return [] }
        let tests = rules.rules.map { matcher(for: $0, library: library, artists: artists) }
        let matched = library.filter { track in
            rules.match == .all ? tests.allSatisfy { $0(track) } : tests.contains { $0(track) }
        }
        var ordered = sorted(matched, by: rules.order, shuffle: shuffle)
        if let limit = rules.limit { ordered = Array(ordered.prefix(max(limit, 0))) }
        return ordered
    }

    /// What a page shows: like `tracks`, but a shuffled list keeps one order (by artist and
    /// album) instead of reshuffling on every redraw; it's shuffled when played.
    static func displayTracks(for rules: PlaylistRules, in library: [Track], artists: ArtistIndex) -> [Track] {
        var shown = rules
        if shown.order == .shuffled { shown.order = .artistAlbum }
        return tracks(for: shown, in: library, artists: artists)
    }

    /// The release year: the song's own, else its album's ("0" or missing = unknown).
    static func year(of track: Track) -> Int? {
        func parse(_ text: String?) -> Int? {
            guard let text, let year = Int(text.prefix(4)), year > 0 else { return nil }
            return year
        }
        return parse(track.releaseDate) ?? parse(track.album?.releaseDate)
    }

    /// Hi-res = more than 16 bits or more than 48 kHz (DSD too); CD = 16 bits at 44.1–48 kHz.
    static func quality(of track: Track) -> Set<Quality> {
        let codec = track.codec?.codecType?.lowercased() ?? ""
        if codec == "dsf" || codec == "dff" { return [.dsd, .hiRes] }
        let bits = track.codec?.bitWidth ?? 0, rate = track.codec?.sampleRate ?? 0
        if bits > 16 || rate > 48000 { return [.hiRes] }
        if bits == 16 && (44100...48000).contains(rate) { return [.cd] }
        return []
    }

    private static func matcher(for rule: PlaylistRule, library: [Track], artists: ArtistIndex) -> (Track) -> Bool {
        switch rule {
        case .year(let from, let to):
            guard from <= to else { return { _ in false } }  // an impossible range matches nothing
            return { year(of: $0).map { (from...to).contains($0) } ?? false }
        case .quality(let wanted):
            return { quality(of: $0).contains(wanted) }
        case .neverPlayed:
            return { ($0.numberOfPlays ?? 0) == 0 }
        case .playedAtLeast(let count):
            return { ($0.numberOfPlays ?? 0) >= count }
        case .newest(let count):
            let ids = Set(library.map(\.trackid).sorted(by: >).prefix(max(count, 0)))
            return { ids.contains($0.trackid) }
        case .genres(let names):
            let keys = Set(names.map(ArtistCredit.key))
            return { keys.contains(ArtistCredit.key($0.genre?.name ?? "")) }
        case .artists(let names):
            let ids = Set(names.compactMap { artists.entry(named: $0) }.flatMap { $0.own + $0.guest }.map(\.trackid))
            return { ids.contains($0.trackid) }
        }
    }

    private static func sorted(_ tracks: [Track], by order: PlaylistOrder, shuffle: (inout [Track]) -> Void) -> [Track] {
        switch order {
        case .shuffled:
            var copy = tracks
            shuffle(&copy)
            return copy
        case .newest:
            return tracks.sorted { $0.trackid > $1.trackid }
        case .mostPlayed:
            return tracks.sorted { ($0.numberOfPlays ?? 0, $0.trackid) > ($1.numberOfPlays ?? 0, $1.trackid) }
        case .artistAlbum:
            return tracks.sorted {
                (sortName($0.artist?.name), $0.album?.name ?? "", $0.diskNumber ?? 0, $0.trackNumber ?? 0)
                    < (sortName($1.artist?.name), $1.album?.name ?? "", $1.diskNumber ?? 0, $1.trackNumber ?? 0)
            }
        case .year:
            // Songs without a year go last.
            return tracks.sorted { (year(of: $0) ?? Int.max, sortName($0.artist?.name)) < (year(of: $1) ?? Int.max, sortName($1.artist?.name)) }
        }
    }
}
