import Foundation

/// Reply to `getPowerStatus`, e.g. status "active" or "standby".
public struct PowerStatus: Decodable, Sendable, Equatable {
    public let status: String
    public let standbyDetail: String?

    public var isActive: Bool { status == "active" }
}

/// Reply to `getSystemInformation`.
public struct SystemInformation: Decodable, Sendable, Equatable {
    public let model: String?
    public let name: String?
    /// Firmware tag, e.g. "0019404R".
    public let version: String?
    public let macAddr: String?
    public let generation: String?
    public let product: String?
    public let language: String?
    public let cid: String?
    public let serial: String?
}

/// Reply to `getPlayingContentInfo`: what the player is playing (or paused on) right now.
public struct PlayingContent: Decodable, Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let albumName: String?
    public let genre: String?
    public let fileName: String?
    /// File format, e.g. "wav", "flac", "dsf".
    public let format: String?
    /// "PLAYING", "PAUSED", "STOPPED"…
    public let state: String?
    public let positionMsec: Int?
    public let durationMsec: Int?
    /// Position in the play queue (1-based) and queue length.
    public let listIndex: Int?
    public let listCount: Int?
    /// Track ID, e.g. "audio:track?id=337".
    public let uri: String?
    public let albumID: String?
    public let coverArtUrl: String?
    public let shuffleType: String?
    public let repeatType: String?
    public let audioInfo: [AudioInfo]?

    public struct AudioInfo: Decodable, Sendable, Equatable {
        public let frequency: String?
        public let bandwidth: String?
        public let codec: String?
        public let bitrate: String?
    }

    /// True when there's no track loaded at all.
    public var isEmpty: Bool { title == nil && uri == nil }

    /// e.g. "WAV · 44.1 kHz / 16-bit"
    public var formatDescription: String {
        var parts: [String] = []
        if let format { parts.append(format.uppercased()) }
        if let info = audioInfo?.first {
            var quality: [String] = []
            if let hz = info.frequency.flatMap(Double.init) {
                quality.append(hz.truncatingRemainder(dividingBy: 1000) == 0
                    ? "\(Int(hz / 1000)) kHz"
                    : String(format: "%.1f kHz", hz / 1000))
            }
            if let bits = info.bandwidth, !bits.isEmpty { quality.append("\(bits)-bit") }
            if !quality.isEmpty { parts.append(quality.joined(separator: " / ")) }
        }
        return parts.joined(separator: " · ")
    }
}
