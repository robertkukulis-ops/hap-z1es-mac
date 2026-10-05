import Foundation

/// A player found on the network, as described by its `hap.xml` "business card".
public struct HAPDevice: Sendable, Equatable, Hashable {
    /// Name shown to people, e.g. "HAP-Z1ES".
    public let friendlyName: String
    /// Model, e.g. "HAP-Z1ES".
    public let modelName: String
    /// Permanent unique ID, e.g. "uuid:00000000-0000-1010-8000-001122334455".
    /// Use this, not the IP address, to recognise the same player later.
    public let udn: String
    /// Hardware address, e.g. "00:11:22:33:44:55".
    public let macAddress: String?
    /// Firmware tag, e.g. "0019404R".
    public let firmwareVersion: String?
    /// Where the JSON control commands go, e.g. http://192.168.1.50:60200/sony
    public let apiBaseURL: URL
    /// Where the description file was read from, e.g. http://192.168.1.50:60100/hap.xml
    public let descriptionURL: URL

    /// The player's current IP address (or host name).
    public var host: String { descriptionURL.host ?? apiBaseURL.host ?? "" }

    public init(
        friendlyName: String, modelName: String, udn: String,
        macAddress: String?, firmwareVersion: String?,
        apiBaseURL: URL, descriptionURL: URL
    ) {
        self.friendlyName = friendlyName
        self.modelName = modelName
        self.udn = udn
        self.macAddress = macAddress
        self.firmwareVersion = firmwareVersion
        self.apiBaseURL = apiBaseURL
        self.descriptionURL = descriptionURL
    }
}
