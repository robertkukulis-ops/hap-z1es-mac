import Foundation
import HAPKit
import Testing
@testable import HAPPlayer

struct ArtistCreditTests {
    @Test func featInAllItsSpellings() {
        for text in ["Estelle feat. Tarrus Riley", "Estelle Feat. Tarrus Riley", "Estelle Ft. Tarrus Riley",
                     "Estelle ft Tarrus Riley", "Estelle Feat Tarrus Riley", "Estelle featuring Tarrus Riley",
                     "Estelle (feat. Tarrus Riley)"] {
            let credit = ArtistCredit(text)
            #expect(credit.main == "Estelle", "\(text)")
            #expect(credit.guests == ["Tarrus Riley"], "\(text)")
        }
    }

    @Test func severalGuests() {
        #expect(ArtistCredit("Tory Lanez feat. Popcaan & Vybz Kartel").guests == ["Popcaan", "Vybz Kartel"])
        #expect(ArtistCredit("A ft. B, C and D").guests == ["B", "C", "D"])
    }

    @Test func bandNamesWithAndStayWhole() {
        #expect(ArtistCredit("Blood,Sweat & Tears").main == "Blood,Sweat & Tears")
        #expect(ArtistCredit("Queen Ifrica & Damian Marley").guests.isEmpty)
    }

    @Test func wordsContainingFtAreNotSplit() {
        // "Craft", "Daft Punk", "Left Side": "ft" inside a word is not a feature.
        #expect(ArtistCredit("Daft Punk").main == "Daft Punk")
        #expect(ArtistCredit("Left Side Brass").guests.isEmpty)
    }

    @Test func spellingVariantsAreTheSamePerson() {
        #expect(ArtistCredit.key("Deep Jahi") == ArtistCredit.key("Deepjahi"))
        #expect(ArtistCredit.key("Jah9") == ArtistCredit.key("JAH 9"))
        #expect(ArtistCredit.key("Estelle") != ArtistCredit.key("Estella"))
    }
}

struct ArtistIndexTests {
    private func track(_ id: Int, _ artist: String, album: String? = nil, albumArtist: String? = nil) throws -> Track {
        var json: [String: Any] = ["trackid": id, "name": "Song \(id)", "artist": ["name": artist]]
        if let album {
            var a: [String: Any] = ["albumid": 1, "name": album]
            if let albumArtist { a["album_artist"] = ["name": albumArtist] }
            json["album"] = a
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aGuestGetsTheSongOnTheirOwnPage() throws {
        let index = ArtistIndex(tracks: [try track(1, "Estelle feat. Tarrus Riley"), try track(2, "Estelle")])
        let tarrus = try #require(index.entry(named: "Tarrus Riley"))
        #expect(tarrus.own.isEmpty)
        #expect(tarrus.guest.map(\.trackid) == [1])
        let estelle = try #require(index.entry(named: "Estelle"))
        #expect(Set(estelle.own.map(\.trackid)) == [1, 2])
    }

    @Test func spellingVariantsAreOneArtistWithTheCommonestSpelling() throws {
        let index = ArtistIndex(tracks: [try track(1, "Deep Jahi"), try track(2, "Deep Jahi"), try track(3, "Deepjahi")])
        #expect(index.entries.count == 1)
        #expect(index.entries.first?.name == "Deep Jahi")
        #expect(index.entry(named: "Deepjahi")?.own.count == 3)
    }

    @Test func albumArtistCountsAsOwn() throws {
        let index = ArtistIndex(tracks: [try track(1, "Someone", album: "Best Of", albumArtist: "Pink Martini")])
        #expect(index.entry(named: "Pink Martini")?.own.map(\.trackid) == [1])
    }

    @Test func emptyNamesAreLeftOut() throws {
        let index = ArtistIndex(tracks: [try track(1, "")])
        #expect(index.entries.isEmpty)
    }
}
