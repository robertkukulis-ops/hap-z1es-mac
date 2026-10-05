import Foundation
import HAPKit
import Observation

/// Everything the app knows about the player. It asks questions, listens for updates, and
/// sends only the playback commands tested with the user (play/pause, next, previous, play a
/// track). It never changes anything on the player's drive.
@MainActor @Observable
final class PlayerModel {
    enum Connection: Equatable {
        case searching
        case connected
        case failed(String)
    }

    private(set) var connection: Connection = .searching
    private(set) var device: HAPDevice?
    private(set) var power: PowerStatus?
    /// What's loaded, from getPlayingContentInfo (has position, state, format, cover link).
    private(set) var content: PlayingContent?
    private(set) var library: LibrarySnapshot? {
        didSet { artistIndex = ArtistIndex(tracks: library?.tracks ?? []) }
    }
    /// Artists as the app shows them: spelling variants merged, "feat." guests included.
    private(set) var artistIndex = ArtistIndex(tracks: [])
    private(set) var isRefreshingLibrary = false
    private(set) var libraryError: String?
    /// Shown briefly when a playback command didn't get an answer or was refused; fades after
    /// 10 seconds (or when the next command works).
    private(set) var commandProblem: String? {
        didSet {
            guard let problem = commandProblem else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                if self?.commandProblem == problem { self?.commandProblem = nil }
            }
        }
    }

    /// The list the app is playing (albums, playlists, folders); see AppQueue.
    private(set) var queue: AppQueue?
    /// Shuffle and repeat for the app's lists, remembered between launches.
    private(set) var shuffleOn = UserDefaults.standard.bool(forKey: "shuffleOn") {
        didSet { UserDefaults.standard.set(shuffleOn, forKey: "shuffleOn") }
    }
    private(set) var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }

    /// Where each track's file is on the drive (trackid → path inside the drive), from the
    /// player's folder view; read after each library refresh (~5 s, read-only).
    private(set) var trackPaths: [Int: String] = [:]

    @ObservationIgnored private(set) var client: HAPClient?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private let store = LibraryStore()

    // MARK: - Connecting

    /// Finds the player (SSDP, or HAP_HOST if set), shows the saved library at once,
    /// then refreshes it and starts listening for live updates.
    func connect() async {
        connection = .searching
        do {
            let found = try await findPlayer()
            let client = HAPClient(device: found)
            self.device = found
            self.client = client
            self.library = store.load(playerUDN: found.udn)
            connection = .connected
            power = try? await client.powerStatus()
            await refreshContent()
            startListening()
            startMonitoring()
            // Show the saved copy at once, then bring it up to date (files may have been
            // added or deleted since; the player updates its library by itself).
            await refreshLibrary()
        } catch {
            connection = .failed(Self.message(for: error))
        }
    }

    /// Right after the app starts, macOS may block the first network attempt while it checks
    /// the "Local Network" permission ("No route to host"), so try up to 3 times.
    private func findPlayer() async throws -> HAPDevice {
        var lastError: Error = HAPError.noPlayerFound
        for attempt in 1...3 {
            do {
                if let host = ProcessInfo.processInfo.environment["HAP_HOST"] {
                    return try await HAPDiscovery.device(atHost: host)
                }
                if let first = try await HAPDiscovery.find().first { return first }
                lastError = HAPError.noPlayerFound
            } catch {
                lastError = error
            }
            if attempt < 3 { try await Task.sleep(for: .seconds(1.5)) }
        }
        throw lastError
    }

    /// File types the player plays (asked once, e.g. "flac", "wav", "dsf"); used to decide what
    /// a drag and drop copies. Falls back to the list the player gave us on 2026-09-25.
    func supportedExtensions() async -> Set<String> {
        if let known = supportedExtensionsCache { return known }
        let types = (try? await client?.supportedFileTypes()) ?? [
            "*.3gp", "*.aa3", "*.aif", "*.aiff", "*.dff", "*.dsf", "*.fla", "*.flac",
            "*.m4a", "*.mp3", "*.mp4", "*.oma", "*.wav", "*.wma"]
        let result = HAPDrive.extensions(fromSupportedTypes: types)
        supportedExtensionsCache = result
        return result
    }
    @ObservationIgnored private var supportedExtensionsCache: Set<String>?

    // MARK: - Library

    func refreshLibrary() async {
        guard let client, let device, !isRefreshingLibrary else { return }
        isRefreshingLibrary = true
        defer { isRefreshingLibrary = false }
        do {
            library = try await store.refresh(from: client, playerUDN: device.udn)
            libraryError = nil
        } catch {
            libraryError = Self.message(for: error)
        }
        await loadTrackPaths()
    }

    func loadTrackPaths() async {
        guard let client, let paths = try? await client.trackLocations() else { return }
        trackPaths = paths
    }

    /// After deleting: take the tracks out of the lists at once (the player updates its own
    /// library by itself; the next refresh brings the official lists).
    func forget(trackIDs: Set<Int>) {
        guard let old = library else { return }
        let tracks = old.tracks.filter { !trackIDs.contains($0.trackid) }
        let albumIDs = Set(tracks.compactMap { $0.album?.albumid })
        library = LibrarySnapshot(playerUDN: old.playerUDN, fetchedAt: old.fetchedAt,
                                  albums: old.albums.filter { albumIDs.contains($0.albumid) },
                                  artists: old.artists, genres: old.genres, playlists: old.playlists, tracks: tracks)
        for id in trackIDs { trackPaths[id] = nil }
    }

    /// An album's tracks in order (disc, then track number), from the saved track list.
    func tracks(of album: Album) -> [Track] {
        (library?.tracks ?? []).filter { $0.album?.albumid == album.albumid }.sorted(by: Self.albumOrder)
    }

    static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        (a.diskNumber ?? 0, a.trackNumber ?? 0, a.name) < (b.diskNumber ?? 0, b.trackNumber ?? 0, b.name)
    }

    /// The album a track belongs to (with its cover), from the saved library.
    func album(of track: Track) -> Album? {
        guard let id = track.album?.albumid else { return nil }
        return library?.albums.first { $0.albumid == id }
    }

    /// The track that's loaded on the player, from the saved library.
    var currentTrack: Track? {
        guard let id = content?.trackID else { return nil }
        return library?.tracks.first { $0.trackid == id }
    }

    /// Cover art is served by the player. Its links contain the player's own IP address,
    /// so keep only the path and use the address we actually reached it on.
    func coverURL(_ image: ImageRef?) -> URL? {
        coverURL(image?.url)
    }

    func coverURL(_ link: String?) -> URL? {
        guard let link, let parsed = URLComponents(string: link), let device,
              var url = URLComponents(url: device.apiBaseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        url.path = parsed.path
        return url.url
    }

    // MARK: - Playing

    var isPlaying: Bool { content?.state == "PLAYING" }
    /// Jumping only works within a playing or paused song (a stopped player refuses it).
    var canSeek: Bool { content?.state == "PLAYING" || content?.state == "PAUSED" }
    var position: Double { Double(content?.positionMsec ?? 0) / 1000 }
    var duration: Double { Double(content?.durationMsec ?? 0) / 1000 }

    enum Command {
        case playPause, next, previous
        case play(trackID: Int)
        case seek(second: Int)
    }

    /// Plays a list. `from`: the song that was clicked (the rest follows); nil = a Play button,
    /// which starts at the top, or at a random song when shuffle is on.
    func play(_ tracks: [Track], from index: Int? = nil, title: String) async {
        guard !tracks.isEmpty else { return }
        let start = index ?? (shuffleOn ? Int.random(in: tracks.indices) : 0)
        guard tracks.indices.contains(start) else { return }
        let q = AppQueue(songs: tracks, start: start, title: title, shuffled: shuffleOn, shuffle: { $0.shuffle() })
        queue = q
        await send(.play(trackID: q.current.trackid))
    }

    /// SHUFFLE button: the current song keeps playing; what's left is shuffled (or back in order).
    func toggleShuffle() {
        shuffleOn.toggle()
        queue?.setShuffle(shuffleOn, shuffle: { $0.shuffle() })
    }

    /// REPEAT button: off → all → one.
    func cycleRepeat() { repeatMode = repeatMode.next }

    /// Plays one of the player's playlists from its first track, with the app's list player.
    /// Reading the list is a read-only question; playing uses the approved one-track command.
    func play(playlist: Playlist) async {
        guard let client else { return }
        do {
            let tracks = try await client.playlistTracks(playlist.playlistid)
            guard !tracks.isEmpty else {
                commandProblem = "“\(playlist.name)” has no tracks."
                return
            }
            await play(tracks, title: playlist.name)
        } catch {
            commandProblem = Self.message(for: error)
        }
    }

    /// Plays one of the user's own playlists (a fresh shuffle each time for shuffled ones).
    func play(saved playlist: SavedPlaylist, store: PlaylistStore) async {
        let tracks = songs(of: playlist, store: store, forPlaying: true)
        guard !tracks.isEmpty else {
            commandProblem = "“\(playlist.name)” has no songs yet."
            return
        }
        await play(tracks, title: playlist.name)
    }

    /// The songs a saved playlist has now: hand-picked ones found in the library, automatic
    /// ones filled by their rules. `forPlaying`: shuffled lists get a fresh shuffle and track ids
    /// found again by name are saved (never while drawing a view).
    func songs(of playlist: SavedPlaylist, store: PlaylistStore, forPlaying: Bool = false) -> [Track] {
        let library = self.library?.tracks ?? []
        switch playlist.kind {
        case .handPicked(let entries):
            let resolved = PlaylistResolver.resolve(entries, in: library)
            if forPlaying, let updated = resolved.updatedEntries { store.applyUpdates(updated, to: playlist.id) }
            return resolved.tracks
        case .automatic(let rules):
            return forPlaying ? RuleEngine.tracks(for: rules, in: library, artists: artistIndex)
                : RuleEngine.displayTracks(for: rules, in: library, artists: artistIndex)
        }
    }

    /// Next / previous follow the app's list when one is playing, otherwise the player's.
    func next() async {
        guard var q = queue else { return await send(.next) }
        guard q.skipForward(repeat: repeatMode, shuffled: shuffleOn, shuffle: { $0.shuffle() }) else { return }
        queue = q
        await send(.play(trackID: q.current.trackid))
    }

    func previous() async {
        guard var q = queue else { return await send(.previous) }
        q.skipBack(position: position)
        queue = q
        await send(.play(trackID: q.current.trackid))
    }

    /// Sends one playback command. Commands are never repeated automatically (a second
    /// play/pause would undo the first); if there's no answer we say so and re-read the state.
    func send(_ command: Command) async {
        guard let client else { return }
        if case .play(let id) = command, queue?.tracks.contains(where: { $0.trackid == id }) != true {
            queue = nil  // playing something outside the app's list ends that list
        }
        do {
            switch command {
            case .playPause: try await client.togglePlayPause()
            case .next: try await client.nextTrack()
            case .previous: try await client.previousTrack()
            case .play(let trackID): try await client.playTrack(id: trackID)
            case .seek(let second): try await client.seek(toSecond: second)
            }
            commandProblem = nil
        } catch HAPError.timedOut {
            commandProblem = "No answer from the player. The command may or may not have arrived."
        } catch {
            commandProblem = Self.message(for: error)
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshContent()
    }

    func refreshContent() async {
        guard let client else { return }
        if let fresh = try? await client.playingContent() {
            content = fresh
        } else if connection == .connected {
            content = nil
        }
    }

    /// Keeps the position current (every second while playing, every 4 s otherwise) and moves
    /// the app's list on when a track ends.
    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshContent()
                await self.advanceQueueIfTrackEnded()
                try? await Task.sleep(for: .seconds(self.isPlaying ? 1 : 4))
            }
        }
    }

    private func advanceQueueIfTrackEnded() async {
        guard var q = queue, let content else { return }
        let expected = q.current.trackid
        guard content.trackID == expected else {
            // Something else is playing (front panel, another app): the list is over.
            if Date().timeIntervalSince(q.startedAt) > 15 { queue = nil }
            return
        }
        let playing = content.state == "PLAYING"
        let position = Double(content.positionMsec ?? 0) / 1000
        let duration = Double(content.durationMsec ?? 0) / 1000
        if playing { q.sawPlaying = true }
        let ended = q.sawPlaying && !playing
            && (content.state == "STOPPED" || position >= duration - 2 || (position < 1 && q.lastPosition >= duration - 5))
        q.lastPosition = position
        queue = q
        if ended {
            if q.advanceAfterSongEnded(repeat: repeatMode, shuffled: shuffleOn, shuffle: { $0.shuffle() }) {
                queue = q
                await send(.play(trackID: q.current.trackid))
            } else {
                queue = nil  // the list is finished
            }
        }
    }

    private func startListening() {
        listener?.cancel()
        guard let client else { return }
        listener = Task { [weak self] in
            do {
                for try await event in client.events() {
                    switch event.kind {
                    case .powerstateChanged:
                        self?.power = try? await client.powerStatus()
                    case .playqueueChanged, .playingtrackChanged, .playinginfoChanged:
                        await self?.refreshContent()
                    case .volumeChanged, .other:
                        break
                    }
                }
            } catch {
                // Updates stopped (e.g. the network dropped); the once-a-second check carries on.
            }
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

extension PlayingContent {
    /// "audio:track?id=337" → 337
    var trackID: Int? {
        guard let uri, let range = uri.range(of: "id=") else { return nil }
        return Int(uri[range.upperBound...])
    }
}
