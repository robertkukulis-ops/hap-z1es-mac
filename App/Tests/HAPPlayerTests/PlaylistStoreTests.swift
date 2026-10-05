import Foundation
import HAPKit
import Testing
@testable import HAPPlayer

@MainActor
struct PlaylistStoreTests {
    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entries(of store: PlaylistStore, _ id: UUID) -> [PlaylistEntry] {
        guard case .handPicked(let list) = store.playlists.first(where: { $0.id == id })?.kind else { return [] }
        return list
    }

    @Test func startsEmptyWithoutAFile() {
        #expect(PlaylistStore(folder: tempFolder()).playlists.isEmpty)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let folder = tempFolder()
        let store = PlaylistStore(folder: folder)
        let id = store.newHandPicked(name: "Sunday")
        _ = store.add([try makeTrack(1), try makeTrack(2)], to: id)
        let reloaded = PlaylistStore(folder: folder)
        #expect(reloaded.playlists == store.playlists)
        #expect(entries(of: reloaded, id).map(\.trackID) == [1, 2])
    }

    @Test func previousVersionKeptAsBak() throws {
        let folder = tempFolder()
        let store = PlaylistStore(folder: folder)
        _ = store.newHandPicked(name: "First")
        _ = store.newHandPicked(name: "Second")
        let bak = try Data(contentsOf: folder.appendingPathComponent("playlists.json.bak"))
        let old = try JSONDecoder().decode([SavedPlaylist].self, from: bak)
        #expect(old.map(\.name) == ["First"])
    }

    @Test func brokenFileStartsEmptyAndIsKeptAside() throws {
        let folder = tempFolder()
        try Data("not json".utf8).write(to: folder.appendingPathComponent("playlists.json"))
        let store = PlaylistStore(folder: folder)
        #expect(store.playlists.isEmpty)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(names.contains { $0.hasPrefix("playlists.json.broken") })
    }

    @Test func newNamesDontClash() {
        let store = PlaylistStore(folder: tempFolder())
        let a = store.newHandPicked(), b = store.newHandPicked()
        #expect(store.playlists.first { $0.id == a }?.name == "New Playlist")
        #expect(store.playlists.first { $0.id == b }?.name == "New Playlist 2")
    }

    @Test func addSkipsSongsAlreadyThere() throws {
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newHandPicked(name: "L")
        #expect(store.add([try makeTrack(1), try makeTrack(2)], to: id) == 2)
        #expect(store.add([try makeTrack(2), try makeTrack(3)], to: id) == 1)
        #expect(entries(of: store, id).map(\.trackID) == [1, 2, 3])
    }

    /// Stored: A, H (hidden, gone from the player), B, C. Shown: A, B, C.
    private func listWithHidden() throws -> (PlaylistStore, UUID, ResolvedPlaylist) {
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newHandPicked(name: "L")
        _ = store.add([try makeTrack(1), try makeTrack(99), try makeTrack(2), try makeTrack(3)], to: id)
        let library = [try makeTrack(1), try makeTrack(2), try makeTrack(3)]
        return (store, id, PlaylistResolver.resolve(entries(of: store, id), in: library))
    }

    @Test func moveSkipsHiddenEntries() throws {
        let (store, id, shown) = try listWithHidden()
        store.moveRows(IndexSet(integer: 2), to: 0, using: shown, in: id)  // move C to the top
        #expect(entries(of: store, id).map(\.trackID) == [3, 1, 99, 2])
        let (store2, id2, shown2) = try listWithHidden()
        store2.moveRows(IndexSet(integer: 0), to: 3, using: shown2, in: id2)  // move A to the end
        #expect(entries(of: store2, id2).map(\.trackID) == [99, 2, 3, 1])
    }

    @Test func removeKeepsHiddenEntries() throws {
        let (store, id, shown) = try listWithHidden()
        store.removeRows(IndexSet(integer: 1), using: shown, from: id)  // remove B
        #expect(entries(of: store, id).map(\.trackID) == [1, 99, 3])
    }

    @Test func duplicateAsHandPickedCopiesSongs() throws {
        let store = PlaylistStore(folder: tempFolder())
        let auto = store.newAutomatic(name: "70s", rules: PlaylistRules(match: .all, rules: [.newest(5)], limit: nil, order: .newest))
        let copy = store.duplicate(auto, asHandPicked: [try makeTrack(4), try makeTrack(5)])
        #expect(entries(of: store, copy).map(\.trackID) == [4, 5])
        #expect(store.playlists.first { $0.id == copy }?.name == "70s copy")
    }

    @Test func deleteRemovesOnlyThatList() {
        let store = PlaylistStore(folder: tempFolder())
        let a = store.newHandPicked(name: "A"), b = store.newHandPicked(name: "B")
        store.delete(a)
        #expect(store.playlists.map(\.id) == [b])
    }

    @Test func renameAndSetRules() {
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newAutomatic(name: "X", rules: PlaylistRules(match: .all, rules: [.neverPlayed], limit: nil, order: .newest))
        store.rename(id, to: "Unplayed")
        let rules = PlaylistRules(match: .any, rules: [.newest(10)], limit: 5, order: .shuffled)
        store.setRules(id, rules)
        #expect(store.playlists.first?.name == "Unplayed")
        #expect(store.playlists.first?.kind == .automatic(rules))
    }

    @Test func applyUpdatesStoresCorrectedIDs() throws {
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newHandPicked(name: "L")
        _ = store.add([try makeTrack(10)], to: id)
        var fixed = entries(of: store, id)
        fixed[0].trackID = 42
        store.applyUpdates(fixed, to: id)
        #expect(entries(of: store, id).map(\.trackID) == [42])
    }

    @Test func addReportsWhatHappened() throws {
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newHandPicked(name: "L")
        _ = store.add([try makeTrack(1)], to: id)
        #expect(store.add([try makeTrack(1), try makeTrack(2), try makeTrack(3)], to: id) == 2)
        #expect(store.lastMessage == "Added 2 songs (1 was already in the list)")
        _ = store.add([try makeTrack(4)], to: id)
        #expect(store.lastMessage == "Added 1 song")
        _ = store.add([try makeTrack(4)], to: id)
        #expect(store.lastMessage == "Already in the list")
    }

    @Test func saveFailureKeepsPlaylistsAndReports() throws {
        let folder = tempFolder()
        let store = PlaylistStore(folder: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let id = store.newHandPicked(name: "Kept")
        #expect(store.playlists.map(\.name) == ["Kept"])
        #expect(store.lastError != nil)
        store.add([try makeTrack(1)], to: id)
        #expect(store.lastMessage == nil)  // no "Added" when it couldn't be saved
    }

    @Test func backupIsMadeOncePerLaunch() throws {
        let folder = tempFolder()
        let first = PlaylistStore(folder: folder)
        _ = first.newHandPicked(name: "One")
        let store = PlaylistStore(folder: folder)  // a new launch
        _ = store.newHandPicked(name: "Two")
        _ = store.newHandPicked(name: "Three")
        let bak = try JSONDecoder().decode([SavedPlaylist].self, from: Data(contentsOf: folder.appendingPathComponent("playlists.json.bak")))
        #expect(bak.map(\.name) == ["One"])  // the file as it was when this launch started
    }

    @Test func olderBrokenFilesAreNotOverwritten() throws {
        let folder = tempFolder()
        try Data("bad 1".utf8).write(to: folder.appendingPathComponent("playlists.json"))
        _ = PlaylistStore(folder: folder)
        try Data("bad 2".utf8).write(to: folder.appendingPathComponent("playlists.json"))
        _ = PlaylistStore(folder: folder)
        let broken = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("playlists.json.broken") }
        #expect(broken.count == 2)
    }

    @Test func renameKeepsNamesUnique() {
        let store = PlaylistStore(folder: tempFolder())
        _ = store.newHandPicked(name: "Party")
        let b = store.newHandPicked(name: "Chill")
        store.rename(b, to: "Party")
        #expect(store.playlists.map(\.name) == ["Party", "Party 2"])
        store.rename(b, to: "Party 2")  // its own name is fine
        #expect(store.playlists.last?.name == "Party 2")
    }

    @Test func addSkipsASongFoundAgainByName() throws {
        // Stored as id 10, which the player renumbered to 42: adding 42 again is a duplicate.
        let store = PlaylistStore(folder: tempFolder())
        let id = store.newHandPicked(name: "L", entries: [PlaylistEntry(trackID: 10, title: "One", artist: "A", album: "B")])
        let renumbered = try makeTrack(42, artist: "A", title: "One", album: "B")
        #expect(store.add([renumbered], to: id, library: [renumbered]) == 0)
    }
}

struct M3UExportTests {
    @Test func m3uListsSongsWithPaths() throws {
        let tracks = [try makeTrack(1, artist: "Beady Belle", title: "Diamond in the Rough", duration: 233),
                      try makeTrack(2, artist: "X", title: "Y", duration: 61)]
        let text = M3UExport.text(name: "Smooth", tracks: tracks, paths: [1: "Collection/Smooth/diamond.flac"])
        #expect(text == """
            #EXTM3U
            #PLAYLIST:Smooth
            #EXTINF:233,Beady Belle - Diamond in the Rough
            Collection/Smooth/diamond.flac
            #EXTINF:61,X - Y
            Y

            """)
    }
}

struct DraggedTracksTests {
    @Test func droppedTextGivesTrackIDs() {
        #expect(DraggedTracks.ids(in: "hap-tracks:12,57") == [12, 57])
        #expect(DraggedTracks.ids(in: "some other text") == nil)
    }
}
