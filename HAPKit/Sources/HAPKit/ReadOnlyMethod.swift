/// Anything that can be sent to the JSON API: only `ReadOnlyMethod` and `ControlMethod` conform.
protocol RPCMethod: Sendable {
    var name: String { get }
    var service: String { get }
    var version: String { get }
    var params: [[String: ParamValue]] { get }
    /// Asking again is harmless for questions, but a repeated command could undo itself
    /// (two play/pause toggles = no change), so only questions are retried.
    var isSafeToRetry: Bool { get }
}

/// The only JSON commands HAPKit can send, all verified read-only on our player (NOTES.md).
///
/// Safety tier 1: these just ask questions. Commands that change something get their own,
/// separate list (ControlMethod), one at a time, after testing them together. Forbidden commands
/// (deleteContent, front-panel keys, network settings, firmware) are never written anywhere.
enum ReadOnlyMethod: String, CaseIterable, Sendable, RPCMethod {
    case getPowerStatus
    case getSystemInformation
    case getSupportedFileType
    case getPlayingContentInfo

    var name: String { rawValue }

    /// All read-only questions take no parameters: `[]`.
    var params: [[String: ParamValue]] { [] }

    var isSafeToRetry: Bool { true }

    /// Which part of the API the command belongs to: POST /sony/<service>.
    var service: String {
        switch self {
        case .getPowerStatus, .getSystemInformation: "system"
        case .getSupportedFileType, .getPlayingContentInfo: "avContent"
        }
    }

    /// The HAP's own version number for each command (differs from other Sony devices).
    var version: String {
        switch self {
        case .getPowerStatus: "1.1"
        case .getSystemInformation: "1.2"
        case .getSupportedFileType: "1.0"
        case .getPlayingContentInfo: "1.2"
        }
    }
}

/// A parameter value in a request: text (`"folder"`), a whole number (`0`) or a decimal (`60.01`).
public enum ParamValue: Encodable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case string(String)
    case int(Int)
    case double(Double)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        }
    }
}
