import CryptoKit
import Foundation

// Copying music from the Mac to the player's drive (drag and drop in the app).
//
// Safety (CLAUDE.md): the app copies only what the user dropped and confirmed. Nothing on the
// player is ever overwritten: new files are created with O_EXCL ("only if it doesn't exist").
// The only thing ever removed is a partial copy this code itself just created (after Stop or
// a failed check).

/// One file to copy.
public struct UploadItem: Sendable, Equatable, Identifiable {
    public let source: URL
    public let destination: URL
    public let size: Int64
    public var id: URL { destination }
}

/// Something that won't be copied, and why.
public struct UploadSkip: Sendable, Equatable {
    public let source: URL
    public let reason: String
}

/// What a drop would do: shown to the user before anything is copied.
public struct UploadPlan: Sendable, Equatable {
    public var items: [UploadItem] = []
    public var skipped: [UploadSkip] = []
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct UploadProgress: Sendable, Equatable {
    public var filesDone = 0
    public var bytesDone: Int64 = 0
    public var currentName = ""

    public init() {}
}

public enum UploadError: Error, LocalizedError, Equatable {
    case protectedTarget(String)
    case outsideDrive(String)
    case copyFailed(String, String)
    case checkFailed(String)
    case differentFileExists(String)

    public var errorDescription: String? {
        switch self {
        case .protectedTarget(let path): "Can't copy into \(path): it's a protected folder."
        case .outsideDrive(let path): "Can't copy to \(path): it's not on the player's drive."
        case .copyFailed(let name, let why): "Copying “\(name)” failed: \(why)"
        case .checkFailed(let name): "The copy of “\(name)” doesn't match the original; it was removed."
        case .differentFileExists(let name): "A different file called “\(name)” is already on the player; it was left alone."
        }
    }
}

extension HAPDrive {
    /// Characters the player (and Sony's app) don't allow in names become "_".
    public static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var result = String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        return result.isEmpty ? "_" : result
    }

    /// File types the player plays, from its `getSupportedFileType` answer ("*.flac" → "flac").
    public static func extensions(fromSupportedTypes types: [String]) -> Set<String> {
        Set(types.map { $0.replacingOccurrences(of: "*.", with: "").lowercased() })
    }

    /// Drops are allowed anywhere on the drive except lost+found (and inside it).
    public func checkUploadTarget(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else {
            throw UploadError.outsideDrive(path)
        }
        let first = relativePath(of: folder).split(separator: "/").first.map(String.init) ?? ""
        if first.lowercased() == "lost+found" { throw UploadError.protectedTarget("lost+found") }
    }

    /// Works out what dropping `sources` into `folder` would copy, without copying anything.
    /// Folders are copied with their structure; only music the player can play is included.
    public func planUpload(_ sources: [URL], into folder: URL, allowedExtensions: Set<String>) throws -> UploadPlan {
        try checkUploadTarget(folder)
        var plan = UploadPlan()
        var taken = Set<String>()

        func consider(_ file: URL, destination: URL) {
            let name = file.lastPathComponent
            if Self.isJunk(name) || name.hasPrefix(".") { return }  // Mac leftovers and hidden files
            guard allowedExtensions.contains(file.pathExtension.lowercased()) else {
                plan.skipped.append(UploadSkip(source: file, reason: "not a music file the player plays"))
                return
            }
            let key = destination.path.lowercased()
            if taken.contains(key) {
                plan.skipped.append(UploadSkip(source: file, reason: "another dropped file has the same name"))
                return
            }
            if let existing = Self.fileSize(destination), existing > 0 {  // empty = leftover, replaced
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                plan.skipped.append(UploadSkip(source: file, reason: Self.sameContent(file, destination, size: size)
                    ? "already on the player"
                    : "a different file with the same name is on the player"))
                return
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            taken.insert(key)
            plan.items.append(UploadItem(source: file, destination: destination, size: size))
        }

        for source in sources {
            if source.standardizedFileURL.path.hasPrefix(root.path + "/") {
                plan.skipped.append(UploadSkip(source: source, reason: "it's already on the player"))
                continue
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                consider(source, destination: folder.appendingPathComponent(Self.safeName(source.lastPathComponent)))
                continue
            }
            let top = folder.appendingPathComponent(Self.safeName(source.lastPathComponent), isDirectory: true)
            let walker = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                let relative = file.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count)
                var destination = top
                for part in relative.split(separator: "/") {
                    destination.appendPathComponent(Self.safeName(String(part)))
                }
                consider(file, destination: destination)
            }
        }
        plan.items.sort { $0.destination.path.localizedStandardCompare($1.destination.path) == .orderedAscending }
        return plan
    }

    /// Copies the planned files, never overwriting. Each copy is checked (size, and a fingerprint
    /// of its first and last megabyte). Stops early if the task is cancelled.
    /// Simple upload without reconnects (used by tests); the app uses `UploadSession`.
    public func upload(_ plan: UploadPlan, progress: @Sendable (UploadProgress) -> Void = { _ in }) throws {
        var state = UploadProgress()
        for item in plan.items {
            if Task.isCancelled { throw CancellationError() }
            state.currentName = item.source.lastPathComponent
            progress(state)
            let before = state
            try copyAndCheck(item) { bytes in
                var now = before
                now.bytesDone += bytes
                progress(now)
            }
            state.filesDone += 1
            state.bytesDone += item.size
            progress(state)
        }
    }

    /// Copies the data only (no Mac metadata, so no `._` files on the player) into a file that
    /// must not exist yet.
    func copyNewFile(_ item: UploadItem, progress: (Int64) -> Void) throws {
        let name = item.source.lastPathComponent
        let input = open(item.source.path, O_RDONLY)
        guard input >= 0 else { throw UploadError.copyFailed(name, String(cString: strerror(errno))) }
        defer { close(input) }
        let output = open(item.destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else {
            let why = errno == EEXIST ? "a file with that name is already on the player" : String(cString: strerror(errno))
            throw UploadError.copyFailed(name, why)
        }
        var finished = false
        defer {
            _ = close(output)  // the player's SMB server can make close() fail harmlessly; the copy is checked
            if !finished { unlink(item.destination.path) }  // remove only our own partial copy
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var copied: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = read(input, &buffer, buffer.count)
            if count < 0 { throw UploadError.copyFailed(name, String(cString: strerror(errno))) }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(output, $0.baseAddress! + offset, count - offset) }
                if written < 0 { throw UploadError.copyFailed(name, String(cString: strerror(errno))) }
                offset += written
            }
            copied += Int64(count)
            progress(copied)
        }
        fsync(output)
        finished = true
    }

    /// Same size, and the same fingerprint of the first and last megabyte.
    static func sameContent(_ a: URL, _ b: URL, size: Int64) -> Bool {
        guard let sizeB = (try? FileManager.default.attributesOfItem(atPath: b.path))?[.size] as? NSNumber,
              sizeB.int64Value == size else { return false }
        return sample(a, size: size) == sample(b, size: size)
    }

    private static func sample(_ url: URL, size: Int64) -> SHA256.Digest? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        for start in [Int64(0), max(0, size - Int64(chunk))] {
            let count = pread(fd, &buffer, chunk, off_t(start))
            guard count >= 0 else { return nil }
            hasher.update(data: buffer[0..<count])
        }
        return hasher.finalize()
    }
}
