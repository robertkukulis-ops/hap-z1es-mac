import Foundation
import Testing
@testable import HAPKit

struct CueAlbumTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CueAlbumTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(name)) }
        return url
    }

    private func cue(file: String, titles: [String?]) -> String {
        var text = "PERFORMER \"Artist\"\nTITLE \"Album\"\nFILE \"\(file)\" WAVE\n"
        for (i, title) in titles.enumerated() {
            text += "  TRACK \(String(format: "%02d", i + 1)) AUDIO\n"
            if let title { text += "    TITLE \"\(title)\"\n" }
            text += "    INDEX 01 0\(i):00:00\n"
        }
        return text
    }

    @Test func findsAFlacAlbum() throws {
        let dir = try folder(["Album.cue": cue(file: "Album.flac", titles: ["One", "Two"]), "Album.flac": "x", "cover.jpg": "x"])
        let albums = CueAlbum.find(in: dir)
        #expect(albums.count == 1)
        #expect(albums.first?.audio.lastPathComponent == "Album.flac")
        #expect(albums.first?.supported == true)
        #expect(albums.first?.sheet.tracks.count == 2)
    }

    @Test func findsTheAudioFileWithAnotherExtension() throws {
        let dir = try folder(["Album.cue": cue(file: "Album.wav", titles: ["One"]), "album.FLAC": "x"])
        #expect(CueAlbum.find(in: dir).first?.audio.lastPathComponent == "album.FLAC")
    }

    @Test func apeIsFoundButUnsupported() throws {
        let dir = try folder(["Album.cue": cue(file: "Album.ape", titles: ["One"]), "Album.ape": "x"])
        let album = try #require(CueAlbum.find(in: dir).first)
        #expect(album.supported == false)
    }

    @Test func alreadySplitSheetIsIgnored() throws {
        let text = "FILE \"01.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\nFILE \"02.flac\" WAVE\n TRACK 02 AUDIO\n INDEX 01 00:00:00\nFILE \"03.flac\" WAVE\n TRACK 03 AUDIO\n INDEX 01 00:00:00\n"
        let dir = try folder(["Album.cue": text, "01.flac": "x", "02.flac": "x", "03.flac": "x"])
        #expect(CueAlbum.find(in: dir).isEmpty)
    }

    @Test func songNamesAreSafeAndNumbered() throws {
        let dir = try folder(["Album.cue": cue(file: "Album.flac", titles: ["Intro", "A/B", nil]), "Album.flac": "x"])
        #expect(CueAlbum.find(in: dir).first?.songNames == ["01 - Intro.flac", "02 - A_B.flac", "03 - Track 3.flac"])
    }

    @Test func aCueWithoutItsAudioFileIsIgnored() throws {
        let dir = try folder(["Album.cue": cue(file: "Album.flac", titles: ["One"])])
        #expect(CueAlbum.find(in: dir).isEmpty)
    }
}
