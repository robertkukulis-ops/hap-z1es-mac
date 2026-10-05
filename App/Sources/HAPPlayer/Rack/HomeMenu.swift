import HAPKit
import SwiftUI

/// The HAP's Home menu, as on the real player: a list with a white box around the
/// highlighted item, over the faded cover of what's playing. Hover or ENTER, click opens.
struct HomeMenu: View {
    @Environment(RackState.self) private var rack
    @Environment(PlayerModel.self) private var player
    @State private var highlighted = 0

    enum Item: String, CaseIterable {
        case nowPlaying = "Now Playing", genres = "Genres", artists = "Artists", albums = "Albums",
             tracks = "Tracks", folders = "Folders", playlists = "Playlists", search = "Search",
             playerInfo = "Player Info"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Item.allCases.enumerated()), id: \.offset) { index, item in
                    Text(item.rawValue)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(width: 280, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1.5)
                            .opacity(index == highlighted ? 1 : 0))
                        .contentShape(Rectangle())
                        .onHover { if $0 { highlighted = index } }
                        .onTapGesture { open(item) }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onRackEnter { open(Item.allCases[highlighted]) }
    }

    @ViewBuilder private var backdrop: some View {
        if let track = player.currentTrack, let album = player.album(of: track) {
            ArtworkView(album: album, cornerRadius: 0)
                .aspectRatio(1, contentMode: .fit)
                .opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private func open(_ item: Item) {
        switch item {
        case .nowPlaying: rack.show(.nowPlaying)
        case .genres: rack.select(.genres)
        case .artists: rack.select(.artists)
        case .albums: rack.select(.albums)
        case .tracks: rack.select(.tracks)
        case .folders: rack.select(.folders)
        case .playlists: rack.select(.playlists)
        case .search: rack.requestSearch()
        case .playerInfo: rack.show(.playerInfo)
        }
    }
}
