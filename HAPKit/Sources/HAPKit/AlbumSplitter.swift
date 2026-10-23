import AudioToolbox
import Foundation

/// Splits a `.cue` album (one big FLAC or WAV) into one FLAC file per song, losslessly, with
/// macOS's own audio tools. The sound is moved through as whole numbers (32-bit containers), so
/// nothing is rounded: a 16- or 24-bit original comes out sample-for-sample identical.
public enum AlbumSplitter {
    public enum SplitError: Error, LocalizedError, Equatable {
        case unsupported(String)
        case beyondEnd(Int)
        case unreadable(String)
        case writeFailed(String)
        case truncated(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let name): "“\(name)” can't be split: macOS can't read this kind of file (only FLAC and WAV)."
            case .beyondEnd(let track): "The .cue sheet doesn't fit the file: song \(track) starts after the end."
            case .unreadable(let name): "“\(name)” couldn't be read."
            case .writeFailed(let name): "“\(name)” couldn't be written."
            case .truncated(let name): "“\(name)” ends earlier than it says: the file may be damaged or incomplete."
            }
        }
    }

    /// Writes the songs into `folder` (created if needed) and returns them in order.
    /// `progress(songsDone, songCount)`.
    @discardableResult
    public static func split(_ album: CueAlbum, into folder: URL, progress: (Int, Int) -> Void = { _, _ in },
                             isCancelled: () -> Bool = { false }) throws -> [URL] {
        guard album.supported else { throw SplitError.unsupported(album.audio.lastPathComponent) }
        let source = try Reader(album.audio)
        let ranges = try songRanges(album.sheet, rate: source.sampleRate, total: source.frames)
        // The album file's own cover (only the blocks at its start are read, not the whole
        // album), else the folder's picture (cover.jpg, …), so the player shows a cover too.
        let embedded = album.audio.pathExtension.lowercased() == "flac" ? (try? FLACMetadata.pictureBlock(album.audio)) ?? nil : nil
        let picture = embedded ?? FolderPicture.find(in: album.cue.deletingLastPathComponent()).flatMap(FolderPicture.flacPictureBlock)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var songs: [URL] = []
        let names = album.songNames
        for (i, range) in ranges.enumerated() {
            let url = folder.appendingPathComponent(names[i])
            try source.copy(range, toFLACAt: url, isCancelled: isCancelled)
            try FLACMetadata.write(comments: tags(album.sheet, track: i), picture: picture, to: url)
            songs.append(url)
            progress(i + 1, ranges.count)
        }
        return songs
    }

    /// Whether the songs, one after another, have exactly the original's sound.
    public static func verify(songs: [URL], against original: URL, isCancelled: () -> Bool = { false }) throws -> Bool {
        let whole = try Reader(original)
        var position: Int64 = 0
        for song in songs {
            let part = try Reader(song)
            guard part.channels == whole.channels, part.sampleRate == whole.sampleRate else { return false }
            var remaining = part.frames
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let count = Int(min(remaining, 65536))
                let a = try part.read(count), b = try whole.read(count, at: position)
                guard a == b else { return false }
                position += Int64(count)
                remaining -= Int64(count)
            }
        }
        return position == whole.frames
    }

    // MARK: - Songs

    /// Each song from its `INDEX 01` to the next one; anything before song 1 belongs to song 1.
    static func songRanges(_ sheet: CueSheet, rate: Int, total: Int64) throws -> [Range<Int64>] {
        var starts = sheet.tracks.map { Int64(CueSheet.samples(fromFrames: $0.start, sampleRate: rate)) }
        guard !starts.isEmpty else { return [] }
        starts[0] = 0
        for (i, start) in starts.enumerated() where start >= total || (i > 0 && start <= starts[i - 1]) {
            throw SplitError.beyondEnd(sheet.tracks[i].number)
        }
        return starts.indices.map { i in starts[i]..<(i + 1 < starts.count ? starts[i + 1] : total) }
    }

    static func tags(_ sheet: CueSheet, track i: Int) -> [(String, String)] {
        let track = sheet.tracks[i]
        let pairs: [(String, String?)] = [
            ("TITLE", track.title ?? "Track \(track.number)"),
            ("ARTIST", track.performer ?? sheet.performer),
            ("ALBUM", sheet.title),
            ("ALBUMARTIST", sheet.performer),
            ("DATE", sheet.date),
            ("GENRE", sheet.genre),
            ("TRACKNUMBER", String(track.number)),
            ("TRACKTOTAL", String(sheet.tracks.count)),
        ]
        return pairs.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }
    }

    // MARK: - Reading and writing sound

    /// Reads a file's sound as interleaved 32-bit whole numbers.
    final class Reader {
        let file: ExtAudioFileRef
        let sampleRate: Int
        let channels: Int
        /// The original's bit depth (16, 20, 24 or 32), for writing the same.
        let bits: Int
        let frames: Int64
        private var position: Int64 = 0

        init(_ url: URL) throws {
            var opened: ExtAudioFileRef?
            guard ExtAudioFileOpenURL(url as CFURL, &opened) == noErr, let file = opened else {
                throw SplitError.unreadable(url.lastPathComponent)
            }
            self.file = file
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
            sampleRate = Int(format.mSampleRate)
            channels = Int(format.mChannelsPerFrame)
            if format.mFormatID == kAudioFormatFLAC {
                bits = [1: 16, 2: 20, 3: 24, 4: 32][Int(format.mFormatFlags)] ?? 24
            } else {
                bits = Int(format.mBitsPerChannel)
            }
            var length: Int64 = 0
            size = UInt32(MemoryLayout<Int64>.size)
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &length)
            frames = length
            var client = Self.clientFormat(rate: sampleRate, channels: channels)
            guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr,
                  [16, 20, 24, 32].contains(bits), channels > 0 else {
                // (deinit closes the file: every property is set by now)
                throw SplitError.unsupported(url.lastPathComponent)
            }
        }

        deinit { ExtAudioFileDispose(file) }

        static func clientFormat(rate: Int, channels: Int) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        }

        /// Up to `count` frames from `at` (or from where the last read ended).
        func read(_ count: Int, at start: Int64? = nil) throws -> [Int32] {
            if let start, start != position {
                guard ExtAudioFileSeek(file, start) == noErr else { throw SplitError.unreadable("seek") }
                position = start
            }
            var samples = [Int32](repeating: 0, count: count * channels)
            var got = UInt32(count)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileRead(file, &got, &list)
            }
            guard status == noErr else { throw SplitError.unreadable("read") }
            position += Int64(got)
            return Array(samples.prefix(Int(got) * channels))
        }

        /// Writes `range` of this file as a FLAC file with the same rate, channels and bit depth.
        func copy(_ range: Range<Int64>, toFLACAt url: URL, isCancelled: () -> Bool = { false }) throws {
            var flac = AudioStreamBasicDescription()
            flac.mSampleRate = Double(sampleRate)
            flac.mFormatID = kAudioFormatFLAC
            flac.mChannelsPerFrame = UInt32(channels)
            flac.mFormatFlags = [16: 1, 20: 2, 24: 3, 32: 4][bits] ?? 3
            flac.mFramesPerPacket = 4096
            var created: ExtAudioFileRef?
            guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil,
                                            AudioFileFlags.eraseFile.rawValue, &created) == noErr, let out = created else {
                throw SplitError.writeFailed(url.lastPathComponent)
            }
            var closed = false
            defer { if !closed { ExtAudioFileDispose(out) } }
            var client = Self.clientFormat(rate: sampleRate, channels: channels)
            ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat,
                                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
            var next = range.lowerBound
            while next < range.upperBound {
                if isCancelled() { throw CancellationError() }
                let count = Int(min(range.upperBound - next, 65536))
                var samples = try read(count, at: next)
                let frames = samples.count / channels
                // Fewer frames than the file promised: never write a short song silently.
                guard frames > 0 else { throw SplitError.truncated(url.deletingLastPathComponent().lastPathComponent) }
                let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                    return ExtAudioFileWrite(out, UInt32(frames), &list)
                }
                guard status == noErr else { throw SplitError.writeFailed(url.lastPathComponent) }
                next += Int64(frames)
            }
            // Closing writes the last part of the file: check that it worked.
            closed = true
            guard ExtAudioFileDispose(out) == noErr else { throw SplitError.writeFailed(url.lastPathComponent) }
        }
    }
}
