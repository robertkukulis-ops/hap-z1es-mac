import Foundation
import HAPKit
import Testing
@testable import HAPPlayer

struct RuleEngineTests {
    private func run(_ rules: [PlaylistRule], match: MatchMode = .all, limit: Int? = nil,
                     order: PlaylistOrder = .newest, _ library: [Track]) -> [Int] {
        let r = PlaylistRules(match: match, rules: rules, limit: limit, order: order)
        return RuleEngine.tracks(for: r, in: library, artists: ArtistIndex(tracks: library)).map(\.trackid)
    }

    @Test func yearRangeMatchesInclusive() throws {
        let lib = [try makeTrack(1, year: "1970"), try makeTrack(2, year: "1979-05-01"), try makeTrack(3, year: "1980"),
                   try makeTrack(4, year: "0"), try makeTrack(5, album: "A", albumYear: "1975")]
        #expect(Set(run([.year(from: 1970, to: 1979)], lib)) == [1, 2, 5])
    }

    @Test func qualityHiResCdDsd() throws {
        #expect(RuleEngine.quality(of: try makeTrack(1, bits: 24, rate: 44100, codec: "flac")) == [.hiRes])
        #expect(RuleEngine.quality(of: try makeTrack(2, bits: 16, rate: 96000, codec: "flac")) == [.hiRes])
        #expect(RuleEngine.quality(of: try makeTrack(3, bits: 16, rate: 44100, codec: "flac")) == [.cd])
        #expect(RuleEngine.quality(of: try makeTrack(4, bits: 1, rate: 2822400, codec: "dsf")) == [.dsd, .hiRes])
        #expect(RuleEngine.quality(of: try makeTrack(5, bits: 16, rate: 48000, codec: "mp3")) == [.cd])
    }

    @Test func neverPlayedAndPlayedAtLeast() throws {
        let lib = [try makeTrack(1), try makeTrack(2, plays: 0), try makeTrack(3, plays: 3), try makeTrack(4, plays: 5)]
        #expect(Set(run([.neverPlayed], lib)) == [1, 2])
        #expect(Set(run([.playedAtLeast(3)], lib)) == [3, 4])
    }

    @Test func newestTakesHighestTrackIDs() throws {
        let lib = [try makeTrack(5), try makeTrack(9), try makeTrack(7)]
        #expect(Set(run([.newest(2)], lib)) == [9, 7])
    }

    @Test func genresIsOneOf() throws {
        let lib = [try makeTrack(1, genre: "Reggae"), try makeTrack(2, genre: "Dub"), try makeTrack(3, genre: "Jazz")]
        #expect(Set(run([.genres(["Reggae", "Dub"])], lib)) == [1, 2])
    }

    @Test func artistsIncludesGuests() throws {
        let lib = [try makeTrack(1, artist: "Estelle feat. Tarrus Riley"), try makeTrack(2, artist: "Estelle")]
        #expect(run([.artists(["Tarrus Riley"])], lib) == [1])
    }

    @Test func allVersusAny() throws {
        let lib = [try makeTrack(1, bits: 24, rate: 96000, genre: "Jazz"), try makeTrack(2, bits: 16, rate: 44100, genre: "Jazz"),
                   try makeTrack(3, bits: 24, rate: 96000, genre: "Rock")]
        #expect(run([.genres(["Jazz"]), .quality(.hiRes)], match: .all, lib) == [1])
        #expect(Set(run([.genres(["Jazz"]), .quality(.hiRes)], match: .any, lib)) == [1, 2, 3])
    }

    @Test func limitCutsAfterOrdering() throws {
        let lib = [try makeTrack(5), try makeTrack(9), try makeTrack(7)]
        #expect(run([.newest(10)], limit: 2, order: .newest, lib) == [9, 7])
    }

    @Test func ordersSortAsSpecified() throws {
        let lib = [try makeTrack(1, artist: "B", album: "X", year: "1990", plays: 2),
                   try makeTrack(2, artist: "A", album: "Y", year: "1970", plays: 9),
                   try makeTrack(3, artist: "C", album: "Z", year: "1980", plays: 5)]
        let all = [PlaylistRule.newest(10)]
        #expect(run(all, order: .newest, lib) == [3, 2, 1])
        #expect(run(all, order: .mostPlayed, lib) == [2, 3, 1])
        #expect(run(all, order: .artistAlbum, lib) == [2, 1, 3])
        #expect(run(all, order: .year, lib) == [2, 3, 1])
        let r = PlaylistRules(match: .all, rules: all, limit: nil, order: .shuffled)
        let shuffled = RuleEngine.tracks(for: r, in: lib, artists: ArtistIndex(tracks: lib)) { $0.reverse() }
        #expect(Set(shuffled.map(\.trackid)) == [1, 2, 3])  // the injected shuffle was used
    }

    @Test func impossibleRulesGiveNoSongs() throws {
        let lib = [try makeTrack(1, year: "1985", genre: "Jazz")]
        #expect(run([.genres([])], lib).isEmpty)
        #expect(run([.year(from: 1990, to: 1980)], lib).isEmpty)
        #expect(run([.genres(["Jazz"])], limit: 0, lib).isEmpty)
        #expect(run([], lib).isEmpty)  // no rules at all: no songs
    }

    @Test func codableRoundTrip() throws {
        let hand = SavedPlaylist(id: UUID(), name: "Sunday", kind: .handPicked([PlaylistEntry(trackID: 1, title: "T", artist: "A", album: "B")]))
        let auto = SavedPlaylist(id: UUID(), name: "70s", kind: .automatic(PlaylistRules(
            match: .any, rules: [.year(from: 1970, to: 1979), .quality(.hiRes), .neverPlayed, .playedAtLeast(2),
                                 .newest(50), .genres(["Jazz"]), .artists(["Buika"])], limit: 30, order: .shuffled)))
        let data = try JSONEncoder().encode([hand, auto])
        #expect(try JSONDecoder().decode([SavedPlaylist].self, from: data) == [hand, auto])
    }
}

struct ReviewFixTests {
    @Test func shuffledListsShowAStableOrder() throws {
        // On screen a shuffled list keeps one order (by artist and album); Play shuffles.
        let lib = [try makeTrack(1, artist: "C"), try makeTrack(2, artist: "A"), try makeTrack(3, artist: "B")]
        let rules = PlaylistRules(match: .all, rules: [.newest(10)], limit: nil, order: .shuffled)
        let shown = RuleEngine.displayTracks(for: rules, in: lib, artists: ArtistIndex(tracks: lib)).map(\.trackid)
        #expect(shown == [2, 3, 1])
        #expect(RuleEngine.displayTracks(for: rules, in: lib, artists: ArtistIndex(tracks: lib)).map(\.trackid) == shown)
    }

    @Test func numberFieldReadsWhatIsTyped() {
        #expect(NumberField.parse("1975") == 1975)
        #expect(NumberField.parse(" 12 ") == 12)
        #expect(NumberField.parse("abc") == nil)
        #expect(NumberField.parse("") == nil)
    }

    @Test func removingARuleKeepsTheOthersAndTheirIdentity() {
        var list = EditableRules([.neverPlayed, .newest(5), .genres(["Jazz"])])
        let keep = list.items.map(\.id)
        list.remove(keep[1])
        #expect(list.rules == [.neverPlayed, .genres(["Jazz"])])
        #expect(list.items.map(\.id) == [keep[0], keep[2]])
    }
}
