import Darwin
import Foundation

/// A live update from the player: *what* changed and *where* to read the new state.
/// It doesn't carry the new state itself (reported by HAP-Revival, NOTES.md).
public struct HAPEvent: Sendable, Equatable {
    /// e.g. "playingtrackChanged", "playinginfoChanged", "playqueueChanged", "powerstateChanged".
    public let name: String
    /// Where to read the new state, e.g. http://…:60200/sony/contentplayer/v100/playinginfo
    public let url: URL?
    /// The player's counter; each event arrives three times with the same number.
    public let sequence: Int
    /// Which player sent it (same unique ID as in hap.xml).
    public let playerUDN: String?

    public var kind: Kind { Kind(rawValue: name) ?? .other }

    public enum Kind: String, Sendable {
        case playqueueChanged, playingtrackChanged, playinginfoChanged, volumeChanged, powerstateChanged
        case other
    }
}

extension HAPEvent {
    /// Parses a message such as:
    ///   NOTIFY * HTTP/1.1\r\nContent-Type: application/json\r\nSEQ: 1\r\n
    ///   X-ContentServiceHostUUID: uuid:…\r\n\r\n{"event": "…", "url": "…"}
    init?(notify text: String) {
        guard text.hasPrefix("NOTIFY"),
              let split = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") else { return nil }
        var headers: [String: String] = [:]
        for line in text[..<split.lowerBound].split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        struct Body: Decodable { let event: String; let url: String? }
        guard let body = try? JSONDecoder().decode(Body.self, from: Data(text[split.upperBound...].utf8))
        else { return nil }
        self.init(
            name: body.event,
            url: body.url.flatMap(URL.init(string:)),
            sequence: headers["SEQ"].flatMap(Int.init) ?? -1,
            playerUDN: headers["X-CONTENTSERVICEHOSTUUID"]
        )
    }
}

extension HAPClient {
    /// How long the player keeps sending after a sign-up (it answers 300 s), and when we renew.
    static let subscriptionRenewal: Duration = .seconds(240)

    /// Live updates from the player. Opens a small UDP "mailbox" on this Mac, asks the player
    /// to send updates there, renews that every 4 minutes, and drops the duplicate copies.
    /// Stop by cancelling the task that reads the stream.
    public nonisolated func events() -> AsyncThrowingStream<HAPEvent, Error> {
        AsyncThrowingStream { continuation in
            let mailbox: UDPMailbox
            do {
                mailbox = try UDPMailbox()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Keep signed up while someone is listening.
            let renewer = Task {
                do {
                    while !Task.isCancelled {
                        try await self.subscribe(port: mailbox.port)
                        try await Task.sleep(for: Self.subscriptionRenewal)
                    }
                } catch is CancellationError {
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Read messages on a background thread; each arrives 3×, pass it on once.
            let reader = Thread {
                var seen: [String] = []
                while !mailbox.isStopped {
                    guard let text = mailbox.receive() else { continue }
                    guard let event = HAPEvent(notify: text) else { continue }
                    let key = "\(event.playerUDN ?? "")#\(event.sequence)"
                    if seen.contains(key) { continue }
                    seen.append(key)
                    if seen.count > 50 { seen.removeFirst() }
                    continuation.yield(event)
                }
                mailbox.close()
            }
            reader.start()

            continuation.onTermination = { _ in
                renewer.cancel()
                mailbox.stop()
            }
        }
    }

    /// Asks the player to send live updates to `port` on this Mac, for the next 300 s.
    /// POST /sony/notification/status {"status": "enable", "port": N}
    /// It changes nothing about playback, and asking again is harmless, so it's retried.
    func subscribe(port: UInt16) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("notification/status"), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"status": "enable", "port": \#(port)}"#.utf8)
        var lastError: Error = HAPError.timedOut("notification/status")
        for _ in 0..<Self.attemptsForQuestions {
            do {
                _ = try await serialized { [session, request] in
                    try await Self.send(request, session: session)
                }
                return
            } catch let error as HAPError where error.isWorthRetrying {
                lastError = error
            }
        }
        throw lastError
    }
}

/// A UDP socket on a free port of this Mac, where the player's messages arrive.
final class UDPMailbox: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    /// Set by `stop()`; the reader thread checks it after each (≤ 0.5 s) wait.
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw HAPError.network("could not open a UDP socket (errno \(errno))") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // let macOS pick a free port
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(socketFD)
            throw HAPError.network("could not open the update mailbox (errno \(errno))")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        // Wake up twice a second so the reader can notice it was stopped.
        var tick = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tick, socklen_t(MemoryLayout<timeval>.size))
        fd = socketFD
        port = UInt16(bigEndian: actual.sin_port)
    }

    /// One message, or nil if nothing arrived within half a second.
    func receive() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    func close() { Darwin.close(fd) }
}
