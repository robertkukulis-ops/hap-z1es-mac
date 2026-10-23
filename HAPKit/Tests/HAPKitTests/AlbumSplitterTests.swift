import Foundation
import Testing
@testable import HAPKit

struct AlbumSplitterTests {
    /// A folder with `Album.<ext>` (3 s unless given) and `Album.cue` with tracks at `starts`.
    private func album(ext: String = "wav", seconds: Double = 3, rate: Int = 44100,
                       starts: [String] = ["00:00:00", "00:01:00", "00:02:00"]) throws -> (CueAlbum, URL) {
        let dir = try TestAudio.folder()
        let audio = dir.appendingPathComponent("Album.\(ext)")
        switch ext {
        case "wav": try TestAudio.wav(audio, seconds: seconds, rate: rate)
        case "flac": try TestAudio.flac(audio, seconds: seconds, rate: rate)
        default: try Data("not audio".utf8).write(to: audio)
        }
        var cue = "REM DATE 2001\nREM GENRE \"Jazz\"\nPERFORMER \"The Band\"\nTITLE \"Live\"\nFILE \"Album.\(ext)\" WAVE\n"
        for (i, start) in starts.enumerated() {
            cue += "  TRACK \(String(format: "%02d", i + 1)) AUDIO\n    TITLE \"Song \(i + 1)\"\n    INDEX 01 \(start)\n"
        }
        try Data(cue.utf8).write(to: dir.appendingPathComponent("Album.cue"))
        let out = dir.appendingPathComponent("songs")
        return (try #require(CueAlbum.find(in: dir).first), out)
    }

    @Test func splitsAWavIntoThreeTaggedSongs() throws {
        let (album, out) = try album()
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(songs.map(\.lastPathComponent) == ["01 - Song 1.flac", "02 - Song 2.flac", "03 - Song 3.flac"])
        #expect(try songs.map(TestAudio.frames) == [44100, 44100, 44100])
        let tags = try FLACMetadata.readComments(songs[1])
        #expect(tags["TITLE"] == "Song 2")
        #expect(tags["TRACKNUMBER"] == "2")
        #expect(tags["TRACKTOTAL"] == "3")
        #expect(tags["ALBUM"] == "Live")
        #expect(tags["ALBUMARTIST"] == "The Band")
        #expect(tags["ARTIST"] == "The Band")
        #expect(tags["DATE"] == "2001")
        #expect(tags["GENRE"] == "Jazz")
    }

    @Test func pregapBelongsToTrackOne() throws {
        let (album, out) = try album(starts: ["00:00:30", "00:01:00", "00:02:00"])
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(try TestAudio.frames(songs[0]) == 44100)  // starts at 0, not at 0.4 s
    }

    @Test func songsTogetherEqualTheOriginal() throws {
        let (album, out) = try album()
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(try AlbumSplitter.verify(songs: songs, against: album.audio))
        // One changed sample in the original: the check must notice.
        var data = try Data(contentsOf: album.audio)
        data[data.count - 500] ^= 0x01
        let changed = album.audio.deletingLastPathComponent().appendingPathComponent("changed.wav")
        try data.write(to: changed)
        #expect(try !AlbumSplitter.verify(songs: songs, against: changed))
    }

    @Test func splitsAFlacOriginalLosslessly() throws {
        let (album, out) = try album(ext: "flac")
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(try AlbumSplitter.verify(songs: songs, against: album.audio))
    }

    @Test func splitsA96kHzFileExactly() throws {
        let (album, out) = try album(seconds: 2, rate: 96000, starts: ["00:00:00", "00:01:00"])
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(try songs.map(TestAudio.frames) == [96000, 96000])
        #expect(try AlbumSplitter.verify(songs: songs, against: album.audio))
    }

    @Test func copiesTheEmbeddedPicture() throws {
        let (album, out) = try album(ext: "flac")
        // A well-formed FLAC PICTURE block (front cover, "image/png", 200 bytes of image data).
        var picture = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).bigEndian) { picture.append(contentsOf: $0) } }
        u32(3); u32(9); picture.append(contentsOf: Array("image/png".utf8)); u32(0)
        u32(10); u32(10); u32(24); u32(0); u32(200); picture.append(contentsOf: (0..<200).map { UInt8($0) })
        try FLACMetadata.write(comments: [], picture: picture, to: album.audio)
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(try FLACMetadata.pictureBlock(songs[2]) == picture)
    }

    @Test func cueBeyondTheEndIsRejected() throws {
        let (album, out) = try album(starts: ["00:00:00", "00:09:00"])
        #expect(throws: AlbumSplitter.SplitError.self) { try AlbumSplitter.split(album, into: out) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty)
    }

    @Test func apeIsRejected() throws {
        let (album, out) = try album(ext: "ape")
        #expect(throws: AlbumSplitter.SplitError.self) { try AlbumSplitter.split(album, into: out) }
    }
}

struct SplitterReviewFixTests {
    private func album(seconds: Double = 3) throws -> (CueAlbum, URL) {
        let dir = try TestAudio.folder()
        try TestAudio.wav(dir.appendingPathComponent("Album.wav"), seconds: seconds)
        let cue = "TITLE \"Live\"\nFILE \"Album.wav\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n TRACK 02 AUDIO\n  INDEX 01 00:01:00\n"
        try Data(cue.utf8).write(to: dir.appendingPathComponent("Album.cue"))
        return (try #require(CueAlbum.find(in: dir).first), dir.appendingPathComponent("songs"))
    }

    @Test func cancellingStopsSplitting() throws {
        let (album, out) = try album()
        #expect(throws: CancellationError.self) { try AlbumSplitter.split(album, into: out, isCancelled: { true }) }
    }

    @Test func cancellingStopsTheCheck() throws {
        let (album, out) = try album()
        let songs = try AlbumSplitter.split(album, into: out)
        #expect(throws: CancellationError.self) { try AlbumSplitter.verify(songs: songs, against: album.audio, isCancelled: { true }) }
    }

    @Test func cutOffOriginalWhoseSongsDontFitIsRejected() throws {
        // macOS measures a cut-off file by the sound it really holds: here 0.75 s of the 3 s,
        // so song 2 (at 1 s) starts after the real end and nothing may be written.
        let (album, out) = try album()
        let data = try Data(contentsOf: album.audio)
        try data.prefix(data.count / 4).write(to: album.audio)
        #expect(throws: AlbumSplitter.SplitError.self) { try AlbumSplitter.split(album, into: out) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty)
    }

    @Test func metadataIsReadWithoutTheAudio() throws {
        let url = try TestAudio.flac(try TestAudio.folder().appendingPathComponent("a.flac"), seconds: 2)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(try FLACMetadata.headerLength(of: url) < size / 10)  // only the blocks at the start
    }
}

struct CueAlbumReviewFixTests {
    @Test func oneAudioFileGoesToOneAlbum() throws {
        let dir = try TestAudio.folder()
        let cue = "FILE \"Album.flac\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"
        try Data(cue.utf8).write(to: dir.appendingPathComponent("Album (UTF-8).cue"))
        try Data(cue.utf8).write(to: dir.appendingPathComponent("Album.cue"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Album.flac"))
        let albums = CueAlbum.find(in: dir)
        #expect(albums.map(\.cue.lastPathComponent) == ["Album.cue"])  // the one named like the audio
    }
}

extension CueUploadTests {
    @Test func songsClashingWithOtherPlannedFilesAreSkipped() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let folder = drive.url("Sample Music")
        let songs = try FileManager.default.temporaryDirectory.appendingPathComponent("Clash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: songs, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: songs.appendingPathComponent("01 - One.flac"))
        let taken: Set<String> = [folder.appendingPathComponent("01 - one.flac").path.lowercased()]
        let plan = drive.drive.plan(songs: [songs.appendingPathComponent("01 - One.flac")], into: folder, taken: taken)
        #expect(plan.items.isEmpty)
        #expect(plan.skipped.first?.reason == "another file in this copy has the same name")
    }
}
