import CoreGraphics
import Foundation
import HAPKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HAPPlayer

@MainActor
struct CoverArtStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoverArtStoreTests-\(UUID().uuidString)")

    /// A real picture on the Mac, like an album folder's cover.jpg.
    private func picture() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("mac-cover-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func album(_ id: Int = 1, _ name: String = "Album", artist: String = "Artist") throws -> Album {
        let json: [String: Any] = ["albumid": id, "name": name, "album_artist": ["name": artist]]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Album.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var store: CoverArtStore { CoverArtStore(folder: folder.appendingPathComponent("covers")) }

    @Test func folderPictureBecomesTheCoverOnceTheSongsAreIn() async throws {
        let covers = store
        await covers.addFolderPictures([(try picture(), ["Music/Artist/Album/01 Song.flac"])])
        let album = try album()
        let track = try makeTrack(5, album: "Album", albumArtist: "Artist")
        // Not in the library yet: kept for later.
        covers.applyFolderCovers(albums: [], tracks: [], trackPaths: [:])
        #expect(covers.albumImage(album) == nil)
        // The player added the songs (folder names may differ in capitals).
        covers.applyFolderCovers(albums: [album], tracks: [track], trackPaths: [5: "music/artist/ALBUM/01 Song.flac"])
        #expect(covers.albumImage(album) != nil)
        #expect(!covers.entries.keys.contains { $0.hasPrefix(CoverArtStore.folderPrefix) })
        #expect(covers.entries[CoverArtStore.albumKey(album)]?.source?.hasPrefix("folder:") == true)
    }

    @Test func otherAlbumsInASharedFolderDontGetIt() async throws {
        let covers = store
        await covers.addFolderPictures([(try picture(), ["Singles/New.flac"])])
        let mine = try album(1, "Album"), other = try album(2, "Other")
        let otherTrack = try makeTrack(6, album: "Other", albumArtist: "Artist")
        covers.applyFolderCovers(albums: [mine, other], tracks: [otherTrack], trackPaths: [6: "Singles/Old.flac"])
        #expect(covers.albumImage(other) == nil)
        covers.applyFolderCovers(albums: [mine, other], tracks: [try makeTrack(5, album: "Album", albumArtist: "Artist"), otherTrack],
                                 trackPaths: [5: "Singles/New.flac", 6: "Singles/Old.flac"])
        #expect(covers.albumImage(mine) != nil)
        #expect(covers.albumImage(other) == nil)
    }

    @Test func aRejectedFolderCoverStaysRejected() async throws {
        let covers = store
        let mac = try picture()
        let album = try album()
        let track = try makeTrack(5, album: "Album", albumArtist: "Artist")
        await covers.addFolderPictures([(mac, ["A/01.flac"])])
        covers.applyFolderCovers(albums: [album], tracks: [track], trackPaths: [5: "A/01.flac"])
        covers.remove(album: album)
        await covers.addFolderPictures([(mac, ["A/01.flac"])])  // the same folder dropped again
        covers.applyFolderCovers(albums: [album], tracks: [track], trackPaths: [5: "A/01.flac"])
        #expect(covers.albumImage(album) == nil)
    }

    @Test func songsInAnotherFolderDontGetIt() async throws {
        let covers = store
        await covers.addFolderPictures([(try picture(), ["Music/Album/01.flac"])])
        let album = try album()
        covers.applyFolderCovers(albums: [album], tracks: [try makeTrack(5, album: "Album", albumArtist: "Artist")],
                                 trackPaths: [5: "Music/Other/01.flac"])
        #expect(covers.albumImage(album) == nil)
        #expect(covers.entries.keys.contains { $0.hasPrefix(CoverArtStore.folderPrefix) })
    }

    @Test func keptAfterRestart() async throws {
        await store.addFolderPictures([(try picture(), ["Music/Album/01.flac"])])
        let album = try album()
        let later = store  // the app started again
        later.applyFolderCovers(albums: [album], tracks: [try makeTrack(5, album: "Album", albumArtist: "Artist")],
                                trackPaths: [5: "Music/Album/01.flac"])
        #expect(later.albumImage(album) != nil)
        #expect(store.albumImage(album) != nil)
    }

    @Test func theMacPictureIsNotMovedOrChanged() async throws {
        let original = try picture()
        let before = try Data(contentsOf: original)
        await store.addFolderPictures([(original, ["Music/Album/01.flac"])])
        #expect(try Data(contentsOf: original) == before)
    }
}
