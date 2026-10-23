import Foundation
import Testing
@testable import HAPKit

struct CueSheetTests {
    static let sample = """
        REM GENRE "Jazz"
        REM DATE 1998
        PERFORMER "Buika"
        TITLE "Mi Niña Lola"
        FILE "Mi Niña Lola.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Sueño con ella"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Jodida pero contenta"
            PERFORMER "Buika feat. Someone"
            INDEX 00 03:23:10
            INDEX 01 03:25:40
        """

    @Test func parsesAlbumAndTracks() {
        let cue = CueSheet(text: Self.sample)
        #expect(cue.title == "Mi Niña Lola")
        #expect(cue.performer == "Buika")
        #expect(cue.date == "1998")
        #expect(cue.genre == "Jazz")
        #expect(cue.files == ["Mi Niña Lola.flac"])
        #expect(cue.tracks.map(\.number) == [1, 2])
        #expect(cue.tracks[0].title == "Sueño con ella")
        #expect(cue.tracks[0].performer == nil)
        #expect(cue.tracks[1].performer == "Buika feat. Someone")
        #expect(cue.tracks[1].start == (3 * 60 + 25) * 75 + 40)  // 15415 frames
    }

    @Test func index00IsIgnored() {
        #expect(CueSheet(text: Self.sample).tracks[1].start == 15415)
    }

    @Test func unquotedValuesAndCRLF() {
        let text = "TITLE Album\r\nFILE album.wav WAVE\r\n  TRACK 1 AUDIO\r\n    TITLE One\r\n    INDEX 01 00:01:00\r\n"
        let cue = CueSheet(text: text)
        #expect(cue.title == "Album")
        #expect(cue.files == ["album.wav"])
        #expect(cue.tracks.first?.title == "One")
        #expect(cue.tracks.first?.start == 75)
    }

    @Test func readsWindows1252() {
        var data = Data("TITLE \"Beyonc".utf8)
        data.append(0xE9)  // é in Windows-1252
        data.append(contentsOf: Array("\"\nFILE \"a.wav\" WAVE\n".utf8))
        #expect(CueSheet(data: data).title == "Beyoncé")
    }

    @Test func readsUTF8WithBOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("TITLE \"Café\"\n".utf8))
        #expect(CueSheet(data: data).title == "Café")
    }

    @Test func severalFilesAreListed() {
        let text = """
            FILE "01.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "02.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            FILE "03.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
            """
        #expect(CueSheet(text: text).files.count == 3)
    }

    @Test func framesToSamplesAtOtherRates() {
        #expect(CueSheet.samples(fromFrames: 75, sampleRate: 44100) == 44100)
        #expect(CueSheet.samples(fromFrames: 75, sampleRate: 48000) == 48000)
        #expect(CueSheet.samples(fromFrames: 75, sampleRate: 96000) == 96000)
        #expect(CueSheet.samples(fromFrames: 1, sampleRate: 44100) == 588)
    }
}
