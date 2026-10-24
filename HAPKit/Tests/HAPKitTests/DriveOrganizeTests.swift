import Foundation
import Testing
@testable import HAPKit

struct DriveOrganizeTests {
    let fake: FakeDrive
    var drive: HAPDrive { fake.drive }

    init() throws { fake = try FakeDrive() }

    // MARK: New folder

    @Test func createsAFolder() throws {
        let made = try drive.createFolder(named: "Party mix", in: fake.root)
        #expect(made.lastPathComponent == "Party mix")
        #expect(fake.exists("Party mix"))
    }

    @Test func folderNamesAreMadeSafe() throws {
        let made = try drive.createFolder(named: "  AC/DC: Live?  ", in: fake.url("Sample Music"))
        #expect(made.lastPathComponent == "AC_DC_ Live_")
    }

    @Test func takenNamesAreRefusedInAnyCapitals() throws {
        #expect(throws: OrganizeError.alreadyExists("sample music")) {
            try drive.createFolder(named: "sample music", in: fake.root)
        }
    }

    @Test func emptyNamesAndLostFoundAreRefused() throws {
        #expect(throws: OrganizeError.emptyName) { try drive.createFolder(named: "   ", in: fake.root) }
        #expect(throws: (any Error).self) { try drive.createFolder(named: "x", in: fake.url("lost+found")) }
        #expect(throws: (any Error).self) { try drive.createFolder(named: "x", in: URL(fileURLWithPath: "/tmp")) }
    }

    // MARK: Moving

    @Test func movesFilesAndFoldersByRenaming() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let song = fake.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav")
        let before = try Data(contentsOf: song)
        let plan = try drive.planMove([song, fake.url("Sample Music")], into: target)
        #expect(plan.moves.count == 2)
        #expect(plan.skipped.isEmpty)
        try drive.move(plan)
        #expect(fake.exists("Mix/02 Black Nights.wav"))
        #expect(fake.exists("Mix/Sample Music/Miles Davis - So What.dsf"))
        #expect(!fake.exists("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav"))
        #expect(!fake.exists("Sample Music"))
        #expect(try Data(contentsOf: fake.url("Mix/02 Black Nights.wav")) == before)
    }

    @Test func theMacCompanionMovesAlong() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        try drive.move(try drive.planMove([fake.url("OTHER-PC/Users/someone/Desktop/Demo/01 Midnight Sugar.wav")], into: target))
        #expect(fake.exists("Mix/._01 Midnight Sugar.wav"))
        #expect(!fake.exists("OTHER-PC/Users/someone/Desktop/Demo/._01 Midnight Sugar.wav"))
    }

    @Test func nothingIsEverOverwritten() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        try Data("mine".utf8).write(to: target.appendingPathComponent("02 Black Nights.wav"))
        let plan = try drive.planMove([fake.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav")], into: target)
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped.first?.reason == "something with this name is already there")
        #expect(try Data(contentsOf: target.appendingPathComponent("02 Black Nights.wav")) == Data("mine".utf8))
    }

    @Test func aNameTakenAfterPlanningStopsTheMove() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let plan = try drive.planMove([fake.url("Sample Music/Miles Davis - So What.dsf")], into: target)
        try Data("new".utf8).write(to: target.appendingPathComponent("Miles Davis - So What.dsf"))
        #expect(throws: OrganizeError.alreadyExists("Miles Davis - So What.dsf")) { try drive.move(plan) }
        #expect(fake.exists("Sample Music/Miles Davis - So What.dsf"))
    }

    @Test func badMovesAreSkipped() throws {
        let inside = try drive.createFolder(named: "Inside", in: fake.url("Sample Music"))
        let plan = try drive.planMove([fake.url("Sample Music"),                     // into itself
                                       fake.url("Sample Music/Miles Davis - So What.dsf"),  // same folder
                                       fake.url("lost+found"),
                                       fake.url("OTHER-PC/Users/someone/Desktop/Demo/._01 Midnight Sugar.wav")],
                                      into: inside.deletingLastPathComponent())
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped.count == 4)
        let selfPlan = try drive.planMove([fake.url("Sample Music")], into: inside)
        #expect(selfPlan.skipped.first?.reason == "a folder can't go inside itself")
    }

    @Test func twoSelectedItemsWithTheSameName() throws {
        try Data("a".utf8).write(to: fake.url("Sample Music/02 Black Nights.wav"))
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let plan = try drive.planMove([fake.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav"),
                                       fake.url("Sample Music/02 Black Nights.wav")], into: target)
        #expect(plan.moves.count == 1)
        #expect(plan.skipped.first?.reason == "another selected item has the same name")
    }

    // MARK: Copying

    @Test func copyPlanKeepsStructureAndLeavesOutLeftovers() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let plan = try drive.planCopy([fake.url("OTHER-PC/Users/someone/Desktop/Demo")], into: target)
        #expect(plan.items.map { drive.relativePath(of: $0.destination) }
                == ["Mix/Demo/01 Midnight Sugar.wav", "Mix/Demo/02 Black Nights.wav"])
        #expect(plan.totalBytes > 0)
    }

    @Test func copyIntoTheSameFolderIsSkipped() throws {
        let plan = try drive.planCopy([fake.url("Sample Music/Miles Davis - So What.dsf")], into: fake.url("Sample Music"))
        #expect(plan.items.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test func copyingWithinTheDriveKeepsTheOriginal() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let song = fake.url("Sample Music/Miles Davis - So What.dsf")
        let plan = try drive.planCopy([song], into: target)
        try drive.upload(plan)
        #expect(fake.exists("Sample Music/Miles Davis - So What.dsf"))
        #expect(try Data(contentsOf: fake.url("Mix/Miles Davis - So What.dsf")) == Data(contentsOf: song))
    }

    @Test func sessionCopyFollowsAReconnect() throws {
        // After every file the session reconnects; the drive may then be at another place on
        // the Mac. A source on the drive must be read from the new place.
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let plan = try drive.planCopy([fake.url("OTHER-PC/Users/someone/Desktop/Demo")], into: target)
        let moved = fake.root.deletingLastPathComponent().appendingPathComponent("FakeHAP-moved-\(UUID().uuidString)")
        let session = UploadSession(drive: drive, stallLimit: 30) { old in
            try FileManager.default.moveItem(at: old.root, to: moved)  // "remounted elsewhere"
            return HAPDrive(root: moved)
        }
        try session.upload(plan)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Mix/Demo/02 Black Nights.wav").path))
        try? FileManager.default.removeItem(at: moved)
    }

    // MARK: Review fixes

    @Test func aStoppedFolderCopyCanBeResumed() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        let demo = fake.url("OTHER-PC/Users/someone/Desktop/Demo")
        var first = try drive.planCopy([demo], into: target)
        first.items = Array(first.items.prefix(1))  // "stopped" after one file
        try drive.upload(first)
        let again = try drive.planCopy([demo], into: target)
        #expect(again.items.map(\.destination.lastPathComponent) == ["02 Black Nights.wav"])
        #expect(again.skipped.map(\.reason) == ["something with this name is already there"])
    }

    @Test func aFileNamedLikeTheFolderStillBlocksTheCopy() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        try Data("x".utf8).write(to: target.appendingPathComponent("Demo"))
        let plan = try drive.planCopy([fake.url("OTHER-PC/Users/someone/Desktop/Demo")], into: target)
        #expect(plan.items.isEmpty)
    }

    @Test func movingIntoAnExistingFolderOfTheSameNameIsRefused() throws {
        let target = try drive.createFolder(named: "Mix", in: fake.root)
        _ = try drive.createFolder(named: "Sample Music", in: target)
        let plan = try drive.planMove([fake.url("Sample Music")], into: target)
        #expect(plan.moves.isEmpty)
    }

    @Test func anUnreadableDestinationIsNeverTakenAsFree() throws {
        let missing = fake.url("Gone")  // can't be listed
        #expect(throws: OrganizeError.unreadable("Gone")) { try HAPDrive.existingName("x", in: missing) }
    }

    @Test func hiddenFolderNamesAreRefused() throws {
        #expect(throws: OrganizeError.hiddenName) { try drive.createFolder(named: "._x", in: fake.root) }
    }

    @Test func aSimilarlyNamedMountIsNotThisDrive() throws {
        let other = URL(fileURLWithPath: fake.root.path + "-1/Music/a.flac")
        #expect(drive.relativePath(of: other) == other.path)
    }

    @Test func aDestinationOffThePlannedDriveIsRefused() throws {
        var plan = UploadPlan()
        plan.items = [UploadItem(source: fake.url("Sample Music/Miles Davis - So What.dsf"),
                                 destination: URL(fileURLWithPath: fake.root.path + "-1/x.dsf"), size: 1)]
        let session = UploadSession(drive: drive, stallLimit: 30) { $0 }
        #expect(throws: (any Error).self) { try session.upload(plan) }
    }
}
