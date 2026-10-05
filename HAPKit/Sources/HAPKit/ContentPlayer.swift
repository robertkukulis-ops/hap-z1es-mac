import Foundation

// The player's second API, "contentplayer": read-only GET requests on port 60200,
// e.g. GET /sony/contentplayer/v100/playinginfo. Live updates (Events.swift) point here.
// Only reading is implemented. Its write endpoint (…/operation) is not used.

/// Reply to GET …/contentplayer/v100/playinginfo.
public struct PlayingInfo: Decodable, Sendable, Equatable {
    /// "playing", "paused"…
    public let playbackState: String?
    /// Position in the play queue and the queue's change counter.
    public let playqueuePosition: Int?
    public let playqueueVersion: Int?
    public let track: Track?
    public let repeatMode: String?
    public let shuffleMode: String?
    /// "hdd", …
    public let sourceType: String?
}

/// Reply to GET …/contentplayer/v100/playqueue: `{"playlist": {...}}`.
public struct PlayQueue: Decodable, Sendable, Equatable {
    public let playlist: Playlist
}

/// The read-only contentplayer addresses HAPKit may ask for.
enum ContentPlayerPath: String, CaseIterable, Sendable {
    case playinginfo
    case playqueue
    case playqueueTracks = "playqueue/tracks"
    case powerstate
}

extension HAPClient {
    var contentPlayerBaseURL: URL { baseURL.appendingPathComponent("contentplayer/v100") }

    /// What's playing, with library ids. Returns nil when nothing is loaded
    /// (the player answers HTTP 500 then, reported by HAP-Revival).
    public func playingInfo() async throws -> PlayingInfo? {
        do {
            return try await getContentPlayer(.playinginfo, as: PlayingInfo.self)
        } catch HAPError.http(status: 500) {
            return nil
        }
    }

    /// The play queue's name, length and change counter.
    public func playQueue() async throws -> PlayQueue {
        try await getContentPlayer(.playqueue, as: PlayQueue.self)
    }

    /// The first `limit` tracks in the play queue.
    public func playQueueTracks(limit: Int = 50) async throws -> [Track] {
        let page = try await getContentPlayer(
            .playqueueTracks, query: ["offset": "0", "limit": String(limit)],
            as: LibraryPage<Track>.self)
        return page.items
    }

    func getContentPlayer<T: Decodable & Sendable>(
        _ path: ContentPlayerPath, query: [String: String] = [:], as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: contentPlayerBaseURL.appendingPathComponent(path.rawValue),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let request = URLRequest(url: components.url!, timeoutInterval: 5)
        var lastError: Error = HAPError.timedOut(path.rawValue)
        for _ in 0..<Self.attemptsForQuestions {
            do {
                let data = try await serialized { [session] in
                    try await Self.send(request, session: session)
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                do {
                    return try decoder.decode(T.self, from: data)
                } catch {
                    throw HAPError.unexpectedResponse("\(path.rawValue): \(error)")
                }
            } catch let error as HAPError where error.isWorthRetrying {
                lastError = error
            }
        }
        throw lastError
    }
}
