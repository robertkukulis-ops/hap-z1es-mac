import Foundation
import Testing
@testable import HAPKit

/// A pretend player drive in a temporary folder (the real drive is never touched by tests).
struct FakeDrive {
    let root: URL
    let drive: HAPDrive

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeHAP-\(UUID().uuidString)")
        let files = [
            "My Mac/Users/me/Music/Logic/Song.logicx/Media/Audio Files/1 Drums.wav",
            "My Mac/Users/me/Music/Logic/Song.logicx/Media/Audio Files/._1 Drums.wav",
            "My Mac/Users/me/Music/Logic/.DS_Store",
            "OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav",
            "OTHER-PC/Users/someone/Desktop/Demo/._01 Midnight Sugar.wav",
            "OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav",
            "Sample Music/Miles Davis - So What.dsf",
        ]
        for (index, path) in files.enumerated() {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100 * (index + 1)).write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lost+found"), withIntermediateDirectories: true)
        drive = HAPDrive(root: root)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct DriveTests {
    @Test func junkIsRecognised() {
        #expect(HAPDrive.isJunk("._01 Midnight Sugar.wav"))
        #expect(HAPDrive.isJunk(".DS_Store"))
        #expect(!HAPDrive.isJunk("01 Midnight Sugar.wav"))
    }

    @Test func listingHidesJunkAndPutsFoldersFirst() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        let top = try fake.drive.items(in: fake.root).map(\.name)
        #expect(top == ["lost+found", "My Mac", "OTHER-PC", "Sample Music"])
        let demo = try fake.drive.items(in: fake.url("OTHER-PC/Users/someone/Desktop/Demo"))
        #expect(demo.map(\.name) == ["01 Midnight Sugar.wav", "02 Black Nights.wav"])
        #expect(demo.allSatisfy { !$0.isFolder && ($0.size ?? 0) > 0 })
    }

    @Test func countIncludesEverythingThatWouldBeDeleted() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        let logic = [fake.url("My Mac/Users/me/Music/Logic")]
        let summary = fake.drive.count(logic)
        #expect(summary.files == 3)       // the WAV, its ._ companion, .DS_Store
        #expect(summary.junkFiles == 2)
        #expect(fake.drive.count([fake.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav")]).files == 1)
    }

    @Test func sizeCountsTheMusic() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        // WAV (100 bytes) + .DS_Store (300); the tiny ._ companion isn't included.
        #expect(fake.drive.size(of: [fake.url("My Mac/Users/me/Music/Logic")]) == 400)
    }

    @Test func relativePaths() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        #expect(fake.drive.relativePath(of: fake.url("OTHER-PC/Users")) == "OTHER-PC/Users")
    }

    @Test func deletesAFolderCompletely() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        try fake.drive.delete([fake.url("My Mac/Users/me/Music/Logic")])
        #expect(!fake.exists("My Mac/Users/me/Music/Logic"))
        #expect(fake.exists("My Mac/Users/me/Music"))  // parent untouched
        #expect(fake.exists("OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav"))
    }

    @Test func findsMacLeftoversButNothingElse() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        try Data(repeating: 1, count: 10).write(to: fake.url("Sample Music/.hap-upload-0BADF00D.part"))
        try Data(repeating: 1, count: 10).write(to: fake.url("lost+found/._hidden"))  // must be ignored
        let found = fake.drive.macLeftovers(in: fake.root).map { fake.drive.relativePath(of: $0) }
        #expect(found == [
            "My Mac/Users/me/Music/Logic/.DS_Store",
            "My Mac/Users/me/Music/Logic/Song.logicx/Media/Audio Files/._1 Drums.wav",
            "OTHER-PC/Users/someone/Desktop/Demo/._01 Midnight Sugar.wav",
            "Sample Music/.hap-upload-0BADF00D.part",
        ])
        // Only below the folder you're in:
        #expect(fake.drive.macLeftovers(in: fake.url("OTHER-PC")).count == 1)
        // Tidying removes exactly those, and no music.
        try fake.drive.delete(fake.drive.macLeftovers(in: fake.root))
        #expect(fake.drive.macLeftovers(in: fake.root).isEmpty)
        #expect(fake.exists("OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav"))
        #expect(fake.exists("lost+found/._hidden"))
    }

    @Test func deleteReportsProgressForEveryFile() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        let counter = Counter()
        try fake.drive.delete([fake.url("My Mac")]) { counter.last = $0 }
        #expect(counter.last == 3)   // WAV, its ._ companion, .DS_Store
        #expect(!fake.exists("My Mac"))
    }

    @Test func stoppingAfterTheFirstFileKeepsTheRest() async throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        let drive = fake.drive, target = fake.url("OTHER-PC")
        let before = drive.count([target]).files
        let task = Task {
            // Press "Stop" as soon as the first file is gone.
            try drive.delete([target]) { removed in
                if removed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(drive.count([target]).files == before - 1)
    }

    @Test func aCompanionThatVanishedByItselfIsNotAnError() throws {
        // On the player's drive, deleting "x.wav" makes macOS remove "._x.wav" too, so the
        // folder listing taken before can name a file that's gone by the time we get to it.
        let fake = try FakeDrive(); defer { fake.remove() }
        let demo = fake.url("OTHER-PC/Users/someone/Desktop/Demo")
        let order = SeenCounter()
        try fake.drive.delete([demo]) { _ in
            // After the first removal, make the companion disappear "by itself".
            if order.bump() == 1 {
                try? FileManager.default.removeItem(at: demo.appendingPathComponent("._01 Midnight Sugar.wav"))
            }
        }
        #expect(!fake.exists("OTHER-PC/Users/someone/Desktop/Demo"))
    }

    @Test func deletingAFileAlsoRemovesItsMacCompanion() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        try fake.drive.delete([fake.url("OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav")])
        #expect(!fake.exists("OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav"))
        #expect(!fake.exists("OTHER-PC/Users/someone/Desktop/Demo/._01 Midnight Sugar.wav"))
        #expect(fake.exists("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav"))
    }

    @Test func refusesTheDriveItselfLostFoundAndOutside() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        #expect(throws: HAPDrive.DeleteError.self) { try fake.drive.delete([fake.root]) }
        #expect(throws: HAPDrive.DeleteError.self) { try fake.drive.delete([fake.url("lost+found")]) }
        #expect(throws: HAPDrive.DeleteError.self) {
            try fake.drive.delete([FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")])
        }
        #expect(throws: HAPDrive.DeleteError.self) { try fake.drive.delete([fake.url("../escape")]) }
    }

    @Test func aBadItemMeansNothingIsDeleted() throws {
        let fake = try FakeDrive(); defer { fake.remove() }
        let good = fake.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav")
        #expect(throws: HAPDrive.DeleteError.self) { try fake.drive.delete([good, fake.url("lost+found")]) }
        #expect(fake.exists("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav"))
    }
}

@Suite struct OriginalLocatorTests {
    let locator = OriginalLocator(
        computerName: "My Mac",
        volumesRoot: URL(fileURLWithPath: "/Volumes"),
        fileExists: { ["/Users/me/Music/Logic", "/Volumes/Backup/1. Archive"].contains($0) })

    @Test func fromThisMacAndStillThere() {
        #expect(locator.status(ofPlayerPath: "My Mac/Users/me/Music/Logic")
                == .onThisMac(URL(fileURLWithPath: "/Users/me/Music/Logic")))
    }

    @Test func externalDriveOfThisMac() {
        #expect(locator.status(ofPlayerPath: "My Mac/Backup/1. Archive")
                == .onThisMac(URL(fileURLWithPath: "/Volumes/Backup/1. Archive")))
    }

    @Test func fromThisMacButGone() {
        #expect(locator.status(ofPlayerPath: "My Mac/Users/me/Old")
                == .missing(URL(fileURLWithPath: "/Users/me/Old")))
    }

    @Test func otherComputersAndPlayerFolders() {
        #expect(locator.status(ofPlayerPath: "OTHER-PC/Users/someone/Desktop/Demo") == .otherComputer("OTHER-PC"))
        #expect(locator.status(ofPlayerPath: "Sample Music/sub/x.dsf") == .unknown)
        #expect(locator.status(ofPlayerPath: "") == .unknown)
    }
}

final class Counter: @unchecked Sendable { var last = 0 }

final class SeenCounter: @unchecked Sendable {
    private var count = 0
    func bump() -> Int { count += 1; return count }
}

struct DuplicateMountTests {
    private func volume(_ path: String, _ remote: String?, readOnly: Bool = false) -> HAPDrive.MountedVolume {
        HAPDrive.MountedVolume(url: URL(fileURLWithPath: path), remote: remote.flatMap(URL.init(string:)), readOnly: readOnly)
    }

    @Test func extraMountsOfTheSameDriveAreFound() {
        let volumes = [volume("/Volumes/HAP_Internal", "smb://GUEST:@HAP-Z1ES/HAP_Internal"),
                       volume("/Volumes/HAP_Internal-1", "smb://GUEST:@HAP-Z1ES/HAP_Internal"),
                       volume("/Volumes/HAP_Internal-2", "smb://192.168.1.50/HAP_Internal"),
                       volume("/Volumes/Backup", nil),
                       volume("/Volumes/Other", "smb://nas/Music"),
                       volume("/private/tmp/hapro", "smb://guest@192.168.1.50/HAP_Internal", readOnly: true)]
        let extra = HAPDrive.duplicateMounts(in: volumes, hosts: ["HAP-Z1ES", "192.168.1.50"],
                                             share: "HAP_Internal", keeping: URL(fileURLWithPath: "/Volumes/HAP_Internal"))
        #expect(extra.map(\.path) == ["/Volumes/HAP_Internal-1", "/Volumes/HAP_Internal-2"])
    }

    @Test func theMountInUseIsNeverListed() {
        let volumes = [volume("/Volumes/HAP_Internal-3", "smb://GUEST:@HAP-Z1ES/HAP_Internal")]
        #expect(HAPDrive.duplicateMounts(in: volumes, hosts: ["HAP-Z1ES"], share: "HAP_Internal",
                                         keeping: URL(fileURLWithPath: "/Volumes/HAP_Internal-3")).isEmpty)
    }
}
