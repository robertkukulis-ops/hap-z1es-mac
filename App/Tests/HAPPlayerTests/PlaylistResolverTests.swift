import Foundation
import HAPKit
import Testing
@testable import HAPPlayer

struct PlaylistResolverTests {
    private func entry(_ id: Int, _ title: String, _ artist: String = "A", _ album: String = "B") -> PlaylistEntry {
        PlaylistEntry(trackID: id, title: title, artist: artist, album: album)
    }

    @Test func matchesByTrackID() throws {
        let lib = [try makeTrack(10, artist: "A", title: "One", album: "B"), try makeTrack(11, title: "Two")]
        let r = PlaylistResolver.resolve([entry(10, "One")], in: lib)
        #expect(r.tracks.map(\.trackid) == [10])
        #expect(r.updatedEntries == nil)
        #expect(r.hiddenCount == 0)
    }

    @Test func fallsBackToTitleArtistAlbum() throws {
        let lib = [try makeTrack(42, artist: "A", title: "One", album: "B")]
        let r = PlaylistResolver.resolve([entry(10, "One")], in: lib)
        #expect(r.tracks.map(\.trackid) == [42])
        #expect(r.updatedEntries?.first?.trackID == 42)
    }

    @Test func fallbackIsSpellingInsensitive() throws {
        let lib = [try makeTrack(42, artist: "Deep Jahi", title: "Hide", album: "Reggae Gold 2K17")]
        let r = PlaylistResolver.resolve([entry(10, "Hide", "Deepjahi", "Reggae Gold 2K17")], in: lib)
        #expect(r.tracks.map(\.trackid) == [42])
    }

    @Test func ambiguousFallbackStaysHidden() throws {
        let lib = [try makeTrack(42, artist: "A", title: "One", album: "B"), try makeTrack(43, artist: "A", title: "One", album: "B")]
        let r = PlaylistResolver.resolve([entry(10, "One")], in: lib)
        #expect(r.tracks.isEmpty)
        #expect(r.hiddenCount == 1)
        #expect(r.updatedEntries == nil)
    }

    @Test func missingSongIsHiddenButKept() throws {
        let lib = [try makeTrack(11, title: "Two")]
        let r = PlaylistResolver.resolve([entry(10, "One")], in: lib)
        #expect(r.tracks.isEmpty)
        #expect(r.hiddenCount == 1)
        #expect(r.updatedEntries == nil)
    }

    @Test func emptyLibraryChangesNothing() {
        // App start before the library has loaded: nothing is matched, nothing is rewritten.
        let r = PlaylistResolver.resolve([entry(10, "One"), entry(11, "Two")], in: [])
        #expect(r.tracks.isEmpty)
        #expect(r.updatedEntries == nil)
    }

    @Test func entryIndexesPointAtStoredPositions() throws {
        let lib = [try makeTrack(10, artist: "A", title: "One", album: "B"), try makeTrack(12, artist: "A", title: "Three", album: "B")]
        let r = PlaylistResolver.resolve([entry(10, "One"), entry(11, "Gone"), entry(12, "Three")], in: lib)
        #expect(r.tracks.map(\.trackid) == [10, 12])
        #expect(r.entryIndexes == [0, 2])
    }

    @Test func aSongIsShownOnlyOnce() throws {
        // Old entry (id 10, found again by name) and a new entry for the same song (id 42).
        let lib = [try makeTrack(42, artist: "A", title: "One", album: "B")]
        let r = PlaylistResolver.resolve([entry(10, "One"), entry(42, "One")], in: lib)
        #expect(r.tracks.map(\.trackid) == [42])
    }
}
