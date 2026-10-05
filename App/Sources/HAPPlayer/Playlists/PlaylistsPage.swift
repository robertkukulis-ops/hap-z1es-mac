import AppKit
import HAPKit
import SwiftUI
import UniformTypeIdentifiers

/// Which list is chosen on the PLAYLISTS page: one of the user's, or one of the player's own.
enum PlaylistChoice: Hashable {
    case mine(UUID)
    case player(Int)
}

/// The PLAYLISTS page: the lists on the left, the chosen list's songs on the right.
struct PlaylistsPage: View {
    @Environment(PlayerModel.self) private var player
    @Environment(PlaylistStore.self) private var store
    @Environment(RackState.self) private var rack
    @State private var choice: PlaylistChoice?
    @State private var editing: RuleEditorRequest?
    @State private var renaming: SavedPlaylist?
    @State private var newName = ""
    @State private var deleting: SavedPlaylist?
    /// The playlist songs are being dragged over, lit up so it's clear where they'll go.
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 0) {
            lists.frame(width: 250)
            Rectangle().fill(ScreenTheme.divider).frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $editing) { request in
            RuleEditorSheet(request: request) { name, rules in
                if let id = request.playlistID {
                    store.rename(id, to: name)
                    store.setRules(id, rules)
                } else {
                    choice = .mine(store.newAutomatic(name: name, rules: rules))
                }
            }
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { store.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let deleting {
                    if choice == .mine(deleting.id) { choice = nil }
                    store.delete(deleting.id)
                }
            }
        } message: {
            Text("Only the list is deleted. The songs stay on the player.")
        }
    }

    // MARK: - Left: the lists

    private var lists: some View {
        List(selection: $choice) {
            Section("Your playlists") {
                if store.playlists.isEmpty {
                    Text("None yet").foregroundStyle(ScreenTheme.dim)
                }
                ForEach(store.playlists) { saved in
                    HStack {
                        Label(saved.name, systemImage: saved.isAutomatic ? "gearshape" : "music.note.list")
                        Spacer()
                        Text("\(player.songs(of: saved, store: store).count)").foregroundStyle(ScreenTheme.dim).monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5))
                        .opacity(dropTarget == saved.id ? 1 : 0))
                    .tag(PlaylistChoice.mine(saved.id))
                    .dropDestination(for: String.self) { texts, _ in
                        // Songs dragged from a track list onto a hand-picked playlist.
                        guard !saved.isAutomatic else { return false }
                        let ids = texts.compactMap(DraggedTracks.ids(in:)).flatMap { $0 }
                        let byID = Dictionary((player.library?.tracks ?? []).map { ($0.trackid, $0) }, uniquingKeysWith: { a, _ in a })
                        let songs = ids.compactMap { byID[$0] }
                        guard !songs.isEmpty else { return false }
                        store.add(songs, to: saved.id, library: player.library?.tracks ?? [])
                        return true
                    } isTargeted: { over in
                        // Only hand-picked lists take songs, so only they light up.
                        if over, !saved.isAutomatic { dropTarget = saved.id } else if dropTarget == saved.id { dropTarget = nil }
                    }
                }
            }
            Section("On the player") {
                ForEach(player.library?.playlists ?? []) { list in
                    Label(list.name, systemImage: "hifispeaker").tag(PlaylistChoice.player(list.playlistid))
                }
            }
        }
        // Right-click a list for its menu; double-click plays it (yours and the player's).
        .contextMenu(forSelectionType: PlaylistChoice.self) { choices in
            if let choice = choices.first { menu(for: choice) }
        } primaryAction: { choices in
            if let choice = choices.first { play(choice) }
        }
        .onChange(of: choice, initial: true) { rack.pageName = name(of: choice) }
        .onChange(of: store.playlists) { rack.pageName = name(of: choice) }
        .onDisappear { rack.pageName = nil }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button { choice = .mine(store.newHandPicked()) } label: { Label("New Playlist", systemImage: "plus") }
                Button { editing = RuleEditorRequest(playlistID: nil, name: store.uniqueName("New Automatic Playlist"),
                                                     rules: PlaylistRules(match: .all, rules: [.year(from: 1970, to: 1979)],
                                                                          limit: nil, order: .shuffled)) } label: {
                    Label("New Automatic Playlist", systemImage: "gearshape")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func menu(for choice: PlaylistChoice) -> some View {
        switch choice {
        case .mine(let id):
            if let saved = store.playlists.first(where: { $0.id == id }) { menu(for: saved) }
        case .player:
            Button("Play") { play(choice) }
        }
    }

    private func play(_ choice: PlaylistChoice) {
        switch choice {
        case .mine(let id):
            if let saved = store.playlists.first(where: { $0.id == id }) {
                Task { await player.play(saved: saved, store: store) }
            }
        case .player(let id):
            if let list = player.library?.playlists.first(where: { $0.playlistid == id }) {
                Task { await player.play(playlist: list) }
            }
        }
    }

    private func name(of choice: PlaylistChoice?) -> String? {
        switch choice {
        case .mine(let id): store.playlists.first { $0.id == id }?.name
        case .player(let id): player.library?.playlists.first { $0.playlistid == id }?.name
        case nil: nil
        }
    }

    @ViewBuilder private func menu(for saved: SavedPlaylist) -> some View {
        Button("Play") { Task { await player.play(saved: saved, store: store) } }
        Divider()
        Button("Rename…") { newName = saved.name; renaming = saved }
        Button("Duplicate") { choice = .mine(store.duplicate(saved.id)) }
        if case .automatic(let rules) = saved.kind {
            Button("Duplicate as Hand-Picked") {
                choice = .mine(store.duplicate(saved.id, asHandPicked: player.songs(of: saved, store: store)))
            }
            Button("Edit Rules…") { editing = RuleEditorRequest(playlistID: saved.id, name: saved.name, rules: rules) }
        }
        Button("Export…") { export(saved) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = saved }
    }

    // MARK: - Right: the songs

    @ViewBuilder private var detail: some View {
        switch choice {
        case .mine(let id):
            if let saved = store.playlists.first(where: { $0.id == id }) {
                MyPlaylistDetail(saved: saved) { export(saved) } editRules: { rules in
                    editing = RuleEditorRequest(playlistID: saved.id, name: saved.name, rules: rules)
                }
            } else {
                ContentUnavailableView("Choose a playlist", systemImage: "music.note.list")
            }
        case .player(let id):
            PlayerPlaylistDetail(playlistID: id, name: player.library?.playlists.first { $0.playlistid == id }?.name ?? "Playlist")
        case nil:
            ContentUnavailableView("Choose a playlist", systemImage: "music.note.list",
                                   description: Text("Or make one: “New Playlist”, then right-click songs anywhere → Add to Playlist."))
        }
    }

    private func export(_ saved: SavedPlaylist) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText]
        panel.nameFieldStringValue = "\(saved.name).m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = M3UExport.text(name: saved.name, tracks: player.songs(of: saved, store: store), paths: player.trackPaths)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.report("“\(saved.name)” couldn't be exported: \(error.localizedDescription)")
        }
    }
}

/// Header line: "23 songs · 1 h 32 min".
func playlistSummary(_ tracks: [Track]) -> String {
    let seconds = tracks.compactMap(\.duration).reduce(0, +)
    let length = seconds >= 3600 ? "\(seconds / 3600) h \(seconds % 3600 / 60) min" : "\(seconds / 60) min"
    return "\(countText(tracks.count, "song")) · \(length)"
}

/// One of the user's playlists: hand-picked ones can be reordered and edited, automatic ones
/// show what their rules give now.
private struct MyPlaylistDetail: View {
    @Environment(PlayerModel.self) private var player
    @Environment(PlaylistStore.self) private var store
    let saved: SavedPlaylist
    let export: () -> Void
    let editRules: (PlaylistRules) -> Void

    private var isShuffled: Bool {
        if case .automatic(let rules) = saved.kind { return rules.order == .shuffled }
        return false
    }

    var body: some View {
        let library = player.library?.tracks ?? []
        let resolved: ResolvedPlaylist? = if case .handPicked(let entries) = saved.kind {
            PlaylistResolver.resolve(entries, in: library)
        } else { nil }
        let tracks = resolved?.tracks ?? player.songs(of: saved, store: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.name).font(.title2.weight(.semibold))
                    Text(saved.isAutomatic ? "Automatic · " + playlistSummary(tracks) + (isShuffled ? " · shuffled when played" : "")
                         : playlistSummary(tracks))
                        .foregroundStyle(ScreenTheme.dim)
                }
                Spacer()
                if case .automatic(let rules) = saved.kind {
                    Button("Edit Rules…") { editRules(rules) }
                }
                Button("Export…", action: export)
                Button { Task { await player.play(saved: saved, store: store) } } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(tracks.isEmpty)
            }
            .padding([.horizontal, .top], 16)
            switch saved.kind {
            case .handPicked:
                if tracks.isEmpty, let hidden = resolved?.hiddenCount, hidden > 0 {
                    // Saved songs exist, but none can be found right now.
                    if library.isEmpty {
                        ProgressView("Loading the library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Songs not on the player", systemImage: "music.note",
                                               description: Text("\(countText(hidden, "song")) of this list aren't on the player right now. They come back if the songs are copied to it again."))
                    }
                } else if tracks.isEmpty {
                    ContentUnavailableView("No songs yet", systemImage: "music.note",
                                           description: Text("Right-click songs in any list, album or folder → Add to Playlist."))
                } else if let resolved {
                    PlaylistSongList(tracks: resolved.tracks, title: saved.name) { rows, row in
                        store.moveRows(rows, to: row, using: resolved, in: saved.id)
                    } onRemove: { rows in
                        store.removeRows(rows, using: resolved, from: saved.id)
                    }
                }
            case .automatic:
                if tracks.isEmpty {
                    ContentUnavailableView("No songs match yet", systemImage: "gearshape",
                                           description: Text("New songs that fit the rules appear here by themselves."))
                } else {
                    TrackTable(tracks: tracks, queueTitle: saved.name, showAlbum: true, enterPlaysAll: true,
                               deletesFromPlayer: false, draggableRows: true)
                }
            }
        }
    }
}

/// A hand-picked playlist's songs: drag to reorder, Delete or right-click to remove from the
/// list (never from the player), double-click or ENTER to play.
private struct PlaylistSongList: View {
    @Environment(PlayerModel.self) private var player
    let tracks: [Track]
    let title: String
    let onMove: (IndexSet, Int) -> Void
    let onRemove: (IndexSet) -> Void
    @State private var selection = Set<Track.ID>()

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 10) {
                    Text("\(index + 1)").foregroundStyle(ScreenTheme.dim).monospacedDigit().frame(width: 26, alignment: .trailing)
                    if player.content?.trackID == track.trackid {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    }
                    Text(track.name).lineLimit(1)
                    Text(track.artistName).foregroundStyle(ScreenTheme.dim).lineLimit(1)
                    Spacer()
                    Text(duration(track.duration) ?? "").foregroundStyle(ScreenTheme.dim).monospacedDigit()
                }
                .tag(track.id)
            }
            .onMove(perform: onMove)
        }
        .onDeleteCommand { removeSelected() }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if let index = tracks.firstIndex(where: { ids.contains($0.id) }) {
                Button("Play from Here") { Task { await player.play(tracks, from: index, title: title) } }
            }
            if !ids.isEmpty {
                AddToPlaylistMenu(title: "Add to Another Playlist") { tracks.filter { ids.contains($0.id) } }
                Button(ids.count == 1 ? "Remove from Playlist" : "Remove \(ids.count) Songs from Playlist") {
                    onRemove(IndexSet(tracks.indices.filter { ids.contains(tracks[$0].id) }))
                }
            }
        } primaryAction: { ids in
            if let index = tracks.firstIndex(where: { ids.contains($0.id) }) {
                Task { await player.play(tracks, from: index, title: title) }
            }
        }
        .onRackEnter {
            let start = tracks.firstIndex { selection.contains($0.id) }  // nil: like the Play button
            if !tracks.isEmpty { Task { await player.play(tracks, from: start, title: title) } }
        }
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        onRemove(IndexSet(tracks.indices.filter { selection.contains(tracks[$0].id) }))
        selection = []
    }
}

/// One of the player's own lists (Newly Added…), read from the player; play only.
private struct PlayerPlaylistDetail: View {
    @Environment(PlayerModel.self) private var player
    let playlistID: Int
    let name: String
    @State private var tracks: [Track]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title2.weight(.semibold))
                Text("On the player" + (tracks.map { " · " + playlistSummary($0) } ?? "")).foregroundStyle(ScreenTheme.dim)
            }
            .padding([.horizontal, .top], 16)
            if let tracks {
                TrackTable(tracks: tracks, queueTitle: name, showAlbum: true, enterPlaysAll: true,
                           deletesFromPlayer: false, draggableRows: true)
            } else {
                ProgressView("Asking the player…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: playlistID) {
            tracks = nil
            tracks = (try? await player.client?.playlistTracks(playlistID)) ?? []
        }
    }
}
