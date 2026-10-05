import Foundation
import Testing
@testable import HAPKit

@Suite struct UploadSessionTests {
    let music: Set<String> = ["flac", "wav", "mp3"]

    func session(_ drive: HAPDrive, counter: Counter) -> UploadSession {
        UploadSession(drive: drive, stallLimit: 30) { old in counter.last += 1; return old }  // "reconnect" = same folder
    }

    @Test func aFailedAttemptIsRetriedAndItsPartialCopyReplaced() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music)
        let reconnects = Counter()
        let s = session(drive.drive, counter: reconnects)
        s.beforeCopy = { item, attempt in
            // `item.destination` is the hidden temporary copy of this attempt.
            #expect(HAPDrive.isTemporaryCopy(item.destination.lastPathComponent))
            if attempt == 1 {  // the connection "drops" mid-copy, leaving a partial file behind
                try Data(repeating: 7, count: 1000).write(to: item.destination)
                throw UploadError.copyFailed("Single.mp3", "Device not configured")
            }
        }
        try s.upload(plan)
        #expect(try Data(contentsOf: drive.url("Single.mp3")) == Data(contentsOf: source.url("Single.mp3")))
        #expect(s.retries == 1)
        #expect(reconnects.last >= 1)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: drive.root.path).filter(HAPDrive.isTemporaryCopy)
        #expect(hidden.isEmpty)  // the failed attempt's partial copy was removed
    }

    @Test func anEmptyLeftoverIsReplaced() throws {
        // What happened on 2026-09-28: "14. Perfect Picture.flac" was left at 0 KB.
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music)
        FileManager.default.createFile(atPath: plan.items[0].destination.path, contents: Data())
        try session(drive.drive, counter: Counter()).upload(plan)
        #expect(try Data(contentsOf: drive.url("Single.mp3")) == Data(contentsOf: source.url("Single.mp3")))
    }

    @Test func oldTemporaryCopiesAreCleanedUp() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        try Data(repeating: 5, count: 99).write(to: drive.url(".hap-upload-DEADBEEF.part"))
        let plan = try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music)
        try session(drive.drive, counter: Counter()).upload(plan)
        #expect(!drive.exists(".hap-upload-DEADBEEF.part"))
    }

    @Test func givesUpAfterThreeAttempts() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music)
        let s = session(drive.drive, counter: Counter())
        s.beforeCopy = { _, _ in throw UploadError.copyFailed("Single.mp3", "Device not configured") }
        #expect(throws: UploadError.self) { try s.upload(plan) }
        #expect(s.retries == UploadSession.maxAttempts - 1)
    }

    @Test func completeFilesAreSkippedOnResume() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Kind of Blue")], into: drive.root, allowedExtensions: music)
        // The first file made it last time.
        try FileManager.default.createDirectory(at: plan.items[0].destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: plan.items[0].source, to: plan.items[0].destination)
        let copied = Counter()
        let s = session(drive.drive, counter: Counter())
        s.beforeCopy = { _, _ in copied.last += 1 }
        try s.upload(plan)
        #expect(copied.last == plan.items.count - 1)
        for item in plan.items { #expect(try Data(contentsOf: item.destination) == Data(contentsOf: item.source)) }
    }

    @Test func aDifferentFileWithTheSameNameIsNeverTouched() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        let plan = try drive.drive.planUpload([source.url("Single.mp3")], into: drive.root, allowedExtensions: music)
        // Someone else's file appears with that name after planning.
        try Data(repeating: 1, count: 42).write(to: plan.items[0].destination)
        let s = session(drive.drive, counter: Counter())
        #expect(throws: UploadError.differentFileExists("Single.mp3")) { try s.upload(plan) }
        #expect(try Data(contentsOf: plan.items[0].destination) == Data(repeating: 1, count: 42))
        #expect(s.retries == 0)
    }

    @Test func planTellsIdenticalFromDifferentExistingFiles() throws {
        let drive = try FakeDrive(), source = try FakeSource()
        defer { drive.remove(); source.remove() }
        try FileManager.default.copyItem(at: source.url("Single.mp3"), to: drive.url("Single.mp3"))
        try Data(repeating: 3, count: 10).write(to: drive.url("notes.mp3"))
        try Data(repeating: 4, count: 10).write(to: source.url("notes.mp3"))
        let plan = try drive.drive.planUpload([source.url("Single.mp3"), source.url("notes.mp3")], into: drive.root, allowedExtensions: music)
        #expect(plan.items.isEmpty)
        #expect(Set(plan.skipped.map(\.reason)) == ["already on the player", "a different file with the same name is on the player"])
    }

    @Test func watchdogFiresOnlyWithoutProgress() throws {
        let fired = Counter(), quiet = Counter()
        let stalled = Watchdog(limit: 1) { fired.last += 1 }
        let busy = Watchdog(limit: 1) { quiet.last += 1 }
        for _ in 0..<5 { busy.touch(); Thread.sleep(forTimeInterval: 0.5) }
        stalled.stop(); busy.stop()
        #expect(fired.last == 1)
        #expect(quiet.last == 0)
    }
}
