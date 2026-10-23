import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HAPKit

struct FolderPictureTests {
    private func folder(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderPictureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: url.appendingPathComponent(name)) }
        return url
    }

    /// A real picture of the given size and kind.
    private func picture(_ url: URL, width: Int, height: Int, type: UTType = .jpeg) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func u32(_ data: Data, _ at: Int) -> Int {
        data[data.startIndex + at..<data.startIndex + at + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    @Test func prefersCoverNames() throws {
        let dir = try folder(["back.jpg", "Folder.JPG", "booklet1.jpg", "01 Song.flac"])
        #expect(FolderPicture.find(in: dir)?.lastPathComponent == "Folder.JPG")
    }

    @Test func coverBeatsFolder() throws {
        let dir = try folder(["folder.jpg", "cover.png"])
        #expect(FolderPicture.find(in: dir)?.lastPathComponent == "cover.png")
    }

    @Test func nameContainingFrontButNotBack() throws {
        let dir = try folder(["Album - Back Cover.jpg", "Album - Front.jpg", "cd.jpg"])
        #expect(FolderPicture.find(in: dir)?.lastPathComponent == "Album - Front.jpg")
    }

    @Test func theOnlyPictureIsUsed() throws {
        let dir = try folder(["Artist - Album.jpeg", "01.flac"])
        #expect(FolderPicture.find(in: dir)?.lastPathComponent == "Artist - Album.jpeg")
    }

    @Test func severalUnnamedPicturesAreNotGuessed() throws {
        #expect(FolderPicture.find(in: try folder(["scan1.jpg", "scan2.jpg"])) == nil)
        #expect(FolderPicture.find(in: try folder(["01.flac", "notes.txt"])) == nil)
    }

    @Test func pictureBlockOfASmallJPEG() throws {
        let url = try picture(try folder([]).appendingPathComponent("cover.jpg"), width: 300, height: 200)
        let block = try #require(FolderPicture.flacPictureBlock(url))
        #expect(u32(block, 0) == 3)  // front cover
        #expect(u32(block, 4) == 10)
        #expect(String(decoding: block[block.startIndex + 8..<block.startIndex + 18], as: UTF8.self) == "image/jpeg")
        #expect(u32(block, 18) == 0)  // no description
        #expect(u32(block, 22) == 300)
        #expect(u32(block, 26) == 200)
        let original = try Data(contentsOf: url)
        #expect(u32(block, 38) == original.count)
        #expect(block.suffix(original.count) == original)  // the picture itself, unchanged
    }

    @Test func pngKeepsItsType() throws {
        let url = try picture(try folder([]).appendingPathComponent("cover.png"), width: 50, height: 50, type: .png)
        let block = try #require(FolderPicture.flacPictureBlock(url))
        #expect(String(decoding: block[block.startIndex + 8..<block.startIndex + 17], as: UTF8.self) == "image/png")
    }

    @Test func bigPicturesAreMadeSmaller() throws {
        let url = try picture(try folder([]).appendingPathComponent("cover.png"), width: 3000, height: 1500, type: .png)
        let block = try #require(FolderPicture.flacPictureBlock(url))
        #expect(String(decoding: block[block.startIndex + 8..<block.startIndex + 18], as: UTF8.self) == "image/jpeg")
        #expect(u32(block, 22) == 1000)
        #expect(u32(block, 26) == 500)
    }

    @Test func notAPicture() throws {
        let dir = try folder(["cover.jpg"])  // "x", not a JPEG
        #expect(FolderPicture.flacPictureBlock(dir.appendingPathComponent("cover.jpg")) == nil)
    }

    @Test func splitSongsGetTheFolderPicture() throws {
        let dir = try TestAudio.folder()
        try TestAudio.flac(dir.appendingPathComponent("Album.flac"), seconds: 3)
        try Data("PERFORMER \"A\"\nTITLE \"B\"\nFILE \"Album.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:01:00\n".utf8)
            .write(to: dir.appendingPathComponent("Album.cue"))
        let cover = try picture(dir.appendingPathComponent("cover.jpg"), width: 120, height: 120)
        let album = try #require(CueAlbum.find(in: dir).first)
        let songs = try AlbumSplitter.split(album, into: dir.appendingPathComponent("out"))
        #expect(songs.count == 2)
        for song in songs {
            let block = try #require(try FLACMetadata.pictureBlock(song))
            #expect(block == FolderPicture.flacPictureBlock(cover))
        }
    }

    @Test func picturesForAPlan() throws {
        let mac = try folder(["cover.jpg", "01.flac"])
        let other = try folder(["02.flac"])
        let player = try folder([])
        var plan = UploadPlan()
        plan.items = [UploadItem(source: mac.appendingPathComponent("01.flac"),
                                 destination: player.appendingPathComponent("Album/01.flac"), size: 1),
                      UploadItem(source: other.appendingPathComponent("02.flac"),
                                 destination: player.appendingPathComponent("Other/02.flac"), size: 1)]
        plan.skipped = [UploadSkip(source: other.appendingPathComponent("02.flac"), reason: "different file"),
                        UploadSkip(source: mac.appendingPathComponent("03.flac"), reason: "already on the player",
                                   destination: player.appendingPathComponent("Old/03.flac"))]
        let pictures = plan.folderPictures()
        #expect(pictures.count == 1)  // the folder without a picture gives nothing
        #expect(pictures.first?.picture.lastPathComponent == "cover.jpg")
        // Only the songs from the folder with the picture (copied, and already on the player).
        #expect(pictures.first?.songs == [player.appendingPathComponent("Album/01.flac"), player.appendingPathComponent("Old/03.flac")])
    }
}
