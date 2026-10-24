import Foundation

// Organising the player's drive: new folders, and moving or copying what's already on it.
//
// Safety (CLAUDE.md): only what the user selected and confirmed. Nothing is ever overwritten:
// anything whose name is already taken in the destination is skipped. Moving renames on the
// drive itself (no data is copied); copying uses the checked upload path.

/// One file or folder to move.
public struct PlannedMove: Sendable, Equatable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// What a move would do: shown to the user before anything moves.
public struct MovePlan: Sendable, Equatable {
    public var moves: [PlannedMove] = []
    public var skipped: [UploadSkip] = []

    public init() {}
}

public enum OrganizeError: Error, LocalizedError, Equatable {
    case emptyName
    case hiddenName
    case alreadyExists(String)
    case unreadable(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Please type a name for the folder."
        case .hiddenName: "A name starting with a dot would be hidden; please choose another."
        case .unreadable(let name): "Couldn't read the folder “\(name)” on the player, so nothing was changed. Please try again."
        case .alreadyExists(let name): "Something called “\(name)” is already in this folder."
        case .failed(let name, let why): "“\(name)”: \(why)"
        }
    }
}

extension HAPDrive {
    /// Creates an empty folder called `name` (characters the player doesn't allow become "_")
    /// inside `parent`, and returns it. Refuses if the name is taken (in any capitals).
    public func createFolder(named name: String, in parent: URL) throws -> URL {
        try checkUploadTarget(parent)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizeError.emptyName }
        guard !trimmed.hasPrefix(".") else { throw OrganizeError.hiddenName }
        let url = parent.appendingPathComponent(Self.safeName(trimmed), isDirectory: true)
        try checkUploadTarget(url)  // e.g. not "lost+found"
        if try Self.existingName(url.lastPathComponent, in: parent) != nil { throw OrganizeError.alreadyExists(url.lastPathComponent) }
        guard mkdir(url.path, 0o755) == 0 else {
            if errno == EEXIST { throw OrganizeError.alreadyExists(url.lastPathComponent) }
            throw OrganizeError.failed(url.lastPathComponent, String(cString: strerror(errno)))
        }
        return url
    }

    /// Works out what moving `sources` (files or folders on the drive) into `folder` would do,
    /// without moving anything.
    public func planMove(_ sources: [URL], into folder: URL) throws -> MovePlan {
        try checkUploadTarget(folder)
        var plan = MovePlan()
        var taken = Set<String>()
        for source in sources.sorted(by: { $0.path < $1.path }) {
            if let reason = organizeProblem(source, into: folder) {
                plan.skipped.append(UploadSkip(source: source, reason: reason))
                continue
            }
            let name = source.lastPathComponent
            guard taken.insert(name.lowercased()).inserted else {
                plan.skipped.append(UploadSkip(source: source, reason: "another selected item has the same name"))
                continue
            }
            plan.moves.append(PlannedMove(source: source, destination: folder.appendingPathComponent(name)))
        }
        return plan
    }

    /// Moves as planned: a rename on the drive, so it's quick and no data is copied. Never over
    /// an existing name. A file's hidden `._` companion moves with it. Calls `progress` with the
    /// number moved so far; stops early if the task is cancelled. Returns what was moved.
    @discardableResult
    public func move(_ plan: MovePlan, progress: @Sendable (Int) -> Void = { _ in }) throws -> [PlannedMove] {
        var moved: [PlannedMove] = []
        for item in plan.moves {
            if Task.isCancelled { throw CancellationError() }
            try checkDeletable([item.source])
            try checkUploadTarget(item.destination.deletingLastPathComponent())
            if try Self.existingName(item.destination.lastPathComponent, in: item.destination.deletingLastPathComponent()) != nil {
                throw OrganizeError.alreadyExists(item.destination.lastPathComponent)
            }
            do {
                try FileManager.default.moveItem(at: item.source, to: item.destination)  // fails if the name is taken
            } catch {
                throw OrganizeError.failed(item.source.lastPathComponent, (error as NSError).localizedDescription)
            }
            let companion = item.source.deletingLastPathComponent().appendingPathComponent("._" + item.source.lastPathComponent)
            if FileManager.default.fileExists(atPath: companion.path) {
                let target = item.destination.deletingLastPathComponent().appendingPathComponent("._" + item.destination.lastPathComponent)
                try? FileManager.default.moveItem(at: companion, to: target)
            }
            moved.append(item)
            progress(moved.count)
        }
        return moved
    }

    /// Works out what copying `sources` (files or folders on the drive) into `folder` would copy,
    /// without copying anything. Folders keep their structure; Mac leftovers and hidden files
    /// are left out; files whose name is already taken are skipped.
    public func planCopy(_ sources: [URL], into folder: URL) throws -> UploadPlan {
        try checkUploadTarget(folder)
        var plan = UploadPlan()
        var taken = Set<String>()
        func add(_ file: URL, as destination: URL) {
            let name = file.lastPathComponent
            if Self.isJunk(name) || name.hasPrefix(".") { return }
            guard taken.insert(destination.path.lowercased()).inserted else {
                plan.skipped.append(UploadSkip(source: file, reason: "another selected item has the same name"))
                return
            }
            if Self.fileSize(destination) != nil {
                plan.skipped.append(UploadSkip(source: file, reason: "something with this name is already there"))
                return
            }
            let size = Self.fileSize(file) ?? 0
            plan.items.append(UploadItem(source: file, destination: destination, size: size))
        }
        for source in sources.sorted(by: { $0.path < $1.path }) {
            if let reason = organizeProblem(source, into: folder, copying: true) {
                plan.skipped.append(UploadSkip(source: source, reason: reason))
                continue
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else { continue }
            // A folder of the same name already there (e.g. an earlier copy that was stopped):
            // copy into it, file by file; files already there are skipped.
            let name = (try? Self.existingName(source.lastPathComponent, in: folder)) ?? nil
            let top = folder.appendingPathComponent(name ?? source.lastPathComponent, isDirectory: isFolder.boolValue)
            guard isFolder.boolValue else { add(source, as: top); continue }
            // Paths relative to the selected folder, so every file stays under the drive's own
            // path (a listing can hand back another spelling of the same place).
            let walker = FileManager.default.enumerator(atPath: source.path)
            while let relative = walker?.nextObject() as? String {
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if walker?.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
                add(source.appendingPathComponent(relative), as: top.appendingPathComponent(relative))
            }
        }
        plan.items.sort { $0.destination.path.localizedStandardCompare($1.destination.path) == .orderedAscending }
        return plan
    }

    /// Why `source` can't be moved (or copied) into `folder`, or nil if it can.
    func organizeProblem(_ source: URL, into folder: URL, copying: Bool = false) -> String? {
        let path = source.standardizedFileURL.path, target = folder.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return "it's not on the player's drive" }
        let relative = relativePath(of: source)
        if relative.lowercased() == "lost+found" || relative.lowercased().hasPrefix("lost+found/") {
            return "it's in lost+found"
        }
        let name = source.lastPathComponent
        if Self.isJunk(name) || name.hasPrefix(".") { return "it's a hidden or Mac leftover file" }
        if target == path || target.hasPrefix(path + "/") { return "a folder can't go inside itself" }
        if source.deletingLastPathComponent().standardizedFileURL.path == target {
            return copying ? "it's already in this folder (a copy would need another name)" : "it's already in this folder"
        }
        let existing: String?
        do { existing = try Self.existingName(name, in: folder) } catch { return "the destination folder couldn't be read" }
        if let existing {
            var sourceIsFolder: ObjCBool = false, existingIsFolder: ObjCBool = false
            let bothFolders = FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsFolder)
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(existing).path, isDirectory: &existingIsFolder)
                && sourceIsFolder.boolValue && existingIsFolder.boolValue
            if !(copying && bothFolders) { return "something with this name is already there" }
        }
        return nil
    }

    /// The name of what `folder` already holds under `name` (in any capitals), or nil.
    /// Throws if the folder can't be read, so a bad connection never counts as "name free".
    static func existingName(_ name: String, in folder: URL) throws -> String? {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch {
            throw OrganizeError.unreadable(folder.lastPathComponent)
        }
        return names.first { $0.lowercased() == name.lowercased() }
    }
}
