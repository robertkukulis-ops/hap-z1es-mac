import Foundation
import Testing
@testable import HAPKit

// Library tests share StubProtocol with ClientTests, so they live in the same
// serialized suite (tests in an extension belong to that suite).
extension ClientTests {
    static let library = "/sony/contentdb/v100/audio"

    @Test func albumsFirstPageDecodes() async throws {
        StubProtocol.reset()
        StubProtocol.reply = try fixture("contentdb-albums-first5.json")
        // The fixture's "next" link points to offset=5; answer that with an empty page.
        StubProtocol.replies["\(Self.library)/albums?offset=5&limit=5"] = Data("{}".utf8)
        let albums = try await client.albums()
        #expect(albums.count == 5)
        #expect(albums[2].name == "A Retrospective")
        #expect(albums[2].albumArtist?.name == "Pink Martini")
        #expect(albums[2].releaseDate == "2011")
        #expect(albums[2].image?.url.hasSuffix("cover_art/A000001F") == true)
        #expect(albums[0].name == "")  // untagged album
        let first = try #require(StubProtocol.requestedURLs.first)
        #expect(first.path == "\(Self.library)/albums")
        #expect(first.query == "offset=0&limit=500")
        #expect(StubProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test func followsNextPageLinks() async throws {
        StubProtocol.reset()
        StubProtocol.replies["\(Self.library)/albums?offset=0&limit=500"] = try fixture("contentdb-albums-first5.json")
        StubProtocol.replies["\(Self.library)/albums?offset=5&limit=5"] = Data("""
            {"albums": [{"albumid": 176, "name": "The TBM Sounds"}],
             "paging": {"offset": 5, "limit": 5, "total": 6, "next": "", "previous": "x"}}
            """.utf8)
        let albums = try await client.albums()
        #expect(albums.map(\.albumid) == [135, 137, 31, 8, 42, 176])
        #expect(StubProtocol.requestedURLs.count == 2)
    }

    @Test func nextLinksKeepOurOwnAddress() async throws {
        // Reached by name, but the player writes its IP into "next": we keep the name.
        StubProtocol.reset()
        let byName = HAPClient(host: "HAP-Z1ES-001122334455.local", session: StubProtocol.session)
        StubProtocol.replies["\(Self.library)/albums?offset=0&limit=500"] = try fixture("contentdb-albums-first5.json")
        StubProtocol.replies["\(Self.library)/albums?offset=5&limit=5"] = Data("{}".utf8)
        _ = try await byName.albums()
        #expect(StubProtocol.requestedURLs.map { $0.host } == ["HAP-Z1ES-001122334455.local", "HAP-Z1ES-001122334455.local"])
    }

    @Test func refusesNextLinksOutsideTheLibrary() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data("""
            {"albums": [], "paging": {"next": "http://192.168.1.50:60200/sony/avContent"}}
            """.utf8)
        await #expect(throws: HAPError.self) { try await client.albums() }
        #expect(StubProtocol.requestedURLs.count == 1)
    }

    @Test func otherListsDecode() async throws {
        StubProtocol.reset()
        StubProtocol.replies["\(Self.library)/artists?offset=0&limit=500"] = try fixture("contentdb-artists-first3.json")
        StubProtocol.replies["\(Self.library)/genres?offset=0&limit=500"] = try fixture("contentdb-genres-first3.json")
        StubProtocol.replies["\(Self.library)/playlists?offset=0&limit=500"] = try fixture("contentdb-playlists-first3.json")
        StubProtocol.reply = Data("{}".utf8)  // any further page: empty

        let artists = try await client.artists()
        #expect(artists.map(\.name) == ["", "82J6", "Afrika Bambaataa"])
        #expect(artists[2].numberOfTracks == 10)

        let genres = try await client.genres()
        #expect(genres[1].name == "Acoustic Blues")

        let playlists = try await client.playlists()
        #expect(playlists.first?.name == "Newly Added")
        #expect(playlists.first?.playlistid == -1)
    }

    @Test func albumTracks() async throws {
        StubProtocol.reset()
        StubProtocol.reply = try fixture("contentdb-album176-tracks.json")
        let tracks = try await client.tracks(inAlbum: 176)
        #expect(tracks.count == 4)
        let track = try #require(tracks.first)
        #expect(track.name == "Aqua Marine")
        #expect(track.artist?.name == "Isao Suzuki Quartet")
        #expect(track.trackNumber == 4)
        #expect(track.duration == 299)
        #expect(track.codec?.sampleRate == 44100)
        #expect(track.codec?.codecType == "wav")
        #expect(track.album?.albumid == 176)
        #expect(StubProtocol.lastRequest?.url?.path == "\(Self.library)/albums/176/tracks")
    }

    @Test func unknownAlbumIsEmpty() async throws {
        // The player answers an unknown id with 200 "{}" (reported), not a 404.
        StubProtocol.reset()
        StubProtocol.reply = Data("{}".utf8)
        #expect(try await client.tracks(inAlbum: 999_999).isEmpty)
    }

    @Test func playlistTracksDecode() async throws {
        StubProtocol.reset()
        StubProtocol.replies["\(Self.library)/playlists/-1/tracks?offset=0&limit=500"] =
            try fixture("contentdb-playlist-1-tracks-first2.json")
        StubProtocol.replies["\(Self.library)/playlists/-1/tracks?offset=2&limit=2"] = Data("{}".utf8)
        let tracks = try await client.playlistTracks(-1)
        #expect(tracks.map(\.trackid).first == 3914)
        #expect(tracks.first?.name == "Perfect Picture")
        #expect(tracks.count == 2)
        #expect(StubProtocol.requestedURLs.first?.path == "\(Self.library)/playlists/-1/tracks")
        #expect(StubProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test func emptyPlaylistGivesNoTracks() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"tracks": [], "paging": {"next": ""}}"#.utf8)
        let tracks = try await client.playlistTracks(-4)
        #expect(tracks.isEmpty)
    }
}

@Suite struct LibraryStoreTests {
    @Test func savesAndLoadsASnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAPKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let udn = "uuid:00000000-0000-1010-8000-001122334455"
        #expect(store.load(playerUDN: udn) == nil)

        let page = try LibraryPage<Album>.decoder.decode(
            LibraryPage<Album>.self, from: try fixture("contentdb-albums-first5.json"))
        let snapshot = LibrarySnapshot(
            playerUDN: udn,
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),  // whole seconds: ISO 8601 has no fractions
            albums: page.items, artists: [], genres: [], playlists: []
        )
        try store.save(snapshot)
        #expect(store.load(playerUDN: udn) == snapshot)
        #expect(store.fileURL(for: udn).lastPathComponent == "library.json")
        #expect(!store.fileURL(for: udn).path.contains("uuid:"))  // no ":" in folder names
    }
}
