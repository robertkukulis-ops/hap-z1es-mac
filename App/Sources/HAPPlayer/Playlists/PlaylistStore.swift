import Foundation
import HAPKit
import Observation

/// The user's playlists and the file they live in (`~/Library/Application Support/HAP/
/// playlists.json`). Every change is saved at once; the previous file is kept as `.bak`.
@MainActor @Observable
final class PlaylistStore {
    private(set) var playlists: [SavedPlaylist] = []
    /// Set when the file couldn't be written; the playlists stay in memory.
    private(set) var lastError: String?
    /// A short note after adding songs ("Added 3 songs"), shown briefly by the window.
    var lastMessage: String?

    @ObservationIgnored private let folder: URL
    /// The backup is made once per app start (the file as it was then), so a mistake can be
    /// undone from it even after more changes.
    @ObservationIgnored private var backedUp = false
    private var fileURL: URL { folder.appendingPathComponent("playlists.json") }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HAP")
    }

    init(folder: URL = PlaylistStore.defaultFolder) {
        self.folder = folder
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            playlists = try JSONDecoder().decode([SavedPlaylist].self, from: data)
        } catch {
            // Never lose a file we can't read: keep it aside (never over an older one) and start empty.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            var aside = folder.appendingPathComponent("playlists.json.broken-\(stamp)")
            var number = 2
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = folder.appendingPathComponent("playlists.json.broken-\(stamp)-\(number)")
                number += 1
            }
            backedUp = true  // never copy the unreadable file over a good backup
            if (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil {
                lastError = "The playlists file couldn't be read; it was kept as \(aside.lastPathComponent)."
            } else {
                lastError = "The playlists file couldn't be read and couldn't be moved aside."
            }
        }
    }

    // MARK: - Lists

    @discardableResult
    func newHandPicked(name: String? = nil, entries: [PlaylistEntry] = []) -> SavedPlaylist.ID {
        insert(SavedPlaylist(id: UUID(), name: uniqueName(name ?? "New Playlist"), kind: .handPicked(entries)))
    }

    @discardableResult
    func newAutomatic(name: String, rules: PlaylistRules) -> SavedPlaylist.ID {
        insert(SavedPlaylist(id: UUID(), name: uniqueName(name), kind: .automatic(rules)))
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let unique = uniqueName(trimmed, excluding: id)
        change(id) { $0.name = unique }
    }

    /// A copy; with `songs`, an automatic list becomes a hand-picked one with those songs.
    @discardableResult
    func duplicate(_ id: UUID, asHandPicked songs: [Track]? = nil) -> UUID {
        guard let original = playlists.first(where: { $0.id == id }) else { return id }
        let kind = songs.map { PlaylistKind.handPicked($0.map(PlaylistEntry.init(track:))) } ?? original.kind
        return insert(SavedPlaylist(id: UUID(), name: uniqueName("\(original.name) copy"), kind: kind))
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func setRules(_ id: UUID, _ rules: PlaylistRules) {
        change(id) { $0.kind = .automatic(rules) }
    }

    func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let names = Set(playlists.filter { $0.id != id }.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: - Songs in a hand-picked list

    /// Adds songs not already in the list, in the given order; returns how many were new.
    /// With the library, songs already there under an old track id count as present too.
    @discardableResult
    func add(_ tracks: [Track], to id: UUID, library: [Track] = []) -> Int {
        var added = 0
        changeEntries(id) { entries in
            var present = Set(entries.map(\.trackID))
            if !library.isEmpty { present.formUnion(PlaylistResolver.resolve(entries, in: library).tracks.map(\.trackid)) }
            for track in tracks where present.insert(track.trackid).inserted {
                entries.append(PlaylistEntry(track: track))
                added += 1
            }
        }
        let skipped = tracks.count - added
        guard lastError == nil else {
            lastMessage = nil  // the error says what happened instead
            return added
        }
        lastMessage = switch (added, skipped) {
        case (0, 1): "Already in the list"
        case (0, _): "All \(skipped) songs are already in the list"
        case (_, 0): "Added \(countText(added, "song"))"
        default: "Added \(countText(added, "song")) (\(skipped) \(skipped == 1 ? "was" : "were") already in the list)"
        }
        return added
    }

    /// Moves shown rows (hidden songs keep their place among the stored entries).
    func moveRows(_ rows: IndexSet, to row: Int, using shown: ResolvedPlaylist, in id: UUID) {
        changeEntries(id) { entries in
            let sources = rows.compactMap { shown.entryIndexes.indices.contains($0) ? shown.entryIndexes[$0] : nil }
            let destination = row < shown.entryIndexes.count ? shown.entryIndexes[row] : entries.count
            let moving = sources.sorted().map { entries[$0] }
            let before = sources.filter { $0 < destination }.count
            for index in sources.sorted(by: >) { entries.remove(at: index) }
            entries.insert(contentsOf: moving, at: destination - before)
        }
    }

    /// Removes shown rows from the list (never from the player).
    func removeRows(_ rows: IndexSet, using shown: ResolvedPlaylist, from id: UUID) {
        changeEntries(id) { entries in
            let stored = rows.compactMap { shown.entryIndexes.indices.contains($0) ? shown.entryIndexes[$0] : nil }
            for index in stored.sorted(by: >) { entries.remove(at: index) }
        }
    }

    /// Saves track ids the resolver corrected (a song found again by its name).
    func applyUpdates(_ entries: [PlaylistEntry], to id: UUID) {
        changeEntries(id) { $0 = entries }
    }

    /// A problem found elsewhere (e.g. exporting), shown like a saving problem.
    func report(_ problem: String) { lastError = problem }

    func dismissError() { lastError = nil }

    // MARK: - Plumbing

    private func insert(_ playlist: SavedPlaylist) -> UUID {
        playlists.append(playlist)
        save()
        return playlist.id
    }

    private func change(_ id: UUID, _ edit: (inout SavedPlaylist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        edit(&playlists[index])
        save()
    }

    private func changeEntries(_ id: UUID, _ edit: (inout [PlaylistEntry]) -> Void) {
        change(id) { playlist in
            guard case .handPicked(var entries) = playlist.kind else { return }
            edit(&entries)
            playlist.kind = .handPicked(entries)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(playlists)
            if !backedUp, FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = folder.appendingPathComponent("playlists.json.bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: fileURL, to: backup)
                backedUp = true
            }
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Playlists couldn't be saved: \(error.localizedDescription)"
        }
    }
}
