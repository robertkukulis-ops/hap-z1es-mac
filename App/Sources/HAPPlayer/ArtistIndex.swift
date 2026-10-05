import Foundation
import HAPKit

/// Who's on a song, read from its artist text: "Estelle feat. Tarrus Riley" → main artist
/// Estelle, guest Tarrus Riley. Only "feat." / "ft." / "featuring" mark guests; "&" is left
/// alone, because it's also part of band names (Blood, Sweat & Tears).
struct ArtistCredit: Equatable {
    let main: String
    let guests: [String]

    // Made when needed: Regex values can't be shared between threads in Swift 6.
    private static var featuring: Regex<AnyRegexOutput> { try! Regex(#"(?i)\s+[\(\[]?(?:feat\.?|ft\.?|featuring)\s+"#) }
    private static var guestSeparator: Regex<AnyRegexOutput> { try! Regex(#"(?i)\s*(?:,|&|\band\b)\s*"#) }

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: Self.featuring) else {
            main = trimmed
            guests = []
            return
        }
        main = String(trimmed[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = trimmed[match.range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " )]"))
        guests = rest.split(separator: Self.guestSeparator).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The same person despite spaces, capitals, accents or punctuation ("Deepjahi" = "Deep Jahi").
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }
}

/// The Artists page, built from the songs themselves: spelling variants are one artist, and a
/// guest ("feat.") also gets the song on their own page.
struct ArtistIndex {
    struct Entry: Identifiable {
        let id: String       // ArtistCredit.key of the name
        let name: String     // the commonest spelling
        let own: [Track]     // as main artist or album artist
        let guest: [Track]   // as a "feat." guest
        var trackCount: Int { own.count + guest.count }
    }

    let entries: [Entry]
    private let byKey: [String: Entry]

    init(tracks: [Track]) {
        var spellings: [String: [String: Int]] = [:]
        var own: [String: [Track]] = [:], guest: [String: [Track]] = [:]
        var seen: Set<String> = []

        func add(_ name: String, _ track: Track, asGuest: Bool) {
            let key = ArtistCredit.key(name)
            guard !key.isEmpty, seen.insert("\(key)|\(asGuest)|\(track.trackid)").inserted else { return }
            spellings[key, default: [:]][name, default: 0] += 1
            if asGuest { guest[key, default: []].append(track) } else { own[key, default: []].append(track) }
        }

        for track in tracks {
            if let text = track.artist?.name {
                let credit = ArtistCredit(text)
                add(credit.main, track, asGuest: false)
                for name in credit.guests { add(name, track, asGuest: true) }
            }
            if let albumArtist = track.album?.albumArtist?.name {
                add(ArtistCredit(albumArtist).main, track, asGuest: false)
            }
        }

        let made = spellings.map { key, counts in
            let name = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            return Entry(id: key, name: name, own: own[key] ?? [], guest: guest[key] ?? [])
        }
        entries = made.sorted { sortName($0.name) < sortName($1.name) }
        byKey = Dictionary(uniqueKeysWithValues: made.map { ($0.id, $0) })
    }

    /// The artist for a name as written anywhere (any spelling; "X feat. Y" finds X).
    func entry(named name: String) -> Entry? {
        byKey[ArtistCredit.key(name)] ?? byKey[ArtistCredit.key(ArtistCredit(name).main)]
    }
}
