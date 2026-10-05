import Foundation

/// The lists we keep on the Mac so screens open instantly.
/// The top-level lists and the full track list are saved; an album's tracks can also be
/// asked for live.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    /// Which player this belongs to (its permanent unique ID).
    public let playerUDN: String
    public let fetchedAt: Date
    public let albums: [Album]
    public let artists: [Artist]
    public let genres: [Genre]
    public let playlists: [Playlist]
    /// Every track (added 2026-09-28; empty in copies saved before that).
    public let tracks: [Track]

    public init(playerUDN: String, fetchedAt: Date, albums: [Album], artists: [Artist],
                genres: [Genre], playlists: [Playlist], tracks: [Track] = []) {
        self.playerUDN = playerUDN
        self.fetchedAt = fetchedAt
        self.albums = albums
        self.artists = artists
        self.genres = genres
        self.playlists = playlists
        self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey {
        case playerUDN, fetchedAt, albums, artists, genres, playlists, tracks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerUDN = try c.decode(String.self, forKey: .playerUDN)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        albums = try c.decode([Album].self, forKey: .albums)
        artists = try c.decode([Artist].self, forKey: .artists)
        genres = try c.decode([Genre].self, forKey: .genres)
        playlists = try c.decode([Playlist].self, forKey: .playlists)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    }
}

/// Saves and loads `LibrarySnapshot`s, one file per player,
/// by default in ~/Library/Caches/HAPKit/<player id>/library.json
public struct LibraryStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAPKit", isDirectory: true)
    }

    func fileURL(for udn: String) -> URL {
        let safe = udn.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("library.json")
    }

    /// The saved lists for this player, or nil if there are none yet.
    public func load(playerUDN: String) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: playerUDN)) else { return nil }
        return try? Self.decoder.decode(LibrarySnapshot.self, from: data)
    }

    public func save(_ snapshot: LibrarySnapshot) throws {
        let url = fileURL(for: snapshot.playerUDN)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// Downloads the four lists from the player (one after another) and saves them.
    public func refresh(from client: HAPClient, playerUDN: String) async throws -> LibrarySnapshot {
        let snapshot = LibrarySnapshot(
            playerUDN: playerUDN,
            fetchedAt: Date(),
            albums: try await client.albums(),
            artists: try await client.artists(),
            genres: try await client.genres(),
            playlists: try await client.playlists(),
            tracks: try await client.allTracks()
        )
        try save(snapshot)
        return snapshot
    }

    // Saved with Swift's own property names (not the player's snake_case),
    // so every field round-trips exactly.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
