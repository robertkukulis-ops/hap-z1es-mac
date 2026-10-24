import Foundation
import HAPKit
import Observation

/// Browsing the player's music drive, and deleting only what the user selects and confirms.
@MainActor @Observable
final class DriveModel {
    private(set) var drive: HAPDrive?
    private(set) var connectError: String?
    private(set) var isConnecting = false
    private(set) var folder: URL?
    private(set) var items: [DriveItem] = []
    private(set) var listError: String?
    private(set) var isLoadingFolder = false
    /// The player's library tracks for the music files in this folder, by file name
    /// (from the player's own folder view). Nil while being asked.
    private(set) var folderTracks: [String: Track]?
    @ObservationIgnored private var loadToken = UUID()
    var selection = Set<URL>()

    /// Contents of the current selection: file count (fast) and size (slow), both in the background.
    private(set) var selectionSummary: DriveSummary?
    private(set) var selectionSize: Int64?

    /// Set when the user clicked Delete…; the confirmation dialog shows it.
    private(set) var pendingDeletion: PendingDeletion?
    private(set) var isDeleting = false
    /// Files deleted so far, and how many there are in total (while deleting).
    private(set) var deletedFiles = 0
    private(set) var filesToDelete = 0
    /// Result of the last deletion, shown as a message.
    private(set) var lastResult: String?

    struct PendingDeletion {
        let urls: [URL]
        let names: [String]
        let summary: DriveSummary
        /// Nil if the size is still being counted.
        let size: Int64?
        /// Set when some items didn't come from this Mac, or their originals are gone.
        let onlyCopyWarning: String?
        /// Shown first (e.g. after splitting a .cue album: the songs passed the check).
        var note: String? = nil
    }

    @ObservationIgnored let locator = OriginalLocator()
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Int64, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Error>?

    // MARK: Copying to the player (drag and drop)

    /// Set after a drop; the confirmation dialog shows it.
    private(set) var pendingUpload: UploadPlan?
    private(set) var isPlanningUpload = false
    private(set) var isUploading = false
    private(set) var uploadProgress = UploadProgress()
    private(set) var uploadTotalFiles = 0
    private(set) var uploadTotalBytes: Int64 = 0
    /// While a .cue album is being split on the Mac before copying: "Splitting “Live”… 3 of 12".
    private(set) var splitStatus: String?
    /// .cue albums in the open folder (whole albums in one file), found after it's listed.
    private(set) var cueAlbums: [CueAlbum] = []
    /// Waiting for "Split into songs" to be confirmed.
    private(set) var pendingSplit: CueAlbum?
    @ObservationIgnored private var uploadTask: Task<Void, Error>?

    /// Why the current folder can't take a drop, or nil if it can.
    var dropBlocker: String? {
        guard let drive, let folder else { return "The drive isn't connected." }
        do {
            try drive.checkUploadTarget(folder)
            return nil
        } catch {
            return PlayerModel.message(for: error)
        }
    }

    /// Step 1 after a drop: work out what would be copied (nothing is copied yet).
    func prepareUpload(_ urls: [URL], extensions: Set<String>) async {
        guard let drive, let folder, !isBusy else { return }
        isPlanningUpload = true
        defer { isPlanningUpload = false }
        do {
            let plan = try await Task.detached {
                try drive.planUpload(urls, into: folder, allowedExtensions: extensions)
            }.value
            if plan.items.isEmpty && plan.albumsToSplit.isEmpty {
                let pictures = await keepFolderPictures(plan)
                lastResult = "Nothing to copy." + Self.skipSummary(plan.skipped)
                    + (pictures == 0 ? "" : " The picture from \(pictures) album folder\(pictures == 1 ? " is" : "s are") now the cover in the app.")
            } else {
                pendingUpload = plan
            }
        } catch {
            lastResult = PlayerModel.message(for: error)
        }
    }

    func cancelUpload() { pendingUpload = nil }

    /// Step 2: only after the user confirmed. Copies with progress; `stopUploading()` stops it.
    func confirmUpload(_ original: UploadPlan) async {
        guard let drive, !hosts.isEmpty else { return }
        pendingUpload = nil
        isUploading = true
        let pictures = await keepFolderPictures(original)
        // .cue albums: split on the Mac first (into a temporary folder), then their songs are
        // copied like any other file. The Mac's own files are never changed.
        var plan = original
        var splitNotes: [String] = []
        cancelFlag = CancelFlag()
        let temporary = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAPKit/split/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (number, split) in original.albumsToSplit.enumerated() {
            let name = split.album.sheet.title ?? split.album.audio.deletingPathExtension().lastPathComponent
            splitStatus = "Splitting “\(name)”…"
            do {
                let folder = temporary.appendingPathComponent("\(number)", isDirectory: true)
                let album = split.album
                let flag = cancelFlag
                let songs = try await Task.detached {
                    let songs = try AlbumSplitter.split(album, into: folder, progress: { done, total in
                        Task { @MainActor [weak self] in self?.splitStatus = "Splitting “\(name)”… \(done) of \(total)" }
                    }, isCancelled: { flag.isSet })
                    // The exact check before anything is copied: the songs together = the original.
                    guard try AlbumSplitter.verify(songs: songs, against: album.audio, isCancelled: { flag.isSet }) else {
                        throw AlbumSplitter.SplitError.writeFailed("the songs of “\(name)” (they didn't match the original)")
                    }
                    return songs
                }.value
                let taken = Set(plan.items.map { $0.destination.path.lowercased() })
                let songPlan = drive.plan(songs: songs, into: split.destinationFolder, taken: taken)
                plan.items += songPlan.items
                plan.skipped += songPlan.skipped
                splitNotes.append("Split “\(name)” into \(songs.count) songs.")
            } catch {
                splitStatus = nil
                isUploading = false
                lastResult = error is CancellationError
                    ? "Stopped. Nothing was copied."
                    : "Splitting “\(name)” failed: \(PlayerModel.message(for: error)) Nothing was copied."
                return
            }
        }
        splitStatus = nil
        uploadProgress = UploadProgress()
        uploadTotalFiles = plan.items.count
        uploadTotalBytes = plan.totalBytes
        lastResult = nil
        let throttle = ProgressThrottle()
        // A session reconnects after every file and retries stalled files: the player's file
        // sharing drops connections after files are written (NOTES.md, "Uploads").
        let session = UploadSession(hosts: hosts, drive: drive)
        let folderPath = folder.map { drive.relativePath(of: $0) } ?? ""
        let task = Task.detached {
            try session.upload(plan) { progress in
                guard throttle.shouldReport(progress) else { return }
                Task { @MainActor [weak self] in self?.uploadProgress = progress }
            }
        }
        uploadTask = task
        defer {
            // The drive may now be connected at a different folder on the Mac.
            let fresh = session.drive
            self.drive = fresh
            folder = folderPath.isEmpty ? fresh.root : fresh.root.appendingPathComponent(folderPath)
        }
        do {
            try await task.value
            let recovered = session.retries > 0 ? " (\(session.retries) connection drop\(session.retries == 1 ? "" : "s") recovered)" : ""
            let leftovers = session.leftoverTemporaryFiles > 0
                ? " \(session.leftoverTemporaryFiles) hidden temporary file\(session.leftoverTemporaryFiles == 1 ? "" : "s") couldn't be removed yet; the next upload into this folder cleans \(session.leftoverTemporaryFiles == 1 ? "it" : "them") up."
                : ""
            lastResult = (splitNotes.isEmpty ? "" : splitNotes.joined(separator: " ") + " ")
                + "Copied \(plan.items.count) file\(plan.items.count == 1 ? "" : "s") (\(Self.bytes(plan.totalBytes))) to the player\(recovered)."
                + Self.skipSummary(plan.skipped) + leftovers
                + " The player adds new music to its library by itself; use Refresh Library to see it."
                + (pictures == 0 ? "" : " Album folder pictures become the covers in the app once the songs are in the library.")
        } catch is CancellationError {
            lastResult = "Stopped. \(uploadProgress.filesDone) of \(plan.items.count) files were copied. Drop the same files again to continue: complete ones are skipped."
        } catch {
            lastResult = "Copying stopped: \(PlayerModel.message(for: error)) \(uploadProgress.filesDone) files were copied before that. "
                + "Drop the same files again to continue: complete ones are skipped."
        }
        uploadTask = nil
        isUploading = false
        reload()
    }

    /// Stop: cancels a copy, and splitting or checking a .cue album.
    func stopUploading() {
        uploadTask?.cancel()
        cancelFlag.set()
    }

    /// Checked while splitting and checking (which run outside Swift tasks' cancellation).
    @ObservationIgnored private var cancelFlag = CancelFlag()

    // MARK: Splitting a .cue album that's already on the player

    func requestSplit(_ album: CueAlbum) { pendingSplit = album }
    func cancelSplit() { pendingSplit = nil }

    /// Reads the big file from the player, splits it on the Mac, copies the songs back into the
    /// same folder (the safe upload), checks them against the original, and then offers to
    /// delete the original (and its .cue) with the usual confirmation. Never deletes by itself.
    func confirmSplit(_ album: CueAlbum) async {
        guard let drive, !hosts.isEmpty, !isUploading else { return }
        pendingSplit = nil
        isUploading = true
        lastResult = nil
        let name = album.sheet.title ?? album.audio.deletingPathExtension().lastPathComponent
        let audioPath = drive.relativePath(of: album.audio), cuePath = drive.relativePath(of: album.cue)
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let temporary = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAPKit/split/\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            splitStatus = nil
            isUploading = false
            reload()
        }
        do {
            splitStatus = "Reading “\(name)” from the player and splitting it…"
            let songs = try await Task.detached {
                try AlbumSplitter.split(album, into: temporary, progress: { done, total in
                    Task { @MainActor [weak self] in self?.splitStatus = "Splitting “\(name)”… \(done) of \(total)" }
                }, isCancelled: { flag.isSet })
            }.value
            let plan = drive.plan(songs: songs, into: album.audio.deletingLastPathComponent())
            guard plan.skipped.isEmpty else {
                lastResult = "Songs with these names are already in this folder, so nothing was copied or deleted."
                return
            }
            splitStatus = nil
            uploadProgress = UploadProgress()
            uploadTotalFiles = plan.items.count
            uploadTotalBytes = plan.totalBytes
            let throttle = ProgressThrottle()
            let session = UploadSession(hosts: hosts, drive: drive)
            let upload = Task.detached {
                try session.upload(plan) { progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor [weak self] in self?.uploadProgress = progress }
                }
            }
            uploadTask = upload  // so Stop works
            defer { uploadTask = nil }
            try await upload.value
            // The drive may now be connected at a different folder on the Mac.
            let fresh = session.drive
            self.drive = fresh
            folder = fresh.root.appendingPathComponent(drive.relativePath(of: album.audio.deletingLastPathComponent()))
            splitStatus = "Checking the songs against the original…"
            let onPlayer = plan.items.map { fresh.root.appendingPathComponent(drive.relativePath(of: $0.destination)) }
            let original = fresh.root.appendingPathComponent(audioPath)
            let verified = try await Task.detached { try AlbumSplitter.verify(songs: onPlayer, against: original, isCancelled: { flag.isSet }) }.value
            let arrived = onPlayer.filter { FileManager.default.fileExists(atPath: $0.path) }.count
            switch CueSplitJob.outcome(verified: verified, uploaded: arrived, expected: songs.count) {
            case .failed(let problem):
                lastResult = "Split “\(name)” into \(songs.count) songs, but \(problem)"
            case .askToDeleteOriginal:
                let urls = [original, fresh.root.appendingPathComponent(cuePath)]
                let summary = await Task.detached { fresh.count(urls) }.value
                pendingDeletion = PendingDeletion(
                    urls: urls, names: urls.map(\.lastPathComponent), summary: summary, size: nil,
                    onlyCopyWarning: onlyCopyWarning(for: urls),
                    note: "The \(songs.count) songs of “\(name)” are now in this folder, and together they're identical to the original. "
                        + "You can delete the original big file and its .cue (or cancel to keep them; the album then shows twice in the player's library).")
            }
        } catch is CancellationError {
            lastResult = "Stopped. Nothing was deleted."
        } catch {
            lastResult = "Splitting “\(name)” stopped: \(PlayerModel.message(for: error)) Nothing was deleted."
        }
    }

    /// e.g. " Skipped 3: 2 not music files the player plays, 1 already on the player."
    static func skipSummary(_ skipped: [UploadSkip]) -> String {
        guard !skipped.isEmpty else { return "" }
        let counts = Dictionary(grouping: skipped, by: \.reason).map { "\($0.value.count) \($0.key)" }.sorted()
        return " Skipped \(skipped.count): " + counts.joined(separator: ", ") + "."
    }

    /// Ways to reach the drive, in order: the player's network name (e.g. "HAP-Z1ES"; the
    /// per-player SMB1 setting in nsmb.conf is keyed on it), then its address as a fallback.
    @ObservationIgnored private var hosts: [String] = []

    func connect(hosts: [String]) async {
        self.hosts = hosts
        guard drive == nil, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let drive = try await HAPDrive.connect(hosts: hosts)
            self.drive = drive
            connectError = nil
            open(drive.root)
            tidyMounts(keeping: drive)
        } catch {
            connectError = PlayerModel.message(for: error)
        }
    }

    /// If the drive's connection was lost (e.g. the player dropped it), connect again and
    /// reopen the same folder.
    func reconnect() async {
        guard !hosts.isEmpty, let old = drive else { return }
        let path = folder.map { old.relativePath(of: $0) } ?? ""
        do {
            let fresh = try await HAPDrive.connect(hosts: hosts)
            drive = fresh
            connectError = nil
            tidyMounts(keeping: fresh)
            open(path.isEmpty ? fresh.root : fresh.root.appendingPathComponent(path), retryOnFailure: false)
        } catch {
            listError = PlayerModel.message(for: error)
        }
    }

    /// Extra mounts of the drive left from earlier reconnects are disconnected (in the
    /// background: a dead mount could otherwise make the window wait).
    private func tidyMounts(keeping drive: HAPDrive) {
        let hosts = self.hosts
        Task.detached { HAPDrive.removeDuplicateMounts(hosts: hosts, keeping: drive.root) }
    }

    func open(_ url: URL) { open(url, retryOnFailure: true) }

    /// Lists the folder in the background (a slow or stuck drive must never freeze the window),
    /// then asks the player which of its music files are in its library.
    private func open(_ url: URL, retryOnFailure: Bool) {
        guard let drive else { return }
        folder = url
        selection = []
        selectionSummary = nil
        selectionSize = nil
        folderTracks = nil
        isLoadingFolder = true
        let token = UUID()
        loadToken = token
        Task {
            let result = await Task.detached { Result { try drive.items(in: url) } }.value
            guard loadToken == token else { return }  // another folder was opened meanwhile
            isLoadingFolder = false
            switch result {
            case .success(let list):
                items = list
                listError = nil
                cueAlbums = []
                if list.contains(where: { !$0.isFolder && $0.name.lowercased().hasSuffix(".cue") }) {
                    let found = await Task.detached { CueAlbum.find(in: url) }.value
                    if loadToken == token { cueAlbums = found }
                }
                await loadFolderTracks(for: url, token: token)
            case .failure(let error):
                items = []
                listError = PlayerModel.message(for: error)
                if retryOnFailure { await reconnect() }
            }
        }
    }

    @ObservationIgnored weak var player: PlayerModel?
    @ObservationIgnored weak var covers: CoverArtStore?

    /// Keeps the pictures of the dropped album folders (cover.jpg, …) as covers in the app (a
    /// copy on the Mac; nothing is written to the player). Used at once for songs already in
    /// the library, otherwise after the player has added them. Returns how many.
    private func keepFolderPictures(_ plan: UploadPlan) async -> Int {
        guard let drive, let covers else { return 0 }
        let found = await Task.detached { plan.folderPictures() }.value  // reads folders: not on the main thread
        let pictures = found.map { (picture: $0.picture, songs: $0.songs.map { drive.relativePath(of: $0) }) }
        guard !pictures.isEmpty else { return 0 }
        await covers.addFolderPictures(pictures)
        if let player, let library = player.library {
            covers.applyFolderCovers(albums: library.albums, tracks: library.tracks, trackPaths: player.trackPaths)
        }
        return pictures.count
    }

    private func loadFolderTracks(for url: URL, token: UUID) async {
        guard let drive, let client = player?.client,
              items.contains(where: { !$0.isFolder }) else { folderTracks = [:]; return }
        let path = drive.relativePath(of: url).split(separator: "/").map(String.init)
        let tracks = (try? await client.tracksInFolder(path)) ?? [:]
        guard loadToken == token else { return }
        folderTracks = tracks
        watchUnindexedFiles(path: path, token: token)
    }

    /// The player adds new files to its library a little while after they're copied, so while
    /// some files here aren't in it yet, ask again every 15 s for up to 5 minutes (read-only).
    private func watchUnindexedFiles(path: [String], token: UUID) {
        guard hasUnindexedFiles else { return }
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(15))
                guard loadToken == token, hasUnindexedFiles else { return }
                if isUploading || isDeleting { continue }  // don't disturb the player while it's busy
                guard let client = player?.client, let fresh = try? await client.tracksInFolder(path),
                      loadToken == token else { continue }
                if fresh.count > (folderTracks?.count ?? 0) {
                    folderTracks = fresh
                    await player?.refreshLibrary()  // show the new tracks in Albums/Tracks too
                }
            }
        }
    }

    private var hasUnindexedFiles: Bool {
        folderTracks != nil && items.contains { !$0.isFolder && track(for: $0) == nil }
    }

    /// The library track for a music file in the current folder, if the player has it.
    func track(for item: DriveItem) -> Track? {
        guard let folderTracks else { return nil }
        return folderTracks[item.name] ?? folderTracks.first { $0.key.precomposedStringWithCanonicalMapping == item.name.precomposedStringWithCanonicalMapping }?.value
    }

    /// Plays a music file, and the folder's other music after it.
    func play(_ item: DriveItem) async {
        guard let player else { return }
        guard let track = track(for: item) else {
            lastResult = folderTracks == nil
                ? "Still asking the player about this folder; try again in a moment."
                : "The player hasn't added “\(item.name)” to its library yet, so it can't be played from here. It usually does so within a few minutes of copying."
            return
        }
        let playable = items.filter { !$0.isFolder }.compactMap { self.track(for: $0) }
        let start = playable.firstIndex { $0.trackid == track.trackid } ?? 0
        await player.play(playable, from: start, title: breadcrumbs.last?.name ?? "Folder")
    }

    func reload() { if let folder { open(folder) } }

    /// Breadcrumbs from the drive's top level to the current folder.
    var breadcrumbs: [(name: String, url: URL)] {
        guard let drive, let folder else { return [] }
        var crumbs = [(name: "HAP_Internal", url: drive.root)]
        var url = drive.root
        for part in drive.relativePath(of: folder).split(separator: "/") {
            url = url.appendingPathComponent(String(part), isDirectory: true)
            crumbs.append((name: String(part), url: url))
        }
        return crumbs
    }

    /// Tick / untick one item (the checkboxes), keeping the rest of the selection.
    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    func selectionChanged() {
        countTask?.cancel()
        sizeTask?.cancel()
        selectionSummary = nil
        selectionSize = nil
        guard let drive, !selection.isEmpty else { return }
        let urls = Array(selection)
        let size = Task.detached { drive.size(of: urls) }
        sizeTask = size
        countTask = Task {
            let summary = await Task.detached { drive.count(urls) }.value
            guard !Task.isCancelled else { return }
            selectionSummary = summary
            let bytes = await size.value
            guard !Task.isCancelled else { return }
            selectionSize = bytes
        }
    }

    func relativePath(_ url: URL) -> String { drive?.relativePath(of: url) ?? url.path }

    func originalStatus(_ url: URL) -> OriginalLocator.Status {
        locator.status(ofPlayerPath: relativePath(url))
    }

    /// Why the selection can't be deleted, or nil if it can.
    var deleteBlocker: String? {
        guard let drive, !selection.isEmpty else { return "Nothing selected" }
        do {
            try drive.checkDeletable(Array(selection))
            return nil
        } catch {
            return PlayerModel.message(for: error)
        }
    }

    /// Step 1: count exactly what would go, then ask for confirmation.
    func requestDelete() async {
        guard let drive, deleteBlocker == nil, !isBusy else { return }
        let urls = selection.sorted { $0.path < $1.path }
        let summary = await Task.detached { drive.count(urls) }.value
        pendingDeletion = PendingDeletion(urls: urls, names: urls.map(\.lastPathComponent),
                                          summary: summary, size: selectionSize,
                                          onlyCopyWarning: onlyCopyWarning(for: urls))
    }

    func cancelDelete() { pendingDeletion = nil }

    /// Warns when the player may hold the only copy: items from another computer, or from
    /// this Mac but no longer here.
    func onlyCopyWarning(for urls: [URL]) -> String? {
        var others = Set<String>(), missing = 0
        for url in urls {
            switch originalStatus(url) {
            case .otherComputer(let name): others.insert(name)
            case .missing: missing += 1
            case .onThisMac, .unknown: break
            }
        }
        var parts: [String] = []
        if !others.isEmpty {
            parts.append("Came from \(others.sorted().joined(separator: ", ")), not this Mac: the player may have the only copy.")
        }
        if missing > 0 {
            parts.append("\(missing == 1 ? "1 item's" : "\(missing) items'") original is no longer on this Mac.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ") + " Make sure you have another copy, or don't need it."
    }

    /// Step 2: only after the user confirmed in the dialog. The dialog hands over exactly what
    /// it showed (closing the dialog clears `pendingDeletion` before this runs).
    /// Deletes file by file (~1 per second on the player) with progress; `stopDeleting()` stops it.
    func confirmDelete(_ pending: PendingDeletion) async {
        guard let drive else { return }
        pendingDeletion = nil
        isDeleting = true
        deletedFiles = 0
        filesToDelete = pending.summary.files
        lastResult = nil
        let task = Task.detached {
            try drive.delete(pending.urls) { removed in
                Task { @MainActor [weak self] in self?.deletedFiles = max(self?.deletedFiles ?? 0, removed) }
            }
        }
        deleteTask = task
        let what = pending.names.count == 1 ? "“\(pending.names[0])”" : "\(pending.names.count) items"
        do {
            try await task.value
            lastResult = "Deleted \(what) (\(pending.summary.files) files\(pending.size.map { ", " + Self.bytes($0) } ?? "")). "
                + "The player updates its library by itself; use Refresh Library to see the new lists."
        } catch is CancellationError {
            lastResult = "Stopped. \(deletedFiles) of \(filesToDelete) files were deleted; the rest is still on the player."
        } catch {
            lastResult = "Deletion stopped: \(PlayerModel.message(for: error)). \(deletedFiles) files were deleted; the list shows what's left."
        }
        deleteTask = nil
        isDeleting = false
        reload()
    }

    // MARK: New folders, moving and copying on the player

    /// Creates an empty folder in the open folder; nil if it worked, otherwise why not.
    func createFolder(named name: String) -> String? {
        guard let drive, let folder else { return "The drive isn't connected." }
        do {
            let made = try drive.createFolder(named: name, in: folder)
            reload()
            selection = [made]
            return nil
        } catch {
            return PlayerModel.message(for: error)
        }
    }

    enum OrganizeKind: Equatable {
        case move, copy
        var verb: String { self == .move ? "Move" : "Copy" }
    }

    /// Choosing where to move or copy these items (the folder chooser shows it).
    struct OrganizeRequest: Identifiable {
        let id = UUID()
        let kind: OrganizeKind
        let urls: [URL]
    }

    /// Waiting for "Move here" / "Copy here" to be confirmed.
    struct PendingOrganize {
        let kind: OrganizeKind
        let destination: URL
        let destinationName: String
        /// Where the drive was on the Mac when this was planned (it can reconnect elsewhere).
        let planRoot: URL
        var moves = MovePlan()
        var copies = UploadPlan()
        var count: Int { kind == .move ? moves.moves.count : copies.items.count }
        var skipped: [UploadSkip] { kind == .move ? moves.skipped : copies.skipped }
    }

    var organizeRequest: OrganizeRequest?
    private(set) var pendingOrganize: PendingOrganize?
    private(set) var isMoving = false

    /// Copying, splitting, deleting or moving: only one job on the drive at a time.
    var isBusy: Bool { isUploading || isDeleting || isMoving || splitStatus != nil }

    /// Why the selection can't be moved or copied, or nil if it can.
    var organizeBlocker: String? {
        if isBusy { return "Wait until the current job has finished." }
        return deleteBlocker  // the same rules: on the drive, not the drive itself or lost+found
    }

    func requestOrganize(_ kind: OrganizeKind, _ urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        organizeRequest = OrganizeRequest(kind: kind, urls: urls.sorted { $0.path < $1.path })
    }

    /// The folder was chosen: work out exactly what would happen (nothing changes yet).
    func prepareOrganize(_ request: OrganizeRequest, into destination: URL) async {
        guard let drive else { return }
        organizeRequest = nil
        do {
            let kind = request.kind, urls = request.urls
            var pending = PendingOrganize(kind: kind, destination: destination,
                                          destinationName: drive.relativePath(of: destination).isEmpty
                                              ? "HAP_Internal" : drive.relativePath(of: destination),
                                          planRoot: drive.root)
            if kind == .move {
                pending.moves = try await Task.detached { try drive.planMove(urls, into: destination) }.value
            } else {
                pending.copies = try await Task.detached { try drive.planCopy(urls, into: destination) }.value
            }
            if pending.count == 0 {
                lastResult = "Nothing to \(kind.verb.lowercased())." + Self.skipSummary(pending.skipped)
            } else {
                pendingOrganize = pending
            }
        } catch {
            lastResult = PlayerModel.message(for: error)
        }
    }

    func cancelOrganize() { pendingOrganize = nil }

    /// Items dragged onto a folder (in the list or the path bar): move them there, or copy
    /// them with ⌥ held. A dragged item that's selected brings the whole selection along.
    /// The confirmation comes next; nothing moves before it.
    func drop(_ urls: [URL], into target: URL, copy: Bool) {
        let dragged = urls.contains(where: selection.contains) ? Array(selection) : urls
        // Let go on one of the dragged items itself: nothing happens (like Finder).
        guard !dragged.isEmpty, !isBusy,
              !dragged.contains(where: { $0.standardizedFileURL.path == target.standardizedFileURL.path }) else { return }
        let request = OrganizeRequest(kind: copy ? .copy : .move, urls: dragged.sorted { $0.path < $1.path })
        Task { await prepareOrganize(request, into: target) }
    }

    /// Only after the user confirmed: moves (renames on the drive) or copies (checked, like uploads).
    func confirmOrganize(_ pending: PendingOrganize) async {
        pendingOrganize = nil
        if pending.kind == .move { await move(pending) } else { await copy(pending) }
    }

    /// The same place on the drive as connected now (it may have reconnected at another folder
    /// on the Mac since the plan was made).
    private static func rerooted(_ url: URL, from old: URL, to new: URL) -> URL {
        guard old.path != new.path else { return url }
        return new.appendingPathComponent(HAPDrive(root: old).relativePath(of: url))
    }

    private func move(_ pending: PendingOrganize) async {
        guard let drive else { return }
        isMoving = true
        lastResult = nil
        var plan = pending.moves
        plan.moves = plan.moves.map {
            PlannedMove(source: Self.rerooted($0.source, from: pending.planRoot, to: drive.root),
                        destination: Self.rerooted($0.destination, from: pending.planRoot, to: drive.root))
        }
        do {
            let moved = try await Task.detached { try drive.move(plan) }.value
            lastResult = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to “\(pending.destinationName)”."
                + Self.skipSummary(pending.skipped)
                + " The player finds them in their new place by itself, usually within a few minutes."
        } catch {
            lastResult = "Moving stopped: \(PlayerModel.message(for: error)) What was already moved stays in “\(pending.destinationName)”."
        }
        isMoving = false
        selection = []
        reload()
        await player?.refreshLibrary()
    }

    private func copy(_ pending: PendingOrganize) async {
        guard let drive, !hosts.isEmpty else {
            lastResult = "The drive isn't connected, so nothing was copied."
            return
        }
        var plan = pending.copies
        plan.items = plan.items.map {
            UploadItem(source: Self.rerooted($0.source, from: pending.planRoot, to: drive.root),
                       destination: Self.rerooted($0.destination, from: pending.planRoot, to: drive.root), size: $0.size)
        }
        isUploading = true
        uploadProgress = UploadProgress()
        uploadTotalFiles = plan.items.count
        uploadTotalBytes = plan.totalBytes
        lastResult = nil
        let throttle = ProgressThrottle()
        let session = UploadSession(hosts: hosts, drive: drive)
        let folderPath = folder.map { drive.relativePath(of: $0) } ?? ""
        let task = Task.detached {
            try session.upload(plan) { progress in
                guard throttle.shouldReport(progress) else { return }
                Task { @MainActor [weak self] in self?.uploadProgress = progress }
            }
        }
        uploadTask = task
        do {
            try await task.value
            lastResult = "Copied \(plan.items.count) file\(plan.items.count == 1 ? "" : "s") (\(Self.bytes(plan.totalBytes))) to “\(pending.destinationName)”."
                + Self.skipSummary(plan.skipped)
                + " The originals stay where they were. The player adds the copies to its library by itself."
        } catch is CancellationError {
            lastResult = "Stopped. \(uploadProgress.filesDone) of \(plan.items.count) files were copied. Copy the same items again to continue: complete ones are skipped."
        } catch {
            lastResult = "Copying stopped: \(PlayerModel.message(for: error)) \(uploadProgress.filesDone) files were copied before that."
        }
        // The drive may now be connected at a different folder on the Mac.
        let fresh = session.drive
        self.drive = fresh
        folder = folderPath.isEmpty ? fresh.root : fresh.root.appendingPathComponent(folderPath)
        uploadTask = nil
        isUploading = false
        selection = []
        reload()
    }

    // MARK: Deleting tracks from anywhere (library pages)

    struct PendingTrackDeletion {
        let tracks: [Track]
        let urls: [URL]
        /// Tracks whose file couldn't be located (not deleted).
        let unlocated: [Track]
        let onlyCopyWarning: String?
    }

    private(set) var pendingTrackDeletion: PendingTrackDeletion?
    private(set) var isPreparingTrackDeletion = false

    /// Connects to the drive if the Drive page hasn't yet (by name, then address).
    func ensureConnected(_ player: PlayerModel) async {
        self.player = player
        guard drive == nil, let device = player.device else { return }
        await connect(hosts: [device.friendlyName, device.host])
    }

    /// Step 1: find the tracks' files and ask for confirmation.
    func requestDeletion(of tracks: [Track], player: PlayerModel) async {
        guard !tracks.isEmpty, !isDeleting, !isUploading else { return }
        isPreparingTrackDeletion = true
        defer { isPreparingTrackDeletion = false }
        await ensureConnected(player)
        if tracks.contains(where: { player.trackPaths[$0.trackid] == nil }) { await player.loadTrackPaths() }
        guard let drive else {
            lastResult = "Couldn't connect to the player's drive, so nothing was deleted."
            return
        }
        var urls: [URL] = [], unlocated: [Track] = []
        for track in tracks {
            if let path = player.trackPaths[track.trackid] {
                urls.append(drive.root.appendingPathComponent(path))
            } else {
                unlocated.append(track)
            }
        }
        guard !urls.isEmpty else {
            lastResult = "Couldn't find the files for these tracks on the drive, so nothing was deleted."
            return
        }
        pendingTrackDeletion = PendingTrackDeletion(tracks: tracks.filter { player.trackPaths[$0.trackid] != nil },
                                                    urls: urls, unlocated: unlocated,
                                                    onlyCopyWarning: onlyCopyWarning(for: urls))
    }

    func cancelTrackDeletion() { pendingTrackDeletion = nil }

    /// Step 2: only after the user confirmed.
    func confirmTrackDeletion(_ pending: PendingTrackDeletion) async {
        guard let drive else { return }
        pendingTrackDeletion = nil
        isDeleting = true
        deletedFiles = 0
        filesToDelete = pending.urls.count
        lastResult = nil
        let task = Task.detached {
            try drive.delete(pending.urls) { removed in
                Task { @MainActor [weak self] in self?.deletedFiles = max(self?.deletedFiles ?? 0, removed) }
            }
        }
        deleteTask = task
        var removedIDs = Set<Int>()
        do {
            try await task.value
            removedIDs = Set(pending.tracks.map(\.trackid))
            lastResult = "Deleted \(countText(pending.tracks.count, "track")) from the player."
                + (pending.unlocated.isEmpty ? "" : " \(countText(pending.unlocated.count, "track")) couldn't be found on the drive and were left alone.")
        } catch {
            // Work out which files are really gone.
            for (track, url) in zip(pending.tracks, pending.urls) where !FileManager.default.fileExists(atPath: url.path) {
                removedIDs.insert(track.trackid)
            }
            lastResult = (error is CancellationError ? "Stopped. " : "Deleting stopped: \(PlayerModel.message(for: error)). ")
                + "\(countText(removedIDs.count, "track")) of \(pending.tracks.count) were deleted."
        }
        deleteTask = nil
        isDeleting = false
        player?.forget(trackIDs: removedIDs)
        if folder != nil { reload() }
    }

    // MARK: Tidying up Mac leftovers

    struct PendingTidy {
        let urls: [URL]
        let folderName: String
    }

    /// Set after counting; the confirmation dialog shows it.
    private(set) var pendingTidy: PendingTidy?
    private(set) var isScanningLeftovers = false

    /// Step 1: count the Mac leftovers in the current folder and everything inside it.
    func requestTidy() async {
        guard let drive, let folder, !isBusy else { return }
        isScanningLeftovers = true
        defer { isScanningLeftovers = false }
        let found = await Task.detached { drive.macLeftovers(in: folder) }.value
        if found.isEmpty {
            lastResult = "No Mac leftovers here: nothing to tidy."
        } else {
            pendingTidy = PendingTidy(urls: found, folderName: breadcrumbs.last?.name ?? "this folder")
        }
    }

    func cancelTidy() { pendingTidy = nil }

    /// Step 2: only after the user confirmed.
    func confirmTidy(_ pending: PendingTidy) async {
        guard let drive else { return }
        pendingTidy = nil
        isDeleting = true
        deletedFiles = 0
        filesToDelete = pending.urls.count
        lastResult = nil
        let task = Task.detached {
            try drive.delete(pending.urls) { removed in
                Task { @MainActor [weak self] in self?.deletedFiles = max(self?.deletedFiles ?? 0, removed) }
            }
        }
        deleteTask = task
        do {
            try await task.value
            lastResult = "Tidied up: removed \(pending.urls.count) Mac leftover file\(pending.urls.count == 1 ? "" : "s"). No music was touched."
        } catch is CancellationError {
            lastResult = "Stopped. \(deletedFiles) of \(filesToDelete) leftover files were removed."
        } catch {
            lastResult = "Tidying stopped: \(PlayerModel.message(for: error)). \(deletedFiles) leftover files were removed."
        }
        deleteTask = nil
        isDeleting = false
        reload()
    }

    /// Stops a running deletion after the current file. What's already deleted stays deleted.
    func stopDeleting() { deleteTask?.cancel() }

    func dismissResult() { lastResult = nil }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Passes on progress at most every 4 MB (and at each new file), so the screen isn't flooded.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBytes: Int64 = -1
    private var lastFiles = -1

    func shouldReport(_ progress: UploadProgress) -> Bool {
        lock.withLock {
            if progress.filesDone != lastFiles || progress.bytesDone - lastBytes >= 4 << 20 || lastBytes < 0 {
                lastFiles = progress.filesDone
                lastBytes = progress.bytesDone
                return true
            }
            return false
        }
    }
}

/// BACK and the FOLDERS switch on the amp move through the drive's folders.
extension DriveModel: DriveNavigation {
    var folderDepth: Int { max(breadcrumbs.count - 1, 0) }
    func goUpFolder() { if let parent = breadcrumbs.dropLast().last { open(parent.url) } }
    func goToTopFolder() { if let top = breadcrumbs.first { open(top.url) } }
}
