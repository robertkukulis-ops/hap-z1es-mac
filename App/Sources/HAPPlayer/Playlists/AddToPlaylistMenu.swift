import CoreTransferable
import HAPKit
import SwiftUI

/// "Add to Playlist ▸" for any songs: each hand-picked playlist, then "New Playlist", which
/// makes one with these songs (rename it on the PLAYLISTS page).
struct AddToPlaylistMenu: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(PlayerModel.self) private var player
    var title = "Add to Playlist"
    let tracks: () -> [Track]

    var body: some View {
        Menu(title) {
            let lists = store.playlists.filter { !$0.isAutomatic }
            ForEach(lists) { list in
                Button(list.name) { store.add(tracks(), to: list.id, library: player.library?.tracks ?? []) }
            }
            if !lists.isEmpty { Divider() }
            Button("New Playlist") {
                let songs = tracks()
                let id = store.newHandPicked()
                store.add(songs, to: id)
                let name = store.playlists.first { $0.id == id }?.name ?? "New Playlist"
                store.lastMessage = "Made “\(name)” with \(countText(songs.count, "song")); rename it on the PLAYLISTS page"
            }
        }
    }
}

/// Songs being dragged from a track list onto a playlist: their track ids as plain text
/// ("hap-tracks:12,57"), so no custom file type needs registering with macOS.
struct DraggedTracks: Transferable {
    let ids: [Int]

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { "hap-tracks:" + $0.ids.map(String.init).joined(separator: ",") })
    }

    /// The ids in a dropped text, or nil when it isn't songs from this app.
    static func ids(in text: String) -> [Int]? {
        guard text.hasPrefix("hap-tracks:") else { return nil }
        return text.dropFirst("hap-tracks:".count).split(separator: ",").compactMap { Int($0) }
    }
}
