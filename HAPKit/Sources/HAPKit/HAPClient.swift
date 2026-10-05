import Foundation

/// Talks to one player's JSON control API on port 60200.
///
/// The player handles only one request at a time (it stops answering everything while
/// a request is pending), so every request here waits for the previous one to finish.
public actor HAPClient {
    /// Port of the player's control API.
    public static let port = 60200

    /// e.g. http://192.168.1.50:60200/sony
    public let baseURL: URL
    let session: URLSession
    private let timeout: TimeInterval
    /// How many times a question is asked before giving up. Our Wi-Fi drops ~2% of
    /// packets, and a lost packet can stall an answer for several seconds (NOTES.md).
    static let attemptsForQuestions = 3
    private var nextID = 1
    /// The most recently queued request; the next one waits for it.
    private var tail: Task<Void, Never>?

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 5) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public init(device: HAPDevice, session: URLSession = .shared) {
        self.init(baseURL: device.apiBaseURL, session: session)
    }

    public init(host: String, session: URLSession = .shared) {
        self.init(baseURL: URL(string: "http://\(host):\(Self.port)/sony")!, session: session)
    }

    // MARK: - Read-only commands

    /// Is the player on ("active") or in standby?
    public func powerStatus() async throws -> PowerStatus {
        try await first(of: [PowerStatus].self, ReadOnlyMethod.getPowerStatus)
    }

    /// Model, firmware version, MAC address…
    public func systemInformation() async throws -> SystemInformation {
        try await first(of: [SystemInformation].self, ReadOnlyMethod.getSystemInformation)
    }

    /// File patterns the player accepts, e.g. ["*.flac", "*.wav", …].
    public func supportedFileTypes() async throws -> [String] {
        try await first(of: [[String]].self, ReadOnlyMethod.getSupportedFileType)
    }

    /// What's playing (or paused) right now. Returns nil when nothing is loaded.
    public func playingContent() async throws -> PlayingContent? {
        let results = try await call(ReadOnlyMethod.getPlayingContentInfo, returning: [PlayingContent].self)
        guard let content = results.first, !content.isEmpty else { return nil }
        return content
    }

    // MARK: - Plumbing

    private func first<Element: Decodable & Sendable>(
        of type: [Element].Type, _ method: some RPCMethod
    ) async throws -> Element {
        guard let value = try await call(method, returning: type).first else {
            throw HAPError.unexpectedResponse("\(method.name) returned an empty result")
        }
        return value
    }

    func call<Result: Decodable & Sendable>(
        _ method: some RPCMethod, returning: Result.Type
    ) async throws -> Result {
        let attempts = method.isSafeToRetry ? Self.attemptsForQuestions : 1
        var lastError: Error = HAPError.timedOut(method.name)
        for _ in 0..<attempts {
            let id = nextID
            nextID += 1
            let request = try makeRequest(method, id: id)
            do {
                let data = try await serialized { [session] in
                    try await Self.send(request, session: session)
                }
                return try Self.decode(Result.self, from: data, method: method)
            } catch let error as HAPError where error.isWorthRetrying {
                lastError = error
            }
        }
        throw lastError
    }

    /// Runs `operation` only after every earlier request has finished.
    func serialized<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func makeRequest(_ method: some RPCMethod, id: Int) throws -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(method.service),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RPCRequest(method: method.name, params: method.params, version: method.version, id: id)
        )
        return request
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw HAPError.timedOut(request.url?.path ?? "request")
        } catch {
            throw HAPError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HAPError.http(status: http.statusCode)
        }
        return data
    }

    static func decode<Result: Decodable>(
        _ type: Result.Type, from data: Data, method: some RPCMethod
    ) throws -> Result {
        let reply: RPCResponse<Result>
        do {
            reply = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
        } catch {
            throw HAPError.unexpectedResponse("\(method.name): \(error)")
        }
        if let error = reply.error { throw HAPError.player(code: error.code, message: error.message) }
        guard let result = reply.result else {
            throw HAPError.unexpectedResponse("\(method.name): no result and no error")
        }
        return result
    }
}

/// {"method": "...", "params": [], "version": "1.0", "id": 1}
struct RPCRequest: Encodable {
    let method: String
    let params: [[String: ParamValue]]
    let version: String
    let id: Int
}

/// {"result": [...], "id": 1}  or  {"error": [12, "message"], "id": 1}
struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result?
    let error: RPCError?
    let id: Int?
}

struct RPCError: Decodable {
    let code: Int
    let message: String

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        code = try values.decode(Int.self)
        message = (try? values.decode(String.self)) ?? ""
    }
}
