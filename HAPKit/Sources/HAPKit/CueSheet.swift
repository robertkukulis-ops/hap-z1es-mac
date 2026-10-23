import Foundation

/// A `.cue` sheet: the list of songs inside one big album file, and where each starts.
/// Times are in CD frames (75 per second). Only the commands the app needs are read; anything
/// else is ignored.
public struct CueSheet: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        public var number: Int
        public var title: String?
        public var performer: String?
        /// Where the song starts (its `INDEX 01`), in frames.
        public var start: Int
    }

    public var title: String?
    public var performer: String?
    public var date: String?
    public var genre: String?
    /// The audio files named by `FILE` lines (one for an album to split).
    public var files: [String] = []
    public var tracks: [Track] = []

    /// Reads UTF-8 (with or without BOM), otherwise Windows-1252 (common with older rippers).
    public init(data: Data) {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? ""
        self.init(text: text)
    }

    public init(text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let words = Self.words(rawLine.trimmingCharacters(in: .whitespaces))
            guard let command = words.first?.uppercased() else { continue }
            let value = words.count > 1 ? words[1] : nil
            switch command {
            case "REM":
                guard words.count > 2 else { continue }
                switch words[1].uppercased() {
                case "DATE": date = words[2]
                case "GENRE": genre = words[2]
                default: break
                }
            case "TITLE":
                if tracks.isEmpty { title = value } else { tracks[tracks.count - 1].title = value }
            case "PERFORMER":
                if tracks.isEmpty { performer = value } else { tracks[tracks.count - 1].performer = value }
            case "FILE":
                if let value { files.append(value) }
            case "TRACK":
                if let value, let number = Int(value) {
                    tracks.append(Track(number: number, title: nil, performer: nil, start: 0))
                }
            case "INDEX":
                guard words.count > 2, Int(words[1]) == 1, !tracks.isEmpty, let frames = Self.frames(words[2]) else { continue }
                tracks[tracks.count - 1].start = frames
            default:
                break
            }
        }
    }

    /// Frames (1/75 s) → samples at `sampleRate` (exact: every common rate divides by 75).
    public static func samples(fromFrames frames: Int, sampleRate: Int) -> Int {
        frames * sampleRate / 75
    }

    /// "mm:ss:ff" → frames.
    static func frames(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0] * 60 + parts[1]) * 75 + parts[2]
    }

    /// Splits a line into words; "quoted text" is one word.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " || character == "\t", !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
