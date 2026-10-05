import Foundation
import Testing
@testable import HAPKit

// All tests use replies saved from the real player (Fixtures/, copied from api/).
// They never contact the network.

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct DiscoveryTests {
    @Test func searchMessageMatchesSonysAppByteForByte() {
        // Captured from HAP Music Transfer 1.3.2 (capture 01): 121 bytes.
        #expect(SSDP.searchMessage.utf8.count == 121)
        #expect(SSDP.searchMessage.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"))
        #expect(SSDP.searchMessage.hasSuffix("ST: urn:schemas-upnp-org:device:Basic:1\r\n\r\n"))
    }

    @Test func parsesThePlayersSSDPAnswer() throws {
        let answer = "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "DATE: Fri, 25 Sep 2026 10:43:54 GMT\r\n" +
            "EXT: \r\n" +
            "LOCATION: http://192.168.1.50:60100/hap.xml\r\n" +
            "SERVER: Linux/3.0 UPnP/1.0 Sony-HAP/1.0\r\n" +
            "ST: urn:schemas-upnp-org:device:Basic:1\r\n" +
            "USN: uuid:00000000-0000-1010-8000-001122334455::urn:schemas-upnp-org:device:Basic:1\r\n\r\n"
        let response = try #require(SSDPResponse(answer))
        #expect(response.location.absoluteString == "http://192.168.1.50:60100/hap.xml")
        #expect(response.isSonyHAP)
    }

    @Test func ignoresNonAnswers() {
        #expect(SSDPResponse("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n\r\n") == nil)
    }

    @Test func readsTheDescriptionFile() throws {
        let url = URL(string: "http://192.168.1.50:60100/hap.xml")!
        let device = try DeviceDescription.parse(try fixture("hap.xml"), from: url)
        #expect(device.friendlyName == "HAP-Z1ES")
        #expect(device.modelName == "HAP-Z1ES")
        #expect(device.udn == "uuid:00000000-0000-1010-8000-001122334455")
        #expect(device.macAddress == "00:11:22:33:44:55")
        #expect(device.firmwareVersion == "0019404R")
        #expect(device.apiBaseURL.absoluteString == "http://192.168.1.50:60200/sony")
        #expect(device.host == "192.168.1.50")
    }
}

@Suite(.serialized) struct ClientTests {
    let client = HAPClient(host: "192.168.1.50", session: StubProtocol.session)

    @Test func powerStatus() async throws {
        StubProtocol.reply = try fixture("system-getPowerStatus.json")
        let power = try await client.powerStatus()
        #expect(power == PowerStatus(status: "active", standbyDetail: ""))
        let sent = try #require(StubProtocol.lastRequest)
        #expect(sent.url?.absoluteString == "http://192.168.1.50:60200/sony/system")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Expect") == nil)  // the player refuses it
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
        #expect(body?["method"] as? String == "getPowerStatus")
        #expect(body?["version"] as? String == "1.1")
        #expect((body?["params"] as? [Any])?.isEmpty == true)
    }

    @Test func systemInformation() async throws {
        StubProtocol.reply = try fixture("system-getSystemInformation.json")
        let info = try await client.systemInformation()
        #expect(info.model == "HAP-Z1ES")
        #expect(info.version == "0019404R")
        #expect(StubProtocol.lastRequest?.url?.lastPathComponent == "system")
    }

    @Test func supportedFileTypes() async throws {
        // The reply captured from the player (capture 01).
        StubProtocol.reply = Data(#"{"result": [["*.3gp", "*.aa3", "*.aif", "*.aiff", "*.dff", "*.dsf", "*.fla", "*.flac", "*.m4a", "*.mp3", "*.mp4", "*.oma", "*.wav", "*.wma"]], "id": 11}"#.utf8)
        let types = try await client.supportedFileTypes()
        #expect(types.count == 14)
        #expect(types.contains("*.flac"))
        #expect(StubProtocol.lastRequest?.url?.lastPathComponent == "avContent")
    }

    @Test func playingContent() async throws {
        StubProtocol.reply = try fixture("avContent-getPlayingContentInfo.json")
        let now = try #require(try await client.playingContent())
        #expect(now.title == "Midnight Sugar")
        #expect(now.artist == "Tsuyoshi Yamamoto Trio")
        #expect(now.albumName == "The TBM Sounds")
        #expect(now.state == "PAUSED")
        #expect(now.positionMsec == 5000)
        #expect(now.durationMsec == 723_000)
        #expect(now.listIndex == 1 && now.listCount == 805)
        #expect(now.formatDescription == "WAV · 44.1 kHz / 16-bit")
    }

    @Test func togglePlayPauseSendsSonysShape() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"result": [], "id": 1}"#.utf8)
        try await client.togglePlayPause()
        #expect(StubProtocol.lastRequest?.url?.path == "/sony/avContent")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
        #expect(body?["method"] as? String == "pausePlayingContent")
        #expect(body?["version"] as? String == "1.0")
        let params = try #require(body?["params"] as? [[String: Any]])
        #expect(params.count == 1 && params[0].isEmpty)  // [{}]
    }

    @Test func nextAndPreviousSendSonysShape() async throws {
        for (action, method) in [("next", "setPlayNextContent"), ("previous", "setPlayPreviousContent")] {
            StubProtocol.reset()
            StubProtocol.reply = Data(#"{"result": [], "id": 1}"#.utf8)
            if action == "next" { try await client.nextTrack() } else { try await client.previousTrack() }
            #expect(StubProtocol.lastRequest?.url?.path == "/sony/avContent")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
            #expect(body?["method"] as? String == method)
            #expect(body?["version"] as? String == "1.0")
            #expect((body?["params"] as? [[String: Any]])?.first?.isEmpty == true)
        }
    }

    @Test func playTrackSendsSonysShape() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"result": [{"playbackControlMode": "folder", "uri": "audio:playinglist?id=70"}], "id": 1}"#.utf8)
        try await client.playTrack(id: 249)
        #expect(StubProtocol.lastRequest?.url?.path == "/sony/avContent")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
        #expect(body?["method"] as? String == "createPlayingListAndQuickPlay")
        #expect(body?["version"] as? String == "1.0")
        let params = try #require((body?["params"] as? [[String: Any]])?.first)
        #expect(params["uri"] as? String == "audio:track?id=249")
        #expect(params["listIndex"] as? Int == 0)
        #expect(params["listCount"] as? Int == 1)
        #expect(params["playbackControlMode"] as? String == "folder")
    }

    @Test func seekSendsSonysShape() async throws {
        // Sony's app sends the second plus 0.01; a whole number made the player restart the
        // track instead (tested on our player 2026-10-05).
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"result": [], "id": 1}"#.utf8)
        try await client.seek(toSecond: 60)
        #expect(StubProtocol.lastRequest?.url?.path == "/sony/avContent")
        let text = String(decoding: StubProtocol.lastBody, as: UTF8.self)
        #expect(text.contains(#""positionSec":60.01"#))
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
        #expect(body?["method"] as? String == "setPlayContent")
        #expect(body?["version"] as? String == "1.1")
        let params = try #require((body?["params"] as? [[String: Any]])?.first)
        #expect(params.count == 1)
    }

    @Test func seekNeverGoesBelowZero() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"result": [], "id": 1}"#.utf8)
        try await client.seek(toSecond: -5)
        #expect(String(decoding: StubProtocol.lastBody, as: UTF8.self).contains(#""positionSec":0.01"#))
    }

    @Test func questionsAreRetriedAfterTimeouts() async throws {
        StubProtocol.reset()
        StubProtocol.reply = try fixture("system-getPowerStatus.json")
        StubProtocol.timeoutsLeft = 2
        let power = try await client.powerStatus()
        #expect(power.isActive)
        #expect(StubProtocol.requestedURLs.count == 3)
    }

    @Test func questionsGiveUpAfterThreeTries() async throws {
        StubProtocol.reset()
        StubProtocol.timeoutsLeft = 5
        await #expect(throws: HAPError.self) { try await client.powerStatus() }
        #expect(StubProtocol.requestedURLs.count == 3)
    }

    @Test func commandsAreNeverRetried() async throws {
        // A repeated play/pause would undo itself, so one try only.
        StubProtocol.reset()
        StubProtocol.timeoutsLeft = 1
        StubProtocol.reply = Data(#"{"result": [], "id": 1}"#.utf8)
        await #expect(throws: HAPError.timedOut("/sony/avContent")) { try await client.togglePlayPause() }
        #expect(StubProtocol.requestedURLs.count == 1)
    }

    @Test func playerErrorsBecomeReadableErrors() async throws {
        StubProtocol.reply = Data(#"{"error": [12, "getPowerStatus"], "id": 1}"#.utf8)
        await #expect(throws: HAPError.player(code: 12, message: "getPowerStatus")) {
            try await client.powerStatus()
        }
    }

    @Test func httpErrorsAreReported() async throws {
        StubProtocol.reply = Data()
        StubProtocol.status = 500
        defer { StubProtocol.status = 200 }
        await #expect(throws: HAPError.http(status: 500)) {
            try await client.powerStatus()
        }
    }
}

@Suite struct SafetyTests {
    @Test func onlyReadOnlyCommandsExist() {
        // Tier 1 must contain questions only. Anything that could change the player
        // (set…, delete…, create…, edit…, pause…) must never appear in this list.
        for method in ReadOnlyMethod.allCases {
            #expect(method.rawValue.hasPrefix("get"), "\(method.rawValue) is not a read-only command")
            #expect(method.params.isEmpty)
        }
    }

    @Test func controlCommandsAreExactlyTheApprovedOnes() {
        // Tier 2 grows only with the user's explicit approval (see NOTES.md).
        #expect(ControlMethod.allCases.map(\.rawValue) ==
            ["pausePlayingContent", "setPlayNextContent", "setPlayPreviousContent",
             "createPlayingListAndQuickPlay",
             "setPlayContent"])  // seek, approved and tested with the user 2026-10-05
    }

    @Test func forbiddenCommandsAppearNowhere() {
        let all = ReadOnlyMethod.allCases.map(\.name) + ControlMethod.allCases.map(\.rawValue)
        for word in ["delete", "Delete", "key", "Key", "firmware", "Firmware", "network", "Network"] {
            #expect(!all.contains { $0.contains(word) }, "found forbidden word \(word)")
        }
    }
}

/// Stands in for the network: answers with `replies[path?query]` if set, otherwise `reply`,
/// and remembers what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var replies: [String: Data] = [:]
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    /// The next N requests fail as if a packet was lost (timeout).
    nonisolated(unsafe) static var timeoutsLeft = 0

    static func reset() {
        reply = Data(); replies = [:]; status = 200; timeoutsLeft = 0
        lastRequest = nil; lastBody = Data(); requestedURLs = []
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lastRequest = request
        Self.requestedURLs.append(url)
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        if Self.timeoutsLeft > 0 {
            Self.timeoutsLeft -= 1
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.replies[key] ?? Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
