import Foundation
import HAPKit

// Write each line immediately, also when output goes to a file (e.g. a watch log).
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    hap: talk to a Sony HAP-Z1ES / HAP-S1

    Commands:
      hap find               Look for players on the network
      hap info  [--host IP]  Model, firmware, power state, supported file types
      hap now   [--host IP]  What's playing right now
      hap watch [--seconds N]  Show live updates as they happen (Ctrl-C to stop)

    Control (changes something on the player):
      hap toggle             Play/pause: plays if paused, pauses if playing
      hap next               Next track in the queue
      hap previous           Previous track in the queue
      hap play TRACK-ID      Replace the queue with this one track and play it

    Library (saved on this Mac after the first download):
      hap refresh            Download albums, artists, genres, playlists again
      hap albums             List albums          (add --refresh to download first)
      hap artists            List artists
      hap genres             List genres
      hap playlists          List playlists
      hap tracks ALBUM-ID    Tracks of one album (always asked live)

    Without --host (or the HAP_HOST environment variable), hap finds the player itself.
    """

let command = CommandLine.arguments.dropFirst().first ?? "help"
let arguments = Array(CommandLine.arguments.dropFirst(2))

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Uses --host, then HAP_HOST, and otherwise looks for the player with SSDP.
@MainActor func connect() async throws -> (HAPDevice, HAPClient) {
    let device: HAPDevice
    if let host = option("--host") ?? ProcessInfo.processInfo.environment["HAP_HOST"] {
        device = try await HAPDiscovery.device(atHost: host)
    } else {
        guard let found = try await HAPDiscovery.find().first else { throw HAPError.noPlayerFound }
        device = found
    }
    return (device, HAPClient(device: device))
}

/// The saved library lists, downloading them first if there are none (or --refresh was given).
@MainActor func library(forceRefresh: Bool = false) async throws -> LibrarySnapshot {
    let (device, client) = try await connect()
    let store = LibraryStore()
    if !forceRefresh && !arguments.contains("--refresh"), let saved = store.load(playerUDN: device.udn) {
        let minutes = Int(Date().timeIntervalSince(saved.fetchedAt) / 60)
        FileHandle.standardError.write(Data("(saved copy from \(minutes) min ago; add --refresh to download again)\n".utf8))
        return saved
    }
    let start = ContinuousClock.now
    FileHandle.standardError.write(Data("Downloading the library from the player…\n".utf8))
    let fresh = try await store.refresh(from: client, playerUDN: device.udn)
    FileHandle.standardError.write(Data("(downloaded in \(start.duration(to: .now).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))))\n".utf8))
    return fresh
}

/// For commands that only need the control API: with an address, talk to it directly
/// (skips the 3 KB hap.xml, the answer most likely to be stalled by a lost packet).
@MainActor func controlClient() async throws -> HAPClient {
    if let host = option("--host") ?? ProcessInfo.processInfo.environment["HAP_HOST"] {
        return HAPClient(host: host)
    }
    return try await connect().1
}

/// Sends a command once. If no answer arrives, it may or may not have reached the
/// player, so we don't resend it: we look at what the player is doing instead.
@MainActor func command(_ label: String, _ send: (HAPClient) async throws -> Void) async throws {
    let client = try await controlClient()
    do {
        try await send(client)
        print("Sent \(label).")
    } catch HAPError.timedOut {
        print("No answer to \(label): it may or may not have arrived. Not resending. Checking the player…")
        try await Task.sleep(for: .seconds(2))
        if let now = try await client.playingContent() {
            print("Player now: \(now.state?.capitalized ?? "?") \(now.title ?? "") "
                + "(track \(now.listIndex ?? 0) of \(now.listCount ?? 0), \(time(now.positionMsec)))")
        } else {
            print("Player now: nothing loaded.")
        }
    }
}

func clock() -> String {
    Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
}

func describe(_ info: PlayingInfo?) -> String {
    guard let info, let track = info.track else { return "nothing loaded" }
    return "\(info.playbackState ?? "?"): \(track.name) — \(named(track.artist?.name ?? "", "?"))"
        + " [album \(named(track.album?.name ?? "", "?")), track id \(track.trackid)]"
        + " · queue position \(info.playqueuePosition ?? 0), queue version \(info.playqueueVersion ?? 0)"
}

func printQueue(_ client: HAPClient) async throws {
    let queue = try await client.playQueue().playlist
    print("  queue: \(queue.name) · \(tracks(queue.numberOfTracks)) · version \(queue.version ?? 0)")
    for (index, track) in try await client.playQueueTracks(limit: 20).enumerated() {
        print(String(format: "   %2d. ", index + 1) + "\(track.name) — \(named(track.artist?.name ?? "", "?"))"
            + "  [album \(named(track.album?.name ?? "", "?")) #\(track.album?.albumid ?? 0), track id \(track.trackid)]")
    }
}

func named(_ name: String, _ fallback: String) -> String { name.isEmpty ? fallback : name }

func tracks(_ count: Int?) -> String { count == 1 ? "1 track" : "\(count ?? 0) tracks" }

func time(_ milliseconds: Int?) -> String {
    guard let milliseconds else { return "--:--" }
    let seconds = milliseconds / 1000
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func printDevice(_ device: HAPDevice) {
    print("\(device.friendlyName) (\(device.modelName)) at \(device.host)")
    print("  unique ID:  \(device.udn)")
    print("  MAC:        \(device.macAddress ?? "?")")
    print("  firmware:   \(device.firmwareVersion ?? "?")")
    print("  control:    \(device.apiBaseURL.absoluteString)")
}

do {
    switch command {
    case "find":
        print("Looking for players (3 seconds)…")
        let devices = try await HAPDiscovery.find()
        if devices.isEmpty { throw HAPError.noPlayerFound }
        for device in devices { printDevice(device) }

    case "info":
        let (device, client) = try await connect()
        printDevice(device)
        let power = try await client.powerStatus()
        print("  power:      \(power.status)")
        let system = try await client.systemInformation()
        print("  generation: \(system.generation ?? "?")")
        let types = try await client.supportedFileTypes()
        print("  file types: \(types.map { $0.replacingOccurrences(of: "*.", with: "") }.joined(separator: " "))")

    case "now":
        let client = try await controlClient()
        guard let now = try await client.playingContent() else {
            print("Nothing loaded.")
            break
        }
        print("\(now.state?.capitalized ?? "?"): \(now.title ?? "(no title)")")
        print("  artist:  \(now.artist ?? "?")")
        print("  album:   \(now.albumName ?? "?")")
        print("  time:    \(time(now.positionMsec)) / \(time(now.durationMsec))")
        print("  format:  \(now.formatDescription)")
        if let index = now.listIndex, let count = now.listCount {
            print("  queue:   track \(index) of \(count)")
        }

    case "toggle":
        try await command("play/pause") { try await $0.togglePlayPause() }

    case "next":
        try await command("next track") { try await $0.nextTrack() }

    case "previous":
        try await command("previous track") { try await $0.previousTrack() }

    case "play":
        guard let trackID = arguments.first.flatMap(Int.init) else {
            print("Usage: hap play TRACK-ID   (see hap tracks ALBUM-ID for the ids)")
            exit(2)
        }
        try await command("play track \(trackID)") { try await $0.playTrack(id: trackID) }

    case "watch":
        let client = try await controlClient()
        let seconds = option("--seconds").flatMap(Double.init)
        print("[\(clock())] now: \(describe(try await client.playingInfo()))")
        do { try await printQueue(client) } catch { print("  queue: (empty or unreadable)") }
        print("Listening for updates\(seconds.map { " for \(Int($0)) s" } ?? " (Ctrl-C to stop)")…")
        let watcher = Task {
            for try await event in client.events() {
                print("[\(clock())] \(event.name) (#\(event.sequence))")
                switch event.kind {
                case .playingtrackChanged, .playinginfoChanged:
                    print("  \(describe(try await client.playingInfo()))")
                case .playqueueChanged:
                    do { try await printQueue(client) } catch { print("  queue: (empty or unreadable)") }
                case .powerstateChanged:
                    print("  power: \(try await client.powerStatus().status)")
                case .volumeChanged, .other:
                    print("  (read at \(event.url?.path ?? "?"))")
                }
            }
        }
        if let seconds {
            try await Task.sleep(for: .seconds(seconds))
            watcher.cancel()
            print("[\(clock())] Stopped after \(Int(seconds)) s.")
        } else {
            try await watcher.value
        }

    case "refresh":
        let snapshot = try await library(forceRefresh: true)
        print("\(snapshot.albums.count) albums, \(snapshot.artists.count) artists, "
            + "\(snapshot.genres.count) genres, \(snapshot.playlists.count) playlists")

    case "albums":
        for album in try await library().albums {
            let artist = named(album.albumArtist?.name ?? "", "?")
            let year = album.releaseDate.flatMap { $0 == "0" ? nil : " (\($0))" } ?? ""
            let count = album.numberOfTracks.map { " · \(tracks($0))" } ?? ""
            print(String(format: "%6d  ", album.albumid) + "\(artist) — \(named(album.name, "(no album name)"))\(year)\(count)")
        }

    case "artists":
        for artist in try await library().artists {
            print(String(format: "%6d  ", artist.artistid) + "\(named(artist.name, "(no artist name)")) · \(tracks(artist.numberOfTracks))")
        }

    case "genres":
        for genre in try await library().genres {
            print(String(format: "%6d  ", genre.genreid) + "\(named(genre.name, "(no genre)")) · \(tracks(genre.numberOfTracks))")
        }

    case "playlists":
        for playlist in try await library().playlists {
            print(String(format: "%6d  ", playlist.playlistid) + "\(playlist.name) · \(tracks(playlist.numberOfTracks))")
        }

    case "tracks":
        guard let albumID = arguments.first.flatMap(Int.init) else {
            print("Usage: hap tracks ALBUM-ID   (see hap albums for the ids)")
            exit(2)
        }
        let client = try await controlClient()
        let tracks = try await client.tracks(inAlbum: albumID)
        if tracks.isEmpty { print("No tracks (unknown album id?)") }
        for track in tracks {
            let number = track.trackNumber.map { $0 > 0 ? String(format: "%2d.", $0) : " -." } ?? " -."
            let length = time(track.duration.map { $0 * 1000 })
            let format = [track.codec?.codecType?.uppercased(),
                          track.codec?.sampleRate.map { String(format: "%g kHz", Double($0) / 1000) },
                          track.codec?.bitWidth.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: " ")
            print("\(number) \(track.name) — \(named(track.artist?.name ?? "", "?"))  [\(length), \(format)]  id \(track.trackid)")
        }

    default:
        print(usage)
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("hap: \(message)\n".utf8))
    exit(1)
}
