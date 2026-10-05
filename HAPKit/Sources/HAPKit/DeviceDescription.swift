import Foundation

/// Reads the player's `hap.xml` description file (served on port 60100).
enum DeviceDescription {
    /// Port of the player's small "business card" web server.
    static let port = 60100

    static func url(forHost host: String) -> URL {
        URL(string: "http://\(host):\(port)/hap.xml")!
    }

    /// Turns the XML text of hap.xml into an `HAPDevice`.
    static func parse(_ data: Data, from descriptionURL: URL) throws -> HAPDevice {
        let fields = XMLFields.extract(
            from: data,
            names: ["friendlyName", "modelName", "UDN", "X_ScalarWebAPI_BaseURL",
                    "X_HAP_Version", "X_HAP_MACAddr"]
        )
        guard let udn = fields["UDN"], !udn.isEmpty else {
            throw HAPError.invalidDescription("no UDN (unique ID)")
        }
        guard let base = fields["X_ScalarWebAPI_BaseURL"], let apiBaseURL = URL(string: base) else {
            throw HAPError.invalidDescription("no X_ScalarWebAPI_BaseURL (control address)")
        }
        return HAPDevice(
            friendlyName: fields["friendlyName"] ?? "HAP",
            modelName: fields["modelName"] ?? "unknown",
            udn: udn,
            macAddress: fields["X_HAP_MACAddr"],
            firmwareVersion: fields["X_HAP_Version"],
            apiBaseURL: apiBaseURL,
            descriptionURL: descriptionURL
        )
    }
}

/// Collects the text of the first element with each wanted name, ignoring XML namespaces
/// (so `<av:X_HAP_Version>` matches "X_HAP_Version").
private final class XMLFields: NSObject, XMLParserDelegate {
    private let wanted: Set<String>
    private var found: [String: String] = [:]
    private var current: String?
    private var text = ""

    private init(wanted: Set<String>) { self.wanted = wanted }

    static func extract(from data: Data, names: Set<String>) -> [String: String] {
        let collector = XMLFields(wanted: names)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        return collector.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if wanted.contains(elementName), found[elementName] == nil {
            current = elementName
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == current {
            found[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            current = nil
        }
    }
}
