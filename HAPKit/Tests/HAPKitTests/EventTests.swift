import Foundation
import Testing
@testable import HAPKit

@Suite struct EventParsingTests {
    // Example message from HAP-Revival's notes (a HAP on their network).
    static let sample = "NOTIFY * HTTP/1.1\r\n" +
        "Content-Length: 112\r\n" +
        "Content-Type: application/json\r\n" +
        "SEQ: 1\r\n" +
        "X-ContentServiceHostUUID: uuid:00000000-0000-1010-8000-104FA86F4B84\r\n" +
        "\r\n" +
        #"{ "event": "playingtrackChanged", "url": "http://192.168.1.28:60200/sony/contentplayer/v100/playinginfo" }"#

    @Test func readsAnUpdateMessage() throws {
        let event = try #require(HAPEvent(notify: Self.sample))
        #expect(event.name == "playingtrackChanged")
        #expect(event.kind == .playingtrackChanged)
        #expect(event.sequence == 1)
        #expect(event.playerUDN == "uuid:00000000-0000-1010-8000-104FA86F4B84")
        #expect(event.url?.path == "/sony/contentplayer/v100/playinginfo")
    }

    @Test func unknownEventsAreKept() throws {
        let text = "NOTIFY * HTTP/1.1\r\nSEQ: 7\r\n\r\n{\"event\": \"somethingNew\"}"
        let event = try #require(HAPEvent(notify: text))
        #expect(event.kind == .other)
        #expect(event.url == nil)
    }

    @Test func ignoresOtherTraffic() {
        #expect(HAPEvent(notify: "M-SEARCH * HTTP/1.1\r\n\r\n") == nil)
        #expect(HAPEvent(notify: "NOTIFY * HTTP/1.1\r\n\r\nnot json") == nil)
    }

    @Test func mailboxGetsAFreePort() throws {
        let mailbox = try UDPMailbox()
        defer { mailbox.close() }
        #expect(mailbox.port > 0)
    }
}

extension ClientTests {
    @Test func subscribeSendsTheSignUp() async throws {
        StubProtocol.reset()
        StubProtocol.reply = Data(#"{"timeout": 300, "port": 50123}"#.utf8)
        try await client.subscribe(port: 50123)
        #expect(StubProtocol.lastRequest?.url?.path == "/sony/notification/status")
        #expect(StubProtocol.lastRequest?.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as? [String: Any]
        #expect(body?["status"] as? String == "enable")
        #expect(body?["port"] as? Int == 50123)
    }

    @Test func playingInfoDecodes() async throws {
        StubProtocol.reset()
        StubProtocol.reply = try fixture("contentplayer-playinginfo.json")
        let info = try #require(try await client.playingInfo())
        #expect(info.playbackState == "paused")
        #expect(info.playqueuePosition == 1)
        #expect(info.playqueueVersion == 52)
        #expect(info.track?.trackid == 337)
        #expect(info.track?.name == "Midnight Sugar")
        #expect(info.track?.album?.albumid == 176)
        #expect(info.sourceType == "hdd")
        #expect(StubProtocol.lastRequest?.url?.path == "/sony/contentplayer/v100/playinginfo")
        #expect(StubProtocol.lastRequest?.httpMethod == "GET")
    }

    @Test func emptyPlayerMeansNothingLoaded() async throws {
        // The player answers 500 when the queue is empty (reported).
        StubProtocol.reset()
        StubProtocol.status = 500
        #expect(try await client.playingInfo() == nil)
    }

    @Test func playQueueDecodes() async throws {
        StubProtocol.reset()
        StubProtocol.reply = try fixture("contentplayer-playqueue.json")
        let queue = try await client.playQueue().playlist
        #expect(queue.name == "Playqueue")
        #expect(queue.numberOfTracks == 805)
        #expect(queue.version == 52)
    }
}
