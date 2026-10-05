import Foundation
import Testing
@testable import HAPKit

extension ClientTests {
    static let directory = "/sony/contentdb/v100/services/directory"

    func stubDirectory() throws {
        StubProtocol.reset()
        let q = "?offset=0&limit=500"
        StubProtocol.replies["\(Self.directory)\(q)"] = try fixture("directory-top.json")
        StubProtocol.replies["\(Self.directory)/4100\(q)"] = try fixture("directory-4100.json")
        StubProtocol.replies["\(Self.directory)/4100/4285\(q)"] = try fixture("directory-collection.json")
        StubProtocol.replies["\(Self.directory)/4100/4285/4286\(q)"] = try fixture("directory-compilations.json")
        StubProtocol.replies["\(Self.directory)/4100/4285/4286/4291\(q)"] = try fixture("directory-smooth.json")
    }

    @Test func folderViewTopLevel() async throws {
        try stubDirectory()
        let top = try await client.directory()
        let names = top.compactMap { item -> String? in
            if case .folder(let name, _, _) = item { return name }
            return nil
        }
        #expect(names.contains("Collection"))
        #expect(names.contains("Sample Music"))
    }

    @Test func tracksInAFolderByFileName() async throws {
        try stubDirectory()
        let tracks = try await client.tracksInFolder(["Collection", "Compilations", "Smooth & Groove"])
        #expect(tracks["Beady Belle - Walk on Air.flac"]?.trackid == 325)
        #expect(tracks["Beady Belle - Diamond in the Rough.flac"]?.trackid == 371)
        #expect(tracks.count == 6)
    }

    @Test func trackLocationsWalkTheWholeTree() async throws {
        try stubDirectory()
        // Folders we have no saved reply for answer "{}" (empty).
        StubProtocol.reply = Data("{}".utf8)
        let locations = try await client.trackLocations()
        #expect(locations[325] == "Collection/Compilations/Smooth & Groove/Beady Belle - Walk on Air.flac")
        #expect(locations.count == 6)
    }

    @Test func unknownFolderGivesNoTracks() async throws {
        try stubDirectory()
        #expect(try await client.tracksInFolder(["Collection", "No such folder"]).isEmpty)
    }

    @Test func folderLinksOutsideTheFolderViewAreRefused() async throws {
        StubProtocol.reset()
        await #expect(throws: HAPError.self) { try await client.directory("http://192.168.1.50:60200/sony/avContent") }
    }
}
