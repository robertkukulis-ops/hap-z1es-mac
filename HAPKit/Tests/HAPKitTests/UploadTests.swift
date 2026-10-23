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

@Suite struct CueUploadTests {
    let music: Set<String> = HAPDrive.extensions(fromSupportedTypes: ["*.flac", "*.wav", "*.mp3", "*.m4a"])

    private func source(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CueUpload-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func cue(_ file: String) -> String {
        "TITLE \"Album\"\nFILE \"\(file)\" WAVE\n TRACK 01 AUDIO\n  TITLE \"One\"\n  INDEX 01 00:00:00\n TRACK 02 AUDIO\n  TITLE \"Two\"\n  INDEX 01 01:00:00\n"
    }

    @Test func cueAlbumIsPlannedForSplitting() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let src = try source(["Live/Album.cue": cue("Album.flac"), "Live/Album.flac": "x", "Live/05 Bonus.flac": "y", "Live/cover.jpg": "z"])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("Live")], into: drive.url("Sample Music"), allowedExtensions: music)
        #expect(plan.albumsToSplit.count == 1)
        #expect(plan.albumsToSplit.first.map { drive.drive.relativePath(of: $0.destinationFolder) } == "Sample Music/Live")
        #expect(plan.items.map(\.destination.lastPathComponent) == ["05 Bonus.flac"])  // not the big file
        #expect(!plan.skipped.contains { $0.source.lastPathComponent == "Album.cue" })
        #expect(plan.skipped.contains { $0.source.lastPathComponent == "cover.jpg" })   // as usual: music only
    }

    @Test func twoCueAlbumsInOneFolderBothSplit() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let src = try source(["Box/A.cue": cue("A.flac"), "Box/A.flac": "x", "Box/B.cue": cue("B.wav"), "Box/B.wav": "y"])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("Box")], into: drive.url("Sample Music"), allowedExtensions: music)
        #expect(plan.albumsToSplit.map { drive.drive.relativePath(of: $0.destinationFolder) } == ["Sample Music/Box/A", "Sample Music/Box/B"])
        #expect(plan.items.isEmpty)
    }

    @Test func unsupportedCueAlbumIsCopiedWhole() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let src = try source(["X/X.cue": cue("X.m4a"), "X/X.m4a": "x"])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("X")], into: drive.url("Sample Music"), allowedExtensions: music)
        #expect(plan.albumsToSplit.isEmpty)
        #expect(plan.items.map(\.destination.lastPathComponent) == ["X.m4a"])
        #expect(plan.skipped.contains { $0.source.lastPathComponent == "X.cue" && $0.reason.contains("copied as one file") })
    }

    @Test func looseCueAndAudioFilesAreSplitToo() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let src = try source(["Album.cue": cue("Album.flac"), "Album.flac": "x"])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("Album.cue"), src.appendingPathComponent("Album.flac")],
                                              into: drive.url("Sample Music"), allowedExtensions: music)
        #expect(plan.albumsToSplit.map { drive.drive.relativePath(of: $0.destinationFolder) } == ["Sample Music"])
        #expect(plan.items.isEmpty)
    }

    @Test func songsAlreadyOnThePlayerAreSkipped() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let folder = drive.url("Sample Music")
        try Data("old".utf8).write(to: folder.appendingPathComponent("01 - One.flac"))
        let songs = try source(["01 - One.flac": "a", "02 - Two.flac": "b"])
        let plan = drive.drive.plan(songs: [songs.appendingPathComponent("01 - One.flac"), songs.appendingPathComponent("02 - Two.flac")], into: folder)
        #expect(plan.items.map(\.destination.lastPathComponent) == ["02 - Two.flac"])
        #expect(plan.skipped.count == 1)
    }
}

extension CueUploadTests {
    @Test func aCueDroppedNextToItsAlbumOnThePlayerIsCopied() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let folder = drive.url("Sample Music")
        try Data("big".utf8).write(to: folder.appendingPathComponent("Album.flac"))  // already on the player
        let src = try source(["Album.cue": cue("Album.flac")])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("Album.cue")], into: folder, allowedExtensions: music)
        #expect(plan.items.map(\.destination.lastPathComponent) == ["Album.cue"])
        #expect(plan.albumsToSplit.isEmpty)
    }

    @Test func aCueWithoutItsAlbumIsStillSkipped() throws {
        let drive = try FakeDrive(); defer { drive.remove() }
        let src = try source(["Album.cue": cue("Album.flac")])
        let plan = try drive.drive.planUpload([src.appendingPathComponent("Album.cue")], into: drive.url("Sample Music"), allowedExtensions: music)
        #expect(plan.items.isEmpty)
    }
}
