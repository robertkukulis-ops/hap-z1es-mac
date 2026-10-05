import HAPKit
import SwiftUI

/// Pages you can open from a list (the back button returns).
enum Page: Hashable {
    case album(Int)
    case artist(String)
    case genre(String)
}

// MARK: - Albums

struct AlbumsGridView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(CoverArtStore.self) private var covers
    @AppStorage("albumSort") private var sort = AlbumSort.artist

    enum AlbumSort: String, CaseIterable, Identifiable {
        case artist = "Artist", title = "Title", year = "Year"
        var id: Self { self }
    }

    var body: some View {
        if let albums = player.library?.albums {
            ScrollView {
                AlbumGrid(albums: sorted(albums))
                    .padding(20)
            }
            .navigationTitle("Albums")
            .navigationSubtitle("\(albums.count) albums")
            .toolbar {
                ToolbarItem {
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Sort albums")
                }
                ToolbarItem { FindCoversButton() }
            }
        } else {
            LibraryPlaceholder()
        }
    }

    private func sorted(_ albums: [Album]) -> [Album] {
        switch sort {
        case .artist:
            albums.sorted { (sortName($0.albumArtist?.name), $0.releaseDate ?? "", $0.name) < (sortName($1.albumArtist?.name), $1.releaseDate ?? "", $1.name) }
        case .title:
            albums.sorted { sortName($0.name) < sortName($1.name) }
        case .year:
            albums.sorted { ($0.releaseDate ?? "0", $0.name) > ($1.releaseDate ?? "0", $1.name) }
        }
    }
}

/// Sorts empty names last and ignores "The " and case.
func sortName(_ name: String?) -> String {
    let n = (name ?? "").trimmingCharacters(in: .whitespaces)
    if n.isEmpty { return "~~~" }
    let lower = n.lowercased()
    return lower.hasPrefix("the ") ? String(lower.dropFirst(4)) : lower
}

struct AlbumGrid: View {
    let albums: [Album]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)],
                  alignment: .leading, spacing: 24) {
            ForEach(albums) { album in
                NavigationLink(value: Page.album(album.albumid)) {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AlbumCard: View {
    @Environment(PlayerModel.self) private var player
    @Environment(CoverArtStore.self) private var covers
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(album: album)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(named(album.name, "Untitled album"))
                .font(.callout.weight(.medium))
                .foregroundStyle(album.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Text([named(album.albumArtist?.name, "Unknown artist"), year(album.releaseDate)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Play Album") {
                Task { await player.play(player.tracks(of: album), title: album.name) }
            }
            AddToPlaylistMenu(title: "Add Album to Playlist") { player.tracks(of: album) }
            CoverMenuItems(album: album)
            Divider()
            DeleteAlbumButton(album: album)
        }
    }
}

struct AlbumDetailView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(CoverArtStore.self) private var covers
    let album: Album

    var body: some View {
        let tracks = player.tracks(of: album)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 24) {
                    ArtworkView(album: album, cornerRadius: 8)
                        .frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .contextMenu { CoverMenuItems(album: album) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Album").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(named(album.name, "Untitled album")).font(.largeTitle.weight(.bold)).lineLimit(2)
                        NavigationLink(value: Page.artist(album.albumArtist?.name ?? "")) {
                            Text(named(album.albumArtist?.name, "Unknown artist")).font(.title2)
                        }
                        .buttonStyle(.link)
                        .disabled((album.albumArtist?.name ?? "").isEmpty)
                        Text([year(album.releaseDate), "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")",
                              duration(album.duration), formatText(tracks.first?.codec)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                Task { await player.play(tracks, title: album.name) }
                            } label: {
                                Label("Play", systemImage: "play.fill").frame(minWidth: 70)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(tracks.isEmpty)
                            Menu {
                                AddToPlaylistMenu(title: "Add Album to Playlist") { tracks }
                                CoverMenuItems(album: album)
                                Divider()
                                DeleteAlbumButton(album: album)
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 30)
                            .help("More")
                        }
                        .padding(.top, 6)
                    }
                }
                TrackTable(tracks: tracks, queueTitle: album.name, showAlbum: false, enterPlaysAll: true)
                    .frame(minHeight: CGFloat(max(tracks.count, 3)) * 26 + 40)
            }
            .padding(24)
        }
        .navigationTitle(named(album.name, "Album"))
    }
}

/// Right-click items for covers the app found (not ones stored on the player).
struct CoverMenuItems: View {
    @Environment(CoverArtStore.self) private var covers
    let album: Album

    var body: some View {
        if album.image == nil {
            Divider()
            Button("Find Cover Online") { Task { await covers.findCover(for: album) } }
            if covers.albumImage(album) != nil {
                Button("Use a Different Cover") { Task { await covers.reject(album: album) } }
                Button("Remove Found Cover") { covers.remove(album: album) }
            }
        }
    }
}

struct DeleteAlbumButton: View {
    @Environment(PlayerModel.self) private var player
    @Environment(DriveModel.self) private var drive
    let album: Album

    var body: some View {
        Button("Delete Album from Player…", role: .destructive) {
            Task { await drive.requestDeletion(of: player.tracks(of: album), player: player) }
        }
    }
}

struct FindCoversButton: View {
    @Environment(PlayerModel.self) private var player
    @Environment(CoverArtStore.self) private var covers

    var body: some View {
        if covers.isSearching {
            Button {
                covers.stop()
            } label: {
                Label("Finding covers \(covers.progress.done)/\(covers.progress.total)… (Stop)", systemImage: "stop.circle")
            }
            .help("Stop looking up covers")
        } else {
            Button {
                covers.findMissing(albums: player.library?.albums ?? [],
                                   artists: (player.library?.artists ?? []).map(\.name))
            } label: {
                Label("Find Missing Covers", systemImage: "photo.badge.magnifyingglass")
            }
            .help("Look up covers the player doesn't have (Apple, Deezer, MusicBrainz), and artist pictures. Only names are sent; your music files aren't changed.")
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if player.library != nil {
            let artists = player.artistIndex.entries
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20, alignment: .top)], spacing: 24) {
                    ForEach(artists) { artist in
                        NavigationLink(value: Page.artist(artist.name)) {
                            VStack(spacing: 6) {
                                ArtistPicture(name: artist.name).frame(width: 110, height: 110)
                                Text(artist.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                                Text(artist.own.isEmpty ? "appears on \(countText(artist.guest.count, "track"))"
                                     : countText(artist.trackCount, "track"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Artists")
            .navigationSubtitle("\(artists.count) artists")
            .toolbar { ToolbarItem { FindCoversButton() } }
        } else {
            LibraryPlaceholder()
        }
    }
}

struct ArtistPicture: View {
    @Environment(CoverArtStore.self) private var covers
    let name: String

    var body: some View {
        Group {
            if let image = covers.artistImage(name) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(hue: Double(stableHash(CoverArtStore.normalized(name)) % 360) / 360, saturation: 0.35, brightness: 0.55))
                    Text(initials(name)).font(.title.weight(.semibold)).foregroundStyle(.white)
                }
            }
        }
        .clipShape(Circle())
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct ArtistDetailView: View {
    @Environment(PlayerModel.self) private var player
    let name: String

    var body: some View {
        let entry = player.artistIndex.entry(named: name)
        let tracks = entry?.own ?? []
        let guestTracks = (entry?.guest ?? []).sorted { sortName($0.artist?.name) < sortName($1.artist?.name) }
        let shownName = entry?.name ?? name
        let albumIDs = Set(tracks.compactMap { $0.album?.albumid })
        let albums = (player.library?.albums ?? []).filter { albumIDs.contains($0.albumid) }
            .sorted { ($0.releaseDate ?? "", $0.name) < ($1.releaseDate ?? "", $1.name) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    ArtistPicture(name: shownName).frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Artist").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(shownName).font(.largeTitle.weight(.bold))
                        Text([countText(albums.count, "album"), countText(tracks.count, "track"),
                              guestTracks.isEmpty ? nil : "guest on \(countText(guestTracks.count, "track"))"]
                                .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await player.play(tracks.sorted(by: PlayerModel.albumOrder) + guestTracks, title: shownName) }
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty && guestTracks.isEmpty)
                    }
                }
                if !albums.isEmpty {
                    Text("Albums").font(.title2.weight(.semibold))
                    AlbumGrid(albums: albums)
                }
                if !guestTracks.isEmpty {
                    // Songs where this artist is the "feat." guest.
                    Text("Also appears on").font(.title2.weight(.semibold))
                    TrackTable(tracks: guestTracks, queueTitle: "\(shownName) (guest)", showAlbum: true)
                        .frame(height: CGFloat(min(guestTracks.count, 12)) * 26 + 40)
                }
            }
            .padding(24)
        }
        .navigationTitle(shownName)
    }
}

// MARK: - Genres

struct GenresView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let library = player.library {
            let genres = library.genres.filter { !$0.name.isEmpty }.sorted { $0.name < $1.name }
            List(genres) { genre in
                NavigationLink(value: Page.genre(genre.name)) {
                    HStack {
                        Image(systemName: "guitars").foregroundStyle(.secondary).frame(width: 24)
                        Text(genre.name)
                        Spacer()
                        Text(countText(genre.numberOfTracks, "track")).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            .navigationTitle("Genres")
            .navigationSubtitle("\(genres.count) genres")
        } else {
            LibraryPlaceholder()
        }
    }
}

struct GenreDetailView: View {
    @Environment(PlayerModel.self) private var player
    let name: String

    var body: some View {
        let tracks = (player.library?.tracks ?? []).filter { $0.genre?.name == name }
            .sorted { (sortName($0.artist?.name), $0.album?.name ?? "", $0.trackNumber ?? 0) < (sortName($1.artist?.name), $1.album?.name ?? "", $1.trackNumber ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name).font(.largeTitle.weight(.bold))
                Spacer()
                Button {
                    Task { await player.play(tracks, title: name) }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
            }
            .padding([.horizontal, .top], 24)
            TrackTable(tracks: tracks, queueTitle: name, showAlbum: true)
        }
        .navigationTitle(name)
    }
}

// MARK: - Tracks

struct TracksView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let tracks = player.library?.tracks, !tracks.isEmpty {
            TrackTable(tracks: tracks.sorted { (sortName($0.artist?.name), $0.album?.name ?? "") < (sortName($1.artist?.name), $1.album?.name ?? "") },
                       queueTitle: "Tracks", showAlbum: true)
                .navigationTitle("Tracks")
                .navigationSubtitle("\(tracks.count) tracks")
        } else {
            LibraryPlaceholder()
        }
    }
}

/// A sortable table of tracks. Double-click plays that track and the rest of the list after it.
struct TrackTable: View {
    @Environment(PlayerModel.self) private var player
    @Environment(DriveModel.self) private var drive
    let tracks: [Track]
    let queueTitle: String
    let showAlbum: Bool
    var enterPlaysAll = false
    /// Delete key / "Delete from Player…" (off on playlist pages, where Delete means the list).
    var deletesFromPlayer = true
    /// Rows can be dragged onto a playlist (only useful on the PLAYLISTS page; elsewhere a
    /// click-drag selects a range of rows instead).
    var draggableRows = false
    @State private var selection = Set<Track.ID>()
    @State private var order: [KeyPathComparator<Track>] = []

    var body: some View {
        let rows = order.isEmpty ? tracks : tracks.sorted(using: order)
        Table(of: Track.self, selection: $selection, sortOrder: $order) {
            TableColumn("") { track in
                if player.content?.trackID == track.trackid {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                } else {
                    Text(track.trackNumber.map { $0 > 0 ? "\($0)" : "" } ?? "").foregroundStyle(.secondary)
                }
            }
            .width(28)
            TableColumn("Title", value: \.name)
            TableColumn("Artist", value: \.artistName)
            if showAlbum {
                TableColumn("Album", value: \.albumName)
            }
            TableColumn("Time", value: \.lengthForSorting) { Text(duration($0.duration) ?? "").monospacedDigit() }
                .width(56)
            TableColumn("Format") { Text(formatText($0.codec) ?? "").foregroundStyle(.secondary) }
                .width(min: 110, ideal: 140)
        } rows: {
            // Dragged rows carry the selected songs, if the row is one of them.
            let selectedIDs = rows.filter { selection.contains($0.id) }.map(\.trackid)
            ForEach(rows) { track in
                if draggableRows {
                    TableRow(track).draggable(DraggedTracks(ids: selection.contains(track.id) ? selectedIDs : [track.trackid]))
                } else {
                    TableRow(track)
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)  // plain blue rows, as on the HAP's screen
        .onDeleteCommand {
            if deletesFromPlayer, !selection.isEmpty { delete(selection, from: rows) }
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if let id = ids.first, let index = rows.firstIndex(where: { $0.id == id }) {
                Button("Play") { Task { await player.play(rows, from: index, title: queueTitle) } }
                Button("Play Only This Track") { Task { await player.play([rows[index]], title: rows[index].name) } }
            }
            if !ids.isEmpty {
                AddToPlaylistMenu { rows.filter { ids.contains($0.id) } }
                if deletesFromPlayer {
                    Divider()
                    Button(ids.count == 1 ? "Delete from Player…" : "Delete \(ids.count) Tracks from Player…", role: .destructive) {
                        delete(ids, from: rows)
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let index = rows.firstIndex(where: { $0.id == id }) {
                Task { await player.play(rows, from: index, title: queueTitle) }
            }
        }
        .onRackEnter {
            // ENTER: play from the first selected track; on an album page, the whole album
            // when nothing is selected.
            let rows = order.isEmpty ? tracks : tracks.sorted(using: order)
            if let index = rows.firstIndex(where: { selection.contains($0.id) }) {
                Task { await player.play(rows, from: index, title: queueTitle) }
            } else if enterPlaysAll, !rows.isEmpty {
                Task { await player.play(rows, title: queueTitle) }
            }
        }
    }
}

extension TrackTable {
    func delete(_ ids: Set<Track.ID>, from rows: [Track]) {
        let chosen = rows.filter { ids.contains($0.id) }
        Task { await drive.requestDeletion(of: chosen, player: player) }
    }
}

extension Track {
    var artistName: String { artist?.name ?? "" }
    var albumName: String { album?.name ?? "" }
    var lengthForSorting: Int { duration ?? 0 }
}

// MARK: - Search

struct SearchResultsView: View {
    @Environment(PlayerModel.self) private var player
    let text: String

    var body: some View {
        let library = player.library
        let albums = (library?.albums ?? []).filter { $0.name.localizedCaseInsensitiveContains(text) || ($0.albumArtist?.name ?? "").localizedCaseInsensitiveContains(text) }
        let artists = player.artistIndex.entries.filter { $0.name.localizedCaseInsensitiveContains(text) }
        let tracks = (library?.tracks ?? []).filter { $0.name.localizedCaseInsensitiveContains(text) || $0.artistName.localizedCaseInsensitiveContains(text) || $0.albumName.localizedCaseInsensitiveContains(text) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if albums.isEmpty && artists.isEmpty && tracks.isEmpty {
                    ContentUnavailableView.search(text: text).frame(maxWidth: .infinity)
                }
                if !artists.isEmpty {
                    Text("Artists").font(.title2.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(artists.prefix(20)) { artist in
                                NavigationLink(value: Page.artist(artist.name)) {
                                    VStack {
                                        ArtistPicture(name: artist.name).frame(width: 80, height: 80)
                                        Text(artist.name).font(.caption).lineLimit(1).frame(width: 96)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !albums.isEmpty {
                    Text("Albums").font(.title2.weight(.semibold))
                    AlbumGrid(albums: Array(albums.prefix(24)))
                }
                if !tracks.isEmpty {
                    Text("Tracks").font(.title2.weight(.semibold))
                    TrackTable(tracks: Array(tracks.prefix(200)), queueTitle: "Search: \(text)", showAlbum: true)
                        .frame(height: CGFloat(min(tracks.count, 12)) * 26 + 40)
                }
            }
            .padding(24)
        }
        .navigationTitle("Search")
    }
}

// MARK: - Shared

struct LibraryPlaceholder: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let error = player.libraryError {
            ContentUnavailableView("Library not loaded", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if case .failed(let message) = player.connection {
            ContentUnavailableView {
                Label("Player not found", systemImage: "hifispeaker")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await player.connect() } }
            }
        } else if player.connection != .connected {
            ContentUnavailableView("Player not connected", systemImage: "hifispeaker",
                                   description: Text("The library appears once the player is found."))
        } else {
            ProgressView("Loading the library…")
        }
    }
}

func countText(_ count: Int?, _ word: String) -> String {
    let n = count ?? 0
    return "\(n) \(word)\(n == 1 ? "" : "s")"
}

func year(_ date: String?) -> String? {
    guard let date, date.count >= 4, date != "0" else { return nil }
    return String(date.prefix(4))
}

func named(_ name: String?, _ fallback: String) -> String {
    guard let name, !name.isEmpty else { return fallback }
    return name
}

/// e.g. "FLAC · 44.1 kHz / 24-bit"
func formatText(_ codec: Track.Codec?) -> String? {
    guard let codec else { return nil }
    var parts: [String] = []
    if let type = codec.codecType, !type.isEmpty { parts.append(type.uppercased()) }
    var quality: [String] = []
    if let rate = codec.sampleRate {
        quality.append(rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000))
    }
    if let bits = codec.bitWidth { quality.append("\(bits)-bit") }
    if !quality.isEmpty { parts.append(quality.joined(separator: " / ")) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Seconds → "4:59" or "1:02:03".
func duration(_ seconds: Int?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
