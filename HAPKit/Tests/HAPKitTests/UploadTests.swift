import Foundation
import Testing
@testable import HAPKit

/// A pretend music folder on the Mac, to drop onto the pretend drive.
struct FakeSource {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeSource-\(UUID().uuidString)")
        let files: [(String, Int)] = [
            ("Kind of Blue/01 So What.flac", 3_000_000),
            ("Kind of Blue/02 Freddie Freeloader.flac", 2_500_000),
            ("Kind of Blue/cover.jpg", 1_000),
            ("Kind of Blue/.DS_Store", 100),
            ("Kind of Blue/Bonus/03 What: A \"Test\"?.wav", 1_200_000),
            ("Single.mp3", 500_000),
            ("notes.txt", 10),
        ]
        for (path, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data(count: size)
            for i in stride(from: 0, to: size, by: 997) { data[i] = UInt8(truncatingIfNeeded: i ^ size) }
            try data.write(to: url)
        }
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct UploadTests {
    let music: Set<String> = HAPDrive.extensions(fromSupportedTypes: ["*.flac", "*.wav", "*.mp3", "*.dsf"])

    @Test func safeNames() {
        #expect(HAPDrive.safeName("What: A \"Test\"?.wav") == "What_ A _Test__.wav")
        #expect(HAPDrive.safeName("Ends with dot.") == "Ends with dot")
        #expect(HAPDrive.safeName("Niña de Fuego") == "Niña de Fuego")
    }

    @Test func planKeepsFolderStructureAndOnlyMusic() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let target = drive.url("OTHER-PC")
        let plan = try drive.drive.planUpload([source.url("Kind of Blue"), source.url("Single.mp3"), source.url("notes.txt")],
                                              into: target, allowedExtensions: music)
        #expect(plan.items.map { drive.drive.relativePath(of: $0.destination) } == [
            "OTHER-PC/Kind of Blue/01 So What.flac",
            "OTHER-PC/Kind of Blue/02 Freddie Freeloader.flac",
            "OTHER-PC/Kind of Blue/Bonus/03 What_ A _Test__.wav",
            "OTHER-PC/Single.mp3",
        ])
        #expect(plan.skipped.map(\.source.lastPathComponent).sorted() == ["cover.jpg", "notes.txt"])  // .DS_Store silently
        #expect(plan.totalBytes == 3_000_000 + 2_500_000 + 1_200_000 + 500_000)
    }

    @Test func existingFilesAreSkippedNotOverwritten() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let existing = drive.url("OTHER-PC/Users/someone/Desktop/Demo/02 Black Nights.wav")
        let before = try Data(contentsOf: existing)
        // A Mac file with the same name as one already on the player:
        let clash = source.url("02 Black Nights.wav")
        try Data(repeating: 9, count: 1234).write(to: clash)
        let plan = try drive.drive.planUpload([clash], into: existing.deletingLastPathComponent(), allowedExtensions: music)
        #expect(plan.items.isEmpty)
        #expect(plan.skipped.first?.reason == "a different file with the same name is on the player")
        try drive.drive.upload(plan)
        #expect(try Data(contentsOf: existing) == before)
    }

    @Test func refusesLostFoundAndOutside() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        #expect(throws: UploadError.self) {
            try drive.drive.planUpload([source.url("Single.mp3")], into: drive.url("lost+found"), allowedExtensions: music)
        }
        #expect(throws: UploadError.self) {
            try drive.drive.planUpload([source.url("Single.mp3")], into: drive.url("lost+found/deeper"), allowedExtensions: music)
        }
        #expect(throws: UploadError.self) {
            try drive.drive.planUpload([source.url("Single.mp3")], into: source.root, allowedExtensions: music)
        }
        // The drive's top level is fine.
        #expect(try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music).items.count == 1)
    }

    @Test func uploadCopiesExactlyAndReportsProgress() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Kind of Blue")], into: drive.url("Sample Music"), allowedExtensions: music)
        let last = LastProgress()
        try drive.drive.upload(plan) { last.value = $0 }
        for item in plan.items {
            #expect(try Data(contentsOf: item.destination) == Data(contentsOf: item.source))
        }
        #expect(last.value.filesDone == 3)
        #expect(last.value.bytesDone == plan.totalBytes)
        #expect(!drive.exists("Sample Music/Kind of Blue/.DS_Store"))
        #expect(!drive.exists("Sample Music/Kind of Blue/cover.jpg"))
    }

    @Test func stoppingRemovesOnlyThePartialCopy() async throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Kind of Blue")], into: drive.url("Sample Music"), allowedExtensions: music)
        let d = drive.drive
        let task = Task {
            // Press Stop during the first file.
            try d.upload(plan) { p in if p.filesDone == 0 && p.bytesDone > 0 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: plan.items[0].destination.path))  // partial copy removed
        #expect(drive.exists("Sample Music/Miles Davis - So What.dsf"))                  // existing music untouched
    }
}

final class LastProgress: @unchecked Sendable { var value = UploadProgress() }
