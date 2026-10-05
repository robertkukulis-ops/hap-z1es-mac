import Foundation

/// Uploads that survive the player's flaky SMB server.
///
/// The player drops the connection shortly after files are written/closed (NOTES.md), and a
/// copy in progress can then hang in macOS's SMB client forever. So a session:
/// - reconnects to the drive **after every file**, so the next file starts on a fresh connection;
/// - runs a **watchdog**: no progress for `stallLimit` → force-disconnect (this makes the stuck
///   write fail instead of hanging) → reconnect → retry the file (up to `maxAttempts`);
/// - **resumes**: a file already on the player with the same size and fingerprint counts as done.
/// Before a retry it removes only the partial copy its own previous attempt created.
public final class UploadSession: @unchecked Sendable {
    public static let stallLimit: TimeInterval = 30
    public static let maxAttempts = 3

    private let lock = NSLock()
    private var current: HAPDrive
    private let reconnectDrive: @Sendable (HAPDrive) throws -> HAPDrive
    private let stallLimit: TimeInterval
    /// Test hook: runs before each copy attempt (file, attempt number).
    var beforeCopy: (@Sendable (UploadItem, Int) throws -> Void)?
    /// How many times the session reconnected (for the result message and tests).
    public private(set) var reconnects = 0
    public private(set) var retries = 0

    /// The drive as currently connected (its folder on the Mac can change after a reconnect).
    public var drive: HAPDrive { lock.withLock { current } }

    public convenience init(host: String, drive: HAPDrive, share: String = HAPDrive.shareName) {
        self.init(hosts: [host], drive: drive, share: share)
    }

    /// `hosts`: ways to reach the player, tried in order (e.g. "HAP-Z1ES", then its address).
    public convenience init(hosts: [String], drive: HAPDrive, share: String = HAPDrive.shareName) {
        self.init(drive: drive, stallLimit: Self.stallLimit) { old in
            _ = unmount(old.root.path, 0) == 0 || unmount(old.root.path, MNT_FORCE) == 0
            var lastError: Error = HAPError.network("could not reconnect to the drive")
            for _ in 0..<5 {
                do {
                    let fresh = try HAPDrive.mount(hosts: hosts, share: share)
                    // If the old mount couldn't be disconnected above, tidy it up now.
                    HAPDrive.removeDuplicateMounts(hosts: hosts, share: share, keeping: fresh.root)
                    return fresh
                } catch { lastError = error }
                Thread.sleep(forTimeInterval: 2)
            }
            throw lastError
        }
    }

    init(drive: HAPDrive, stallLimit: TimeInterval, reconnect: @escaping @Sendable (HAPDrive) throws -> HAPDrive) {
        self.current = drive
        self.stallLimit = stallLimit
        self.reconnectDrive = reconnect
    }

    private func reconnect() throws {
        let old = drive
        let fresh = try reconnectDrive(old)
        lock.withLock {
            current = fresh
            reconnects += 1
        }
    }

    /// Temporary copies that couldn't be removed yet (the player may still hold them open for a
    /// dropped connection). They're hidden `.part` files, which the player ignores, and are
    /// cleaned up on the next upload into the same folder.
    public private(set) var leftoverTemporaryFiles = 0

    /// Copies the planned files (the plan may have been made with an older connection).
    /// Each file is copied under a hidden temporary name and renamed to its real name only
    /// after it has been checked, so a failed attempt never blocks or half-fills the real name.
    public func upload(_ plan: UploadPlan, progress: @Sendable (UploadProgress) -> Void = { _ in }) throws {
        let planned = drive
        var leftovers: [String] = []
        // Our own leftovers from earlier uploads into these folders.
        let folders = Set(plan.items.map { planned.relativePath(of: $0.destination.deletingLastPathComponent()) })
        for folder in folders { HAPDrive.removeTemporaryCopies(in: planned.root.appendingPathComponent(folder)) }

        var state = UploadProgress()
        for (index, item) in plan.items.enumerated() {
            let relative = planned.relativePath(of: item.destination)
            state.currentName = item.source.lastPathComponent
            progress(state)
            var attempt = 0
            attempts: while true {
                attempt += 1
                if Task.isCancelled { throw CancellationError() }
                let drive = self.drive
                let target = UploadItem(source: item.source,
                                        destination: drive.root.appendingPathComponent(relative),
                                        size: item.size)
                let temporary = HAPDrive.temporaryURL(for: target.destination)
                let watchdog = Watchdog(limit: stallLimit) { _ = unmount(drive.root.path, MNT_FORCE) }
                do {
                    defer { watchdog.stop() }
                    if let existing = HAPDrive.fileSize(target.destination) {
                        if HAPDrive.sameContent(item.source, target.destination, size: item.size) {
                            break attempts  // already there, complete (resume)
                        }
                        guard existing == 0 else {
                            throw UploadError.differentFileExists(item.source.lastPathComponent)
                        }
                        // An empty file can't be music: a leftover from an interrupted copy.
                        try FileManager.default.removeItem(at: target.destination)
                    }
                    try beforeCopy?(UploadItem(source: item.source, destination: temporary, size: item.size), attempt)
                    let before = state
                    try drive.copyAndCheck(target, via: temporary) { bytes in
                        watchdog.touch()
                        var now = before
                        now.bytesDone += bytes
                        progress(now)
                    }
                    break attempts
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: temporary)
                    throw CancellationError()
                } catch UploadError.differentFileExists(let name) {
                    throw UploadError.differentFileExists(name)  // not ours: never touched, never retried
                } catch {
                    if (try? FileManager.default.removeItem(at: temporary)) == nil, HAPDrive.fileSize(temporary) != nil {
                        leftovers.append(drive.relativePath(of: temporary))
                    }
                    guard attempt < Self.maxAttempts else { throw error }
                    lock.withLock { retries += 1 }
                    try reconnect()
                }
            }
            state.filesDone += 1
            state.bytesDone += item.size
            progress(state)
            // A fresh connection for the next file: the player tends to drop the old one
            // shortly after a file is closed.
            if index < plan.items.count - 1 { try? reconnect() }
        }
        // Try once more to tidy up temporary copies from failed attempts.
        let root = drive.root
        let remaining = leftovers.filter { (try? FileManager.default.removeItem(at: root.appendingPathComponent($0))) == nil }
        lock.withLock { leftoverTemporaryFiles = remaining.count }
    }
}

extension HAPDrive {
    /// Hidden name for a copy in progress, next to its final place: ".hap-upload-1A2B3C4D.part".
    /// The player ignores it (not a music file type) and it never clashes with a real name.
    static func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".hap-upload-\(UUID().uuidString.prefix(8)).part")
    }

    static func isTemporaryCopy(_ name: String) -> Bool {
        name.hasPrefix(".hap-upload-") && name.hasSuffix(".part")
    }

    /// Removes our own temporary copies left in a folder by earlier, interrupted uploads.
    static func removeTemporaryCopies(in folder: URL) {
        guard let names = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) else { return }
        for name in names where !name.contains("/") && isTemporaryCopy(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Copies one file under a temporary name, checks it, keeps its date, then renames it to its
    /// real name, never over an existing file.
    func copyAndCheck(_ item: UploadItem, via temporary: URL? = nil, progress: (Int64) -> Void) throws {
        try checkUploadTarget(item.destination.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = temporary ?? Self.temporaryURL(for: item.destination)
        try copyNewFile(UploadItem(source: item.source, destination: temporary, size: item.size), progress: progress)
        guard Self.sameContent(item.source, temporary, size: item.size) else {
            try? FileManager.default.removeItem(at: temporary)  // our own bad copy
            throw UploadError.checkFailed(item.source.lastPathComponent)
        }
        if let date = try? item.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        }
        if FileManager.default.fileExists(atPath: item.destination.path) {
            try? FileManager.default.removeItem(at: temporary)
            throw UploadError.differentFileExists(item.source.lastPathComponent)
        }
        try FileManager.default.moveItem(at: temporary, to: item.destination)  // fails if the name is taken
        Self.dropMacLabels(item.destination)
    }

    /// macOS labels every file an app creates ("com.apple.provenance"); the player's drive can't
    /// store such labels, so macOS keeps them in a hidden `._` companion file. Removing the label
    /// lets macOS drop the companion, keeping the player's folders clean. Best effort.
    static func dropMacLabels(_ url: URL) {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) > 0 else { return }
        let names = buffer.split(separator: 0).map { String(decoding: $0.map(UInt8.init), as: UTF8.self) }
        for name in names { removexattr(url.path, name, XATTR_NOFOLLOW) }
    }
}

/// Calls `onStall` once if `touch()` isn't called for `limit` seconds.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var stopped = false
    private(set) var fired = false

    init(limit: TimeInterval, onStall: @escaping @Sendable () -> Void) {
        let thread = Thread { [weak self] in
            while let self, !self.isStopped {
                Thread.sleep(forTimeInterval: 1)
                if self.lock.withLock({ !self.stopped && !self.fired && Date().timeIntervalSince(self.last) > limit }) {
                    self.lock.withLock { self.fired = true }
                    onStall()
                }
            }
        }
        thread.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }
    func touch() { lock.withLock { last = Date() } }
    func stop() { lock.withLock { stopped = true } }
}
