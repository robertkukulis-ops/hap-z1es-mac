import HAPKit
import SwiftUI

/// What the amp's blue display opens: pick a playlist to play it at once.
struct PlaylistMenu: View {
    @Environment(PlayerModel.self) private var player
    @Environment(RackState.self) private var rack
    @Environment(PlaylistStore.self) private var store
    let close: () -> Void

    var body: some View {
        let lists = player.library?.playlists ?? []
        VStack(alignment: .leading, spacing: 2) {
            Text("Playlists").font(.headline).padding(.bottom, 4)
            if lists.isEmpty && store.playlists.isEmpty {
                Text("No playlists yet").foregroundStyle(.secondary)
            }
            // The user's own playlists first.
            ForEach(store.playlists) { saved in
                let count = player.songs(of: saved, store: store).count
                Button {
                    close()
                    Task { await player.play(saved: saved, store: store) }
                } label: {
                    HStack {
                        Image(systemName: saved.isAutomatic ? "gearshape" : "music.note.list").foregroundStyle(.secondary)
                        Text(saved.name)
                        Spacer()
                        Text(count == 0 ? "empty" : countText(count, "song")).foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .disabled(count == 0)
                .opacity(count == 0 ? 0.5 : 1)
            }
            if !store.playlists.isEmpty && !lists.isEmpty {
                Divider().padding(.vertical, 4)
                Text("On the player").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lists) { list in
                Button {
                    close()
                    Task { await player.play(playlist: list) }
                } label: {
                    HStack {
                        Text(list.name)
                        Spacer()
                        Text(list.numberOfTracks == 0 ? "empty" : countText(list.numberOfTracks, "track"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(list.numberOfTracks == 0)  // nothing to play
                .opacity(list.numberOfTracks == 0 ? 0.5 : 1)
                .padding(.vertical, 3)
            }
            Divider().padding(.vertical, 4)
            Button("Show All Playlists") {
                close()
                rack.select(.playlists)
            }
            .buttonStyle(.link)
        }
        .padding(14)
    }
}
