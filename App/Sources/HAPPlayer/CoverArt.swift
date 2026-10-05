import AppKit
import HAPKit
import Observation
import SwiftUI

/// Finds and keeps album covers the player doesn't have, and artist pictures.
///
/// Order for an album without a cover on the player: Apple's iTunes catalogue, Deezer,
/// MusicBrainz/Cover Art Archive; then a picture of the artist (Deezer); otherwise the app
/// draws a generated tile. Found pictures are saved on the Mac in
/// ~/Library/Caches/HAPKit/covers and shown in the app only: the music files are not changed.
/// Only album and artist names are sent to those services.
@MainActor @Observable
final class CoverArtStore {
    struct Entry: Codable {
        var file: String?       // image file in the covers folder, nil = nothing found
        var source: String?     // where it came from (a web address)
        var rejected: [String] = []
        var checked = Date()
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var isSearching = false
    private(set) var progress = (done: 0, total: 0)
    private(set) var lastSummary: String?
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAPKit/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    // MARK: Keys and lookups

    static func normalized(_ text: String) -> String {
        let noBrackets = text.replacingOccurrences(of: "\\s*[\\(\\[].*?[\\)\\]]", with: "", options: .regularExpression)
        let letters = noBrackets.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    static func albumKey(_ album: Album) -> String {
        "album|\(normalized(album.albumArtist?.name ?? ""))|\(normalized(album.name))"
    }

    static func artistKey(_ name: String) -> String { "artist|\(normalized(name))" }

    static func isUnknown(_ artist: String) -> Bool {
        let n = normalized(artist)
        return n.isEmpty || n == "unknown artist" || n == "various artists" || n == "test files"
    }

    func image(forKey key: String) -> NSImage? {
        if let cached = images[key] { return cached }
        guard let file = entries[key]?.file,
              let image = NSImage(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        images[key] = image
        return image
    }

    func albumImage(_ album: Album) -> NSImage? { image(forKey: Self.albumKey(album)) }

    func artistImage(_ name: String?) -> NSImage? {
        guard let name, !Self.isUnknown(name) else { return nil }
        return image(forKey: Self.artistKey(name))
    }

    // MARK: Finding

    /// Looks up everything that's missing: covers for albums the player has no cover for, and
    /// pictures for their artists (used when no cover is found, and on the Artists page).
    func findMissing(albums: [Album], artists: [String]) {
        guard !isSearching else { return }
        let needAlbums = albums.filter { $0.image == nil && entries[Self.albumKey($0)] == nil && !$0.name.isEmpty }
        let needArtists = Array(Set(artists + albums.filter { $0.image == nil }.compactMap { $0.albumArtist?.name }))
            .filter { !Self.isUnknown($0) && entries[Self.artistKey($0)] == nil }
        isSearching = true
        progress = (0, needAlbums.count + needArtists.count)
        lastSummary = nil
        searchTask = Task {
            var foundCovers = 0, foundArtists = 0
            for album in needAlbums {
                if Task.isCancelled { break }
                if await findCover(for: album) { foundCovers += 1 }
                progress.done += 1
            }
            for artist in needArtists {
                if Task.isCancelled { break }
                if await findArtistPicture(artist) { foundArtists += 1 }
                progress.done += 1
            }
            isSearching = false
            lastSummary = "Found \(foundCovers) of \(needAlbums.count) missing album covers and \(foundArtists) artist pictures."
        }
    }

    func stop() { searchTask?.cancel() }

    /// Finds a cover for one album; skips pictures you rejected. True if one was found.
    @discardableResult
    func findCover(for album: Album) async -> Bool {
        let key = Self.albumKey(album)
        let rejected = entries[key]?.rejected ?? []
        let artist = album.albumArtist?.name ?? ""
        for candidate in await Self.coverCandidates(album: album.name, artist: Self.isUnknown(artist) ? "" : artist)
        where !rejected.contains(candidate) {
            if await save(candidate, key: key) { return true }
        }
        entries[key] = Entry(file: nil, source: nil, rejected: rejected)
        persist()
        return false
    }

    @discardableResult
    func findArtistPicture(_ name: String) async -> Bool {
        let key = Self.artistKey(name)
        let rejected = entries[key]?.rejected ?? []
        for candidate in await Self.artistCandidates(name) where !rejected.contains(candidate) {
            if await save(candidate, key: key) { return true }
        }
        entries[key] = Entry(file: nil, source: nil, rejected: rejected)
        persist()
        return false
    }

    /// "Use a different cover": forget this one and look for the next candidate.
    func reject(album: Album) async {
        let key = Self.albumKey(album)
        var entry = entries[key] ?? Entry()
        if let source = entry.source { entry.rejected.append(source) }
        removeFile(entry)
        entry.file = nil
        entry.source = nil
        entries[key] = entry
        images[key] = nil
        persist()
        await findCover(for: album)
    }

    /// "Remove cover": show the generated tile instead (and don't search again).
    func remove(album: Album) {
        let key = Self.albumKey(album)
        var entry = entries[key] ?? Entry()
        if let source = entry.source { entry.rejected.append(source) }
        removeFile(entry)
        entry.file = nil
        entry.source = nil
        entries[key] = entry
        images[key] = nil
        persist()
    }

    private func removeFile(_ entry: Entry) {
        if let file = entry.file { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
    }

    private func save(_ address: String, key: String) async -> Bool {
        guard let url = URL(string: address),
              let (data, response) = try? await URLSession.shared.data(for: Self.request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.size.width >= 100 else { return false }
        let file = "\(stableHash(key))-\(UUID().uuidString.prefix(6)).jpg"
        guard (try? data.write(to: folder.appendingPathComponent(file))) != nil else { return false }
        var entry = entries[key] ?? Entry()
        removeFile(entry)
        entry.file = file
        entry.source = address
        entry.checked = Date()
        entries[key] = entry
        images[key] = image
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        }
    }

    // MARK: Online sources (only names are sent)

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("HAPCollection/0.1 (personal music library)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func json(_ url: URL?) async -> [String: Any]? {
        guard let url, let (data, _) = try? await URLSession.shared.data(for: request(url)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func matches(_ found: String?, _ wanted: String) -> Bool {
        guard let found else { return false }
        let a = normalized(found), b = normalized(wanted)
        return !b.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a))
    }

    static func artistMatches(_ found: String?, _ wanted: String) -> Bool {
        wanted.isEmpty || matches(found, wanted)
            || normalized(found ?? "").contains(normalized(wanted)) || normalized(wanted).contains(normalized(found ?? "#"))
    }

    /// Picture addresses for an album, best first.
    static func coverCandidates(album: String, artist: String) async -> [String] {
        var results: [String] = []
        // 1. Apple's iTunes catalogue.
        var itunes = URLComponents(string: "https://itunes.apple.com/search")!
        itunes.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(normalized(album))"),
                             URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "10")]
        for item in (await json(itunes.url)?["results"] as? [[String: Any]]) ?? []
        where matches(item["collectionName"] as? String, album) && artistMatches(item["artistName"] as? String, artist) {
            if let art = item["artworkUrl100"] as? String {
                results.append(art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            }
        }
        // 2. Deezer.
        var deezer = URLComponents(string: "https://api.deezer.com/search/album")!
        deezer.queryItems = [URLQueryItem(name: "q", value: artist.isEmpty ? "album:\"\(album)\"" : "artist:\"\(artist)\" album:\"\(album)\"")]
        for item in (await json(deezer.url)?["data"] as? [[String: Any]]) ?? []
        where matches(item["title"] as? String, album)
            && artistMatches((item["artist"] as? [String: Any])?["name"] as? String, artist) {
            if let art = item["cover_xl"] as? String { results.append(art) }
        }
        // 3. MusicBrainz + Cover Art Archive.
        var mb = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        let q = artist.isEmpty ? "release:\"\(album)\"" : "release:\"\(album)\" AND artist:\"\(artist)\""
        mb.queryItems = [URLQueryItem(name: "query", value: q), URLQueryItem(name: "fmt", value: "json"),
                         URLQueryItem(name: "limit", value: "5")]
        for release in (await json(mb.url)?["releases"] as? [[String: Any]]) ?? []
        where (release["score"] as? Int ?? 0) >= 90 {
            if let id = release["id"] as? String { results.append("https://coverartarchive.org/release/\(id)/front-500") }
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    /// Picture addresses for an artist (Deezer), best first.
    static func artistCandidates(_ name: String) async -> [String] {
        var deezer = URLComponents(string: "https://api.deezer.com/search/artist")!
        deezer.queryItems = [URLQueryItem(name: "q", value: name)]
        return ((await json(deezer.url)?["data"] as? [[String: Any]]) ?? [])
            .filter { matches($0["name"] as? String, name) }
            .compactMap { $0["picture_xl"] as? String }
            .filter { !$0.contains("/artist//") }  // Deezer's "no picture" placeholder
    }
}

// MARK: - Showing artwork

/// Album artwork: the player's cover, else a found cover, else the artist's picture, else a
/// generated tile.
struct ArtworkView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(CoverArtStore.self) private var covers
    let album: Album?
    var fallbackTitle = ""
    var fallbackArtist = ""
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let album, album.image != nil {
                AsyncImage(url: player.coverURL(album.image)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if case .failure = phase {
                        found
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
            } else {
                found
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder private var found: some View {
        let title = album.map { named($0.name, fallbackTitle) } ?? fallbackTitle
        let artist = album?.albumArtist?.name ?? fallbackArtist
        if let album, let image = covers.albumImage(album) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let image = covers.artistImage(artist) {
            ZStack(alignment: .bottomLeading) {
                Image(nsImage: image).resizable().scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2).padding(8)
            }
        } else {
            GeneratedArt(title: title, subtitle: artist)
        }
    }
}

/// A generated, album-art-style tile: colours from the album's name, title and artist set on it.
struct GeneratedArt: View {
    let title: String
    let subtitle: String

    var body: some View {
        let hue = Double(stableHash(CoverArtStore.normalized(title + subtitle)) % 360) / 360
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                        Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: geo.size.width * 0.45, weight: .light))
                    .foregroundStyle(.white.opacity(0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(geo.size.width * 0.06)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: max(9, geo.size.width * 0.1), weight: .semibold, design: .serif))
                        .lineLimit(3)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: max(8, geo.size.width * 0.07))).opacity(0.8).lineLimit(2)
                    }
                }
                .foregroundStyle(.white)
                .padding(geo.size.width * 0.08)
            }
        }
    }
}

/// The same number for the same text on every launch (Swift's own hashValue changes each run).
func stableHash(_ text: String) -> UInt64 {
    text.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) }  // djb2
}
