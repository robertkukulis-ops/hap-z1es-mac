import AudioToolbox
import Foundation

/// Test sound files: a stereo tone as WAV (PCM written directly), or FLAC (made from that WAV
/// with macOS's own `afconvert`).
enum TestAudio {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TestAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A WAV whose every sample differs (a rising pattern), so any shift or loss shows up.
    @discardableResult
    static func wav(_ url: URL, seconds: Double, rate: Int = 44100, bits: Int = 24) throws -> URL {
        let frames = Int(seconds * Double(rate)), channels = 2, bytes = bits / 8
        var pcm = Data(capacity: frames * channels * bytes)
        for i in 0..<frames {
            for c in 0..<channels {
                let value = Int32(truncatingIfNeeded: (i * 37 + c * 1001) % (1 << (bits - 2)))
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0.prefix(bytes)) }
            }
        }
        var data = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        u32(36 + pcm.count); data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(rate); u32(rate * channels * bytes); u16(channels * bytes); u16(bits)
        data.append(contentsOf: Array("data".utf8)); u32(pcm.count); data.append(pcm)
        try data.write(to: url)
        return url
    }

    @discardableResult
    static func flac(_ url: URL, seconds: Double, rate: Int = 44100, bits: Int = 24) throws -> URL {
        let wav = url.deletingPathExtension().appendingPathExtension("source.wav")
        try Self.wav(wav, seconds: seconds, rate: rate, bits: bits)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", wav.path, url.path]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: wav)
        return url
    }

    /// Length in sample frames, as macOS reads it.
    static func frames(_ url: URL) throws -> Int64 {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { throw CocoaError(.fileReadCorruptFile) }
        defer { ExtAudioFileDispose(file) }
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        return frames
    }
}
