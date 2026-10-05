import Foundation

// The player's own folder view ("services/directory"): the same folders as the drive,
// with each music file already linked to its library track (trackid, tags, cover).
// Read-only GET requests, e.g. GET /sony/contentdb/v100/services/directory/4100
// Verified 2026-09-28: items carry "filename" and "trackid" (NOTES.md).

/// One entry in a folder, as the player sees it.
public enum DirectoryItem: Sendable, Equatable {
    case folder(name: String, url: String, files: Int?)
    case track(Track)
}

extension HAPClient {
    var directoryRootURL: URL { libraryBaseURL.deletingLastPathComponent().appendingPathComponent("services/directory") }

    /// The folder view's entries at `url` (nil = the drive's top level "HAP_Internal").
    public func directory(_ url: String? = nil) async throws -> [DirectoryItem] {
        if let url {
            return try await directoryItems(checkedURL(url, inside: directoryRootURL) ?? directoryRootURL)
        }
        // The very top lists the drive itself ("HAP_Internal"); step into it.
        let top = try await directoryItems(directoryRootURL)
        guard case .folder(_, let drive, _)? = top.first else { return top }
        return try await directory(drive)
    }

    /// Music files in the folder at `path` (e.g. ["Collection", "Albums", "Buika"]),
    /// by file name, as the player knows them. Empty if the player hasn't got that folder.
    public func tracksInFolder(_ path: [String]) async throws -> [String: Track] {
        var items = try await directory()
        for name in path {
            guard let next = items.compactMap({ item -> String? in
                if case .folder(let folderName, let url, _) = item, folderName == name { return url }
                return nil
            }).first else { return [:] }
            items = try await directory(next)
        }
        var result: [String: Track] = [:]
        for case .track(let track) in items {
            if let filename = track.filename { result[filename] = track }
        }
        return result
    }

    private func directoryItems(_ url: URL) async throws -> [DirectoryItem] {
        var entries: [DirectoryItem] = []
        var next: URL? = pagedURL(url)
        var pagesLeft = 100
        while let page = next, pagesLeft > 0 {
            let data = try await getLibraryData(page)
            let decoded = try LibraryPage<Track>.decoder.decode(DirectoryPage.self, from: data)
            for item in decoded.items {
                if item.type == "container", let c = item.itemInfo?.container {
                    entries.append(.folder(name: c.name, url: c.url, files: c.numberOfFiles))
                } else if item.type == "track", let t = item.itemInfo?.track {
                    entries.append(.track(t))
                }
            }
            next = try decoded.paging?.next.flatMap { try checkedURL($0, inside: directoryRootURL) }
            pagesLeft -= 1
        }
        return entries
    }

    private func pagedURL(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "500")]
        return c.url!
    }
}

struct DirectoryPage: Decodable {
    let items: [Item]
    let paging: LibraryPage<Track>.Paging?

    struct Item: Decodable {
        let type: String
        let itemInfo: ItemInfo?
    }

    struct ItemInfo: Decodable {
        let container: Container?
        let track: Track?
    }

    struct Container: Decodable {
        let name: String
        let url: String
        let numberOfFiles: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        paging = try c.decodeIfPresent(LibraryPage<Track>.Paging.self, forKey: .paging)
    }

    private enum CodingKeys: String, CodingKey { case items, paging }
}

extension HAPClient {
    /// Where every track lives on the drive: trackid → path inside the drive, e.g.
    /// 337 → "Collection/Albums/Various Artists/2011 - The TBM Sounds/01 ….wav".
    /// Walks the player's whole folder view (read-only; ~150 folders on our player).
    public func trackLocations() async throws -> [Int: String] {
        var result: [Int: String] = [:]
        func walk(_ url: String?, _ path: [String]) async throws {
            for item in try await directory(url) {
                switch item {
                case .folder(let name, let url, _):
                    if name.lowercased() == "lost+found" { continue }
                    try await walk(url, path + [name])
                case .track(let track):
                    if let filename = track.filename {
                        result[track.trackid] = (path + [filename]).joined(separator: "/")
                    }
                }
            }
        }
        try await walk(nil, [])
        return result
    }
}
