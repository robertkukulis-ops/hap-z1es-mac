import Foundation

/// Everything that can go wrong when talking to the player, in plain words.
public enum HAPError: Error, Equatable, LocalizedError {
    /// Nobody answered the SSDP "who's there?" message.
    case noPlayerFound
    /// The player answered with an HTTP status other than 200.
    case http(status: Int)
    /// The player understood the request but refused it (JSON `"error": [code, message]`).
    case player(code: Int, message: String)
    /// The reply wasn't in the shape we expected.
    case unexpectedResponse(String)
    /// The player's description file (hap.xml) was missing something essential.
    case invalidDescription(String)
    /// No answer in time. For a command, it may or may not have reached the player.
    case timedOut(String)
    /// A low-level network problem (no route, socket error…).
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .noPlayerFound:
            return "No HAP player answered. Is it switched on and on the same network?"
        case .http(let status):
            return "The player answered with HTTP status \(status)."
        case .player(let code, let message):
            let meaning = switch code {
            case 12: "the player doesn't know this command"
            case 14: "wrong version number for this command"
            case 3: "a value in the request was not accepted"
            default: "the player refused the request"
            }
            return "Player error \(code) (\(meaning)): \(message)"
        case .unexpectedResponse(let detail):
            return "Unexpected reply from the player: \(detail)"
        case .invalidDescription(let detail):
            return "The player's description file is incomplete: \(detail)"
        case .timedOut(let what):
            return "No answer from the player in time (\(what)). The network may be dropping packets."
        case .network(let detail):
            return "Network problem: \(detail)"
        }
    }
}

extension HAPError {
    /// Timeouts and connection problems may go away on a second try; refusals won't.
    var isWorthRetrying: Bool {
        switch self {
        case .timedOut, .network: true
        default: false
        }
    }
}
