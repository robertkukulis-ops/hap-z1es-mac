/// Safety tier 2: commands that change something on the player.
///
/// Each one is added only after the user has approved it and we've tried it together
/// on the real player (NOTES.md, "Control commands"). Forbidden commands (deleteContent,
/// front-panel keys, network settings, firmware) are never written anywhere.
enum ControlMethod: String, CaseIterable, Sendable {
    /// Play/pause toggle: plays when paused, pauses when playing (reported by HAP-Revival,
    /// from Sony's Android app). Approved by the user 2026-09-28.
    case pausePlayingContent
    /// Next / previous track in the play queue (reported by HAP-Revival).
    /// Approved by the user 2026-09-28.
    case setPlayNextContent
    case setPlayPreviousContent
    /// Replace the play queue with ONE track and start playing it (reported by HAP-Revival,
    /// live-tested there; a whole album can't be queued this way). Approved 2026-09-28.
    case createPlayingListAndQuickPlay
    /// Jump within the current track: `[{"positionSec": N + 0.01}]` (Sony's app adds 0.01; a
    /// whole number made our player restart the track). Reported by HAP-Revival from Sony's
    /// app; approved and tested with the user 2026-10-05.
    case setPlayContent

    var service: String { "avContent" }
    var version: String { self == .setPlayContent ? "1.1" : "1.0" }
}

/// One command with its parameters, ready to send. Only built by the methods below.
struct ControlCall: RPCMethod {
    let method: ControlMethod
    let params: [[String: ParamValue]]

    var name: String { method.rawValue }
    var service: String { method.service }
    var version: String { method.version }
    /// Never retried automatically: after a timeout, check the player's state instead.
    var isSafeToRetry: Bool { false }

    /// Commands without settings take `[{}]`: one empty object.
    static func simple(_ method: ControlMethod) -> ControlCall {
        ControlCall(method: method, params: [[:]])
    }
}

extension HAPClient {
    /// Plays if paused, pauses if playing.
    public func togglePlayPause() async throws {
        _ = try await call(ControlCall.simple(.pausePlayingContent), returning: [IgnoredValue].self)
    }

    /// Skips to the next track in the play queue.
    public func nextTrack() async throws {
        _ = try await call(ControlCall.simple(.setPlayNextContent), returning: [IgnoredValue].self)
    }

    /// Goes to the previous track in the play queue.
    public func previousTrack() async throws {
        _ = try await call(ControlCall.simple(.setPlayPreviousContent), returning: [IgnoredValue].self)
    }
}

extension HAPClient {
    /// Replaces the play queue with this one track and starts playing it.
    /// `trackID` is the library's `trackid` (e.g. from `tracks(inAlbum:)`).
    public func playTrack(id trackID: Int) async throws {
        let call = ControlCall(method: .createPlayingListAndQuickPlay, params: [[
            "uri": .string("audio:track?id=\(trackID)"),
            "listIndex": 0,
            "listCount": 1,
            "playbackControlMode": "folder",
        ]])
        _ = try await self.call(call, returning: [IgnoredValue].self)
    }
}

extension HAPClient {
    /// Jumps to `second` in the current track.
    public func seek(toSecond second: Int) async throws {
        let call = ControlCall(method: .setPlayContent, params: [["positionSec": .double(Double(max(0, second)) + 0.01)]])
        _ = try await self.call(call, returning: [IgnoredValue].self)
    }
}

/// Accepts any JSON value; used for replies we don't need, such as `"result": []`.
struct IgnoredValue: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
