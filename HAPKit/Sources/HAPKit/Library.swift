import Foundation

// The player's music database ("contentdb"): read-only GET requests on port 60200,
// e.g. GET /sony/contentdb/v100/audio/albums?offset=0&limit=500
// Verified on our player 2026-09-28 (NOTES.md, "Library browsing").

/// A name-only reference, e.g. `"album_artist": {"name": "Pink Martini"}`.
public struct NameRef: Codable, Sendable, Hashable {
    public let name: String
}

/// Link to a cover-art image on the player.
public struct ImageRef: Codable, Sendable, Hashable {
    public let url: String
}

public struct Album: LibraryItem {
    public let albumid: Int
    /// Empty when the files have no album tag.
    public let name: String
    public let releaseDate: String?
    public let numberOfTracks: Int?
    /// Total length in seconds.
    public let duration: Int?
    public let albumArtist: NameRef?
    public let image: ImageRef?

    public var id: Int { albumid }
    static let listKey = "albums"
}

public struct Artist: LibraryItem {
    public let artistid: Int
    public let name: String
    public let numberOfTracks: Int?

    public var id: Int { artistid }
    static let listKey = "artists"
}

public struct Genre: LibraryItem {
    public let genreid: Int
    public let name: String
    public let numberOfTracks: Int?

    public var id: Int { genreid }
    static let listKey = "genres"
}

/// Includes the player's automatic lists ("Newly Added", "Most Played"…), which have negative ids.
public struct Playlist: LibraryItem {
    public let playlistid: Int
    public let name: String
    public let numberOfTracks: Int?
    public let version: Int?
    public let type: String?

    public var id: Int { playlistid }
    static let listKey = "playlists"
}

public struct Track: LibraryItem {
    public let trackid: Int
    public let name: String
    public let filename: String?
    public let trackNumber: Int?
    public let diskNumber: Int?
    /// Length in seconds.
    public let duration: Int?
    public let releaseDate: String?
    public let artist: ArtistRef?
    public let album: Album?
    public let genre: GenreRef?
    public let codec: Codec?
    public let numberOfPlays: Int?
    public let favoriteType: String?

    public var id: Int { trackid }
    static let listKey = "tracks"

    public struct ArtistRef: Codable, Sendable, Hashable {
        public let artistid: Int?
        public let name: String
    }

    public struct GenreRef: Codable, Sendable, Hashable {
        public let genreid: Int?
        public let name: String
    }

    public struct Codec: Codable, Sendable, Hashable {
        public let bitWidth: Int?
        public let bitRate: Int?
        public let sampleRate: Int?
        public let codecType: String?
    }
}

/// Anything the library lists: albums, artists, genres, playlists, tracks.
protocol LibraryItem: Codable, Sendable, Hashable, Identifiable where ID == Int {
    /// The key holding the list in the reply, e.g. "albums".
    static var listKey: String { get }
}

extension HAPClient {
    /// Library requests can be slow on big libraries (reported: up to a minute or more
    /// when the player is "cold"), so they get a much longer timeout than commands.
    static let libraryTimeout: TimeInterval = 60
    /// Items per page. The player accepts up to 5000 (reported), 500 keeps each reply small.
    static let pageSize = 500

    // MARK: - Whole lists (every page)

    public func albums() async throws -> [Album] { try await everyPage("albums") }
    public func artists() async throws -> [Artist] { try await everyPage("artists") }
    public func genres() async throws -> [Genre] { try await everyPage("genres") }
    public func playlists() async throws -> [Playlist] { try await everyPage("playlists") }

    /// Every track in the library (slow on big libraries; fast on ours: ~600 tracks).
    public func allTracks() async throws -> [Track] { try await everyPage("tracks") }

    /// Tracks of one album, in the player's order. Empty if the album id is unknown.
    public func tracks(inAlbum albumID: Int) async throws -> [Track] {
        try await everyPage("albums/\(albumID)/tracks")
    }

    /// Tracks of one of the player's playlists, in its order. The player's automatic lists
    /// ("Newly Added", "Most Played"…) have negative ids.
    public func playlistTracks(_ playlistID: Int) async throws -> [Track] {
        try await everyPage("playlists/\(playlistID)/tracks")
    }

    // MARK: - Plumbing

    var libraryBaseURL: URL { baseURL.appendingPathComponent("contentdb/v100/audio") }

    /// Downloads the first page, then follows the player's own `next` links.
    func everyPage<Item: LibraryItem>(_ relativePath: String) async throws -> [Item] {
        var components = URLComponents(
            url: libraryBaseURL.appendingPathComponent(relativePath),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ]
        var nextURL: URL? = components.url
        var items: [Item] = []
        var pagesLeft = 1000  // guards against a player that keeps saying "next"
        while let url = nextURL, pagesLeft > 0 {
            let page: LibraryPage<Item> = try await getLibraryPage(url)
            items += page.items
            nextURL = try page.paging?.next.flatMap { try checkedNextURL($0) }
            pagesLeft -= 1
        }
        return items
    }

    /// Only follow `next` links inside this player's library. We keep our own address and
    /// take just the path and page numbers from the link (the player writes its IP there,
    /// which may differ from how we reached it, e.g. by its .local name).
    func checkedNextURL(_ text: String) throws -> URL? {
        try checkedURL(text, inside: libraryBaseURL)
    }

    /// Links the player gives us are only followed inside `base` (the music library, or its
    /// folder view), keeping our own address and taking just the path and page numbers.
    func checkedURL(_ text: String, inside base: URL) throws -> URL? {
        guard !text.isEmpty else { return nil }
        guard let link = URLComponents(string: text),
              link.path == base.path || link.path.hasPrefix(base.path + "/"),
              var next = URLComponents(url: libraryBaseURL, resolvingAgainstBaseURL: false)
        else {
            throw HAPError.unexpectedResponse("refusing to follow a next-page link outside the library: \(text)")
        }
        next.path = link.path
        next.queryItems = link.queryItems
        return next.url
    }

    private func getLibraryPage<Item: LibraryItem>(_ url: URL) async throws -> LibraryPage<Item> {
        let data = try await getLibraryData(url)
        do {
            return try LibraryPage<Item>.decoder.decode(LibraryPage<Item>.self, from: data)
        } catch {
            throw HAPError.unexpectedResponse("\(url.path): \(error)")
        }
    }

    /// A read-only GET from the player's music database, retried like other questions.
    func getLibraryData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.libraryTimeout)
        request.httpMethod = "GET"
        var result: Data?
        var lastError: Error = HAPError.timedOut(url.path)
        for _ in 0..<Self.attemptsForQuestions where result == nil {
            do {
                result = try await serialized { [session, request] in
                    try await Self.send(request, session: session)
                }
            } catch let error as HAPError where error.isWorthRetrying {
                lastError = error
            }
        }
        guard let data = result else { throw lastError }
        return data
    }
}

/// One page of a list: `{"albums": [...], "paging": {...}, "request": "..."}`.
/// An unknown id answers `{}`, which becomes an empty page.
struct LibraryPage<Item: LibraryItem>: Decodable {
    let items: [Item]
    let paging: Paging?

    struct Paging: Decodable {
        let offset: Int?
        let limit: Int?
        let total: Int?
        let next: String?
        let previous: String?
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        items = try container.decodeIfPresent([Item].self, forKey: Key(Item.listKey)) ?? []
        paging = try container.decodeIfPresent(Paging.self, forKey: Key("paging"))
    }
}
