import Foundation
import Testing
@testable import HAPKit

struct FLACMetadataTests {
    /// The bytes after the metadata blocks: the audio frames.
    private func audioBytes(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var pos = 4
        while true {
            let header = data[pos], length = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            pos += 4 + length
            if header & 0x80 != 0 { return data[pos...] }
        }
    }

    @Test func commentsRoundTrip() throws {
        let url = try TestAudio.flac(try TestAudio.folder().appendingPathComponent("a.flac"), seconds: 1)
        try FLACMetadata.write(comments: [("TITLE", "Café"), ("TRACKNUMBER", "3")], picture: nil, to: url)
        let comments = try FLACMetadata.readComments(url)
        #expect(comments["TITLE"] == "Café")
        #expect(comments["TRACKNUMBER"] == "3")
    }

    @Test func audioBytesUnchanged() throws {
        let url = try TestAudio.flac(try TestAudio.folder().appendingPathComponent("a.flac"), seconds: 1)
        let before = try audioBytes(url)
        try FLACMetadata.write(comments: [("TITLE", "x")], picture: Data(repeating: 7, count: 500), to: url)
        #expect(try audioBytes(url) == before)
    }

    @Test func pictureIsCopied() throws {
        let url = try TestAudio.flac(try TestAudio.folder().appendingPathComponent("a.flac"), seconds: 1)
        let picture = Data((0..<300).map { UInt8($0 % 256) })
        try FLACMetadata.write(comments: [], picture: picture, to: url)
        #expect(try FLACMetadata.pictureBlock(url) == picture)
    }

    @Test func macOSStillReadsTheFile() throws {
        let url = try TestAudio.flac(try TestAudio.folder().appendingPathComponent("a.flac"), seconds: 1)
        let frames = try TestAudio.frames(url)
        try FLACMetadata.write(comments: [("ARTIST", "Someone")], picture: nil, to: url)
        #expect(try TestAudio.frames(url) == frames)
        #expect(frames == 44100)
    }
}
