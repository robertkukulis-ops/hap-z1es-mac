import Darwin
import Foundation

/// Finds HAP players on the local network.
public enum HAPDiscovery {
    /// Shouts SSDP "who's there?" and returns every HAP player that answers.
    /// Sends exactly the message HAP Music Transfer sends (see NOTES.md, capture 01).
    public static func find(
        timeout: Duration = .seconds(3),
        session: URLSession = .shared
    ) async throws -> [HAPDevice] {
        let responses = try await Task.detached {
            try SSDP.search(timeout: timeout)
        }.value

        var devices: [HAPDevice] = []
        for response in responses where response.isSonyHAP {
            if let device = try? await describe(response.location, session: session),
               !devices.contains(where: { $0.udn == device.udn }) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Reads the description of a player at a known address, skipping SSDP.
    public static func device(atHost host: String, session: URLSession = .shared) async throws -> HAPDevice {
        try await describe(DeviceDescription.url(forHost: host), session: session)
    }

    /// Reads hap.xml (read-only, so it's retried: at 3 KB it needs two packets,
    /// and a lost one can stall it).
    static func describe(_ url: URL, session: URLSession) async throws -> HAPDevice {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        var lastError: Error = HAPError.timedOut(url.path)
        for _ in 0..<HAPClient.attemptsForQuestions {
            do {
                let data = try await HAPClient.send(request, session: session)
                return try DeviceDescription.parse(data, from: url)
            } catch let error as HAPError where error.isWorthRetrying {
                lastError = error
            }
        }
        throw lastError
    }
}

/// One answer to an SSDP search.
struct SSDPResponse: Equatable {
    let location: URL
    let server: String
    let usn: String

    var isSonyHAP: Bool { server.contains("Sony-HAP") }

    /// Parses an answer such as "HTTP/1.1 200 OK\r\nLOCATION: http://…/hap.xml\r\n…".
    init?(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let location = headers["LOCATION"].flatMap(URL.init(string:)) else { return nil }
        self.location = location
        self.server = headers["SERVER"] ?? ""
        self.usn = headers["USN"] ?? ""
    }
}

enum SSDP {
    static let multicastAddress = "239.255.255.250"
    static let port: UInt16 = 1900

    /// Byte-for-byte the search HAP Music Transfer 1.3.2 sends (121 bytes).
    static let searchMessage =
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: 239.255.255.250:1900\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: 5\r\n" +
        "ST: urn:schemas-upnp-org:device:Basic:1\r\n" +
        "\r\n"

    /// Sends the search twice (as Sony's app does) and collects answers until `timeout`.
    /// Uses a plain UDP socket because the answers come back from the player's own
    /// address, not from the group address the search was sent to.
    static func search(timeout: Duration) throws -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw HAPError.network("could not open a UDP socket (errno \(errno))") }
        defer { close(fd) }

        // Wake up at least every 200 ms to check the deadline.
        var tick = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tick, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, multicastAddress, &target.sin_addr)

        // Send on every network port (Wi-Fi, Ethernet cable…), not just the main one:
        // the player may be cabled straight to the Mac (NOTES.md, "Direct cable").
        let bytes = Array(searchMessage.utf8)
        var sentSomewhere = false
        for interfaceAddress in multicastInterfaceAddresses() {
            var outgoing = interfaceAddress
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing,
                             socklen_t(MemoryLayout<in_addr>.size)) == 0 else { continue }
            for _ in 0..<2 {
                let sent = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent == bytes.count { sentSomewhere = true }
            }
        }
        guard sentSomewhere else {
            throw HAPError.network("could not send the SSDP search on any network port (errno \(errno))")
        }

        let deadline = ContinuousClock.now + timeout
        var results: [SSDPResponse] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        while ContinuousClock.now < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }  // timeout tick, check deadline again
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            if let response = SSDPResponse(text), !results.contains(where: { $0.usn == response.usn }) {
                results.append(response)
            }
        }
        return results
    }

    /// IPv4 addresses of the Mac's active network ports that can send multicast
    /// (e.g. Wi-Fi 192.168.1.20 and Ethernet 169.254.10.30), skipping loopback.
    static func multicastInterfaceAddresses() -> [in_addr] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [in_addr] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if !addresses.contains(where: { $0.s_addr == ipv4.s_addr }) { addresses.append(ipv4) }
        }
        return addresses
    }
}
