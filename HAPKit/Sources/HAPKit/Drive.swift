import Foundation
import NetFS

// The player's music drive, reached over SMB file sharing (share "HAP_Internal").
// Needs the Mac-side setting ~/Library/Preferences/nsmb.conf with protocol_vers_map=1 (SMB1; see README)
// (this player hangs up on the Mac's SMB 3.1.1 greeting, NOTES.md).
//
// Safety (CLAUDE.md): the app may delete files only when the user selects them and confirms.
// `delete(_:)` is the only function here that changes anything, and it refuses anything
// outside the drive, the drive's top level itself, and lost+found.

/// A file or folder on the player's drive.
public struct DriveItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isFolder: Bool
    /// Size in bytes for files (folders: see `HAPDrive.summary(of:)`).
    public let size: Int64?
    public let modified: Date?

    public var id: URL { url }
}

/// What a folder (or a selection) contains, counted recursively.
public struct DriveSummary: Sendable, Equatable {
    /// Every file, including Mac leftovers: exactly what a deletion would remove.
    public var files = 0
    /// Hidden Mac leftovers (._* and .DS_Store) included in `files`.
    public var junkFiles = 0
}

public struct HAPDrive: Sendable {
    /// Where the share is mounted on this Mac, e.g. /Volumes/HAP_Internal.
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static let shareName = "HAP_Internal"

    /// Uses an existing writable connection to the share, or connects like Finder does
    /// (as guest, hidden from the Finder sidebar).
    public static func connect(host: String, share: String = shareName) async throws -> HAPDrive {
        try await connect(hosts: [host], share: share)
    }

    /// Tries each way of reaching the player in order, e.g. its network name "HAP-Z1ES" first
    /// (the per-player SMB1 setting in ~/Library/Preferences/nsmb.conf is keyed on it, and it
    /// survives address changes), then its address as a fallback.
    public static func connect(hosts: [String], share: String = shareName) async throws -> HAPDrive {
        if let existing = existingMount(hosts: hosts, share: share) { return HAPDrive(root: existing) }
        return try await Task.detached { try mount(hosts: hosts, share: share) }.value
    }

    static func mount(hosts: [String], share: String) throws -> HAPDrive {
        var lastError: Error = HAPError.network("no way to reach the drive")
        for host in hosts where !host.isEmpty {
            do { return try mount(host: host, share: share) } catch { lastError = error }
        }
        throw lastError
    }

    static func existingMount(hosts: [String], share: String) -> URL? {
        for host in hosts where !host.isEmpty {
            if let found = existingMount(host: host, share: share) { return found }
        }
        return nil
    }

    static func existingMount(host: String, share: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsReadOnlyKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsReadOnly != true,
                  let remote = values.volumeURLForRemounting,
                  remote.scheme?.lowercased() == "smb",
                  remote.host?.lowercased() == host.lowercased(),
                  remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == share.lowercased()
            else { continue }
            return volume
        }
        return nil
    }

    /// A mounted volume as macOS describes it (used to find extra mounts of the player's drive).
    struct MountedVolume {
        let url: URL
        let remote: URL?
        let readOnly: Bool
    }

    /// Other writable mounts of this drive besides `keeping`. They pile up when a reconnect
    /// can't disconnect the old mount first (e.g. during a stalled upload): "HAP_Internal-1"…
    static func duplicateMounts(in volumes: [MountedVolume], hosts: [String], share: String, keeping: URL) -> [URL] {
        let wantedHosts = Set(hosts.map { $0.lowercased() })
        return volumes.filter { volume in
            guard !volume.readOnly, let remote = volume.remote, remote.scheme?.lowercased() == "smb",
                  let host = remote.host?.lowercased(), wantedHosts.contains(host),
                  remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == share.lowercased()
            else { return false }
            return volume.url.standardizedFileURL.path != keeping.standardizedFileURL.path
        }.map(\.url)
    }

    /// Gently disconnects extra mounts of the drive (a busy one is left alone; disconnecting
    /// never touches the files on the player). Returns how many were disconnected.
    @discardableResult
    public static func removeDuplicateMounts(hosts: [String], share: String = shareName, keeping: URL) -> Int {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsReadOnlyKey]
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return MountedVolume(url: url, remote: values?.volumeURLForRemounting, readOnly: values?.volumeIsReadOnly == true)
        }
        return duplicateMounts(in: volumes, hosts: hosts, share: share, keeping: keeping)
            .filter { unmount($0.path, 0) == 0 }.count
    }

    static func mount(host: String, share: String) throws -> HAPDrive {
        guard let url = URL(string: "smb://\(host)/\(share)") else {
            throw HAPError.network("bad drive address")
        }
        let openOptions = NSMutableDictionary()
        openOptions[kNetFSUseGuestKey] = true
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountFlagsKey] = MNT_DONTBROWSE
        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &mountPoints)
        if status == EEXIST, let existing = existingMount(host: host, share: share) {
            return HAPDrive(root: existing)
        }
        guard status == 0,
              let path = (mountPoints?.takeRetainedValue() as? [String])?.first
        else {
            throw HAPError.network("could not connect to the music drive (error \(status)). "
                + "Check ~/Library/Preferences/nsmb.conf (protocol_vers_map=1, see the README).")
        }
        return HAPDrive(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: - Reading

    /// Mac leftovers inside `folder` and all its subfolders: `._` files, `.DS_Store`, and our own
    /// hidden upload leftovers (`.hap-upload-….part`). Never looks inside lost+found. Reads only
    /// folder listings (fast over SMB).
    public func macLeftovers(in folder: URL) -> [URL] {
        var found: [URL] = []
        func visit(_ path: String) {
            guard let dir = opendir(path) else { return }
            var entries: [(String, Bool)] = []
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                if name != "." && name != ".." { entries.append((name, entry.pointee.d_type == DT_DIR)) }
            }
            closedir(dir)
            for (name, isFolder) in entries {
                let child = (path as NSString).appendingPathComponent(name)
                if isFolder {
                    if name.lowercased() == "lost+found" { continue }
                    visit(child)
                } else if Self.isJunk(name) || Self.isTemporaryCopy(name) {
                    found.append(URL(fileURLWithPath: child))
                }
            }
        }
        visit(folder.path)
        return found.sorted { $0.path < $1.path }
    }

    /// Mac leftovers the player never needs: `._name` companion files and `.DS_Store`.
    public static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store"
    }

    /// The folders and files inside `folder`, folders first, without Mac junk.
    public func items(in folder: URL) throws -> [DriveItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [])
        return urls.compactMap { url -> DriveItem? in
            let name = url.lastPathComponent
            guard !Self.isJunk(name), !Self.isTemporaryCopy(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory ?? false
            return DriveItem(url: url, name: name, isFolder: isFolder,
                             size: isFolder ? nil : values?.fileSize.map(Int64.init),
                             modified: values?.contentModificationDate)
        }
        .sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Counts every file inside (recursively), including Mac junk, so the number matches
    /// exactly what a deletion would remove. Reads only the folder listings (names and
    /// file-or-folder), which is fast over SMB: ~1 s for 1,876 files. Asking each file's
    /// size separately took 2 minutes (NOTES.md). Apple's URL-based listings skip `._`
    /// files, so this uses the plain directory listing.
    public func count(_ urls: [URL]) -> DriveSummary {
        var summary = DriveSummary()
        func visit(_ path: String) {
            guard let dir = opendir(path) else { return }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                if name == "." || name == ".." { continue }
                let child = (path as NSString).appendingPathComponent(name)
                if entry.pointee.d_type == DT_DIR {
                    visit(child)
                } else {
                    summary.files += 1
                    if Self.isJunk(name) { summary.junkFiles += 1 }
                }
            }
        }
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                visit(url.path)
            } else {
                summary.files += 1
                if Self.isJunk(url.lastPathComponent) { summary.junkFiles += 1 }
            }
        }
        return summary
    }

    /// Total size of the music files inside (Mac leftovers are a few KB each and not counted).
    /// Slow over SMB (~40 s for the 9 GB Logic folder), so run it in the background.
    public func size(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
                while let child = walker?.nextObject() as? URL {
                    if Task.isCancelled { return total }
                    let childValues = try? child.resourceValues(forKeys: Set(keys))
                    if childValues?.isDirectory != true { total += Int64(childValues?.fileSize ?? 0) }
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Path inside the drive, e.g. "My Mac/Users/me/Music/Logic".
    public func relativePath(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        guard full == root.path || full.hasPrefix(root.path + "/") else { return full }
        return String(full.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public var freeBytes: Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }

    public var totalBytes: Int64? {
        (try? root.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    // MARK: - Deleting (only after the user has confirmed)

    public enum DeleteError: Error, LocalizedError, Equatable {
        case outsideDrive(String)
        case protected(String)

        public var errorDescription: String? {
            switch self {
            case .outsideDrive(let path): "Refused: \(path) is not on the player's drive."
            case .protected(let path): "Refused: \(path) is protected and can't be deleted from the app."
            }
        }
    }

    /// Checks every item before anything is deleted, so a bad selection deletes nothing.
    public func checkDeletable(_ urls: [URL]) throws {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { throw DeleteError.outsideDrive(path) }
            let relative = relativePath(of: url)
            if relative.isEmpty || relative.lowercased() == "lost+found" {
                throw DeleteError.protected(relative.isEmpty ? "the drive itself" : relative)
            }
        }
    }

    /// Permanently deletes the given files/folders from the player's drive (there is no Trash
    /// on the player). A file's hidden `._` companion is removed with it. Call only after the
    /// user has seen exactly what will be removed and confirmed.
    ///
    /// Deletes file by file (~1 file per second on the player, NOTES.md), calling `progress`
    /// with the number of files removed so far. Stops early if the task is cancelled; what's
    /// already deleted stays deleted.
    public func delete(_ urls: [URL], progress: @Sendable (Int) -> Void = { _ in }) throws {
        try checkDeletable(urls)
        var removed = 0
        // Already gone counts as removed: on this drive macOS deletes a file's hidden `._`
        // companion by itself when the file is deleted (seen 2026-09-28).
        func removeIfPresent(_ path: String) throws {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            }
        }
        func removeFile(_ path: String) throws {
            try removeIfPresent(path)
            removed += 1
            progress(removed)
        }
        func removeFolder(_ path: String) throws {
            guard let dir = opendir(path) else { throw CocoaError(.fileReadNoPermission) }
            var entries: [(String, Bool)] = []
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                if name != "." && name != ".." { entries.append((name, entry.pointee.d_type == DT_DIR)) }
            }
            closedir(dir)
            for (name, isFolder) in entries {
                if Task.isCancelled { throw CancellationError() }
                let child = (path as NSString).appendingPathComponent(name)
                if isFolder { try removeFolder(child) } else { try removeFile(child) }
            }
            try removeIfPresent(path)  // now empty
        }
        for url in urls {
            if Task.isCancelled { throw CancellationError() }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                try removeFolder(url.path)
            } else {
                try removeFile(url.path)
                let companion = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
                if FileManager.default.fileExists(atPath: companion.path) { try? removeFile(companion.path) }
            }
        }
    }
}

/// Paths on the player mirror the computer they came from: "<computer name>/<original path>".
/// This finds whether the original is still on this Mac.
public struct OriginalLocator: Sendable {
    public enum Status: Equatable, Sendable {
        /// The original exists on this Mac at this path.
        case onThisMac(URL)
        /// It came from this Mac, but the original isn't there any more (or the drive isn't connected).
        case missing(URL)
        /// It came from another computer, e.g. "OTHER-PC".
        case otherComputer(String)
        /// Not in a computer folder (e.g. "Sample Music").
        case unknown
    }

    static let playerFolders: Set<String> = ["Sample Music", "lost+found"]

    public let computerName: String
    /// Where external drives are mounted on this Mac.
    let volumesRoot: URL
    let fileExists: @Sendable (String) -> Bool

    public init(computerName: String = Host.current().localizedName ?? "") {
        self.init(computerName: computerName, volumesRoot: URL(fileURLWithPath: "/Volumes"),
                  fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    init(computerName: String, volumesRoot: URL, fileExists: @escaping @Sendable (String) -> Bool) {
        self.computerName = computerName
        self.volumesRoot = volumesRoot
        self.fileExists = fileExists
    }

    /// `relativePath` is the path inside the player's drive.
    public func status(ofPlayerPath relativePath: String) -> Status {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // The player's own top-level folders don't come from a computer.
        guard let computer = parts.first, !Self.playerFolders.contains(computer) else { return .unknown }
        guard computer == computerName else { return .otherComputer(computer) }
        guard parts.count > 1 else { return .onThisMac(URL(fileURLWithPath: "/")) }
        let rest = parts.dropFirst()
        // "My Mac/Users/…" → /Users/…; "My Mac/Backup/…" → /Volumes/Backup/…
        let local: URL = rest.first == "Users"
            ? URL(fileURLWithPath: "/" + rest.joined(separator: "/"))
            : volumesRoot.appendingPathComponent(rest.joined(separator: "/"))
        return fileExists(local.path) ? .onThisMac(local) : .missing(local)
    }
}
