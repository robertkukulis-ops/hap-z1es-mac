import HAPKit
import SwiftUI

/// The HAP's big screen: title and search on top, the pages in the middle, what's playing
/// along the bottom.
struct RackScreen: View {
    @Environment(RackState.self) private var rack
    @Environment(PlayerModel.self) private var player
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var rack = rack
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                TextField("Search albums, artists, tracks", text: $rack.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Rectangle().fill(ScreenTheme.divider).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(ScreenTheme.divider).frame(height: 1)
            NowPlayingBar()
        }
        .sonyScreen()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black, lineWidth: 4))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rack.screenFrame = $0 }
        .onChange(of: rack.searchFocusRequests) { searchFocused = true }
        .onChange(of: rack.search) { rack.path = [] }  // new search text: show the results
    }

    private var title: String {
        switch rack.mode {
        case .home: "Home"
        case .nowPlaying: "Now Playing"
        case .playerInfo: "Player Info"
        case .section:
            if !rack.search.isEmpty { "Search" }
            else if rack.section == .playlists, let name = rack.pageName { "Playlists · \(name)" }
            else { rack.section.title }
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var rack = rack
        switch rack.mode {
        case .home: HomeMenu()
        case .nowPlaying: NowPlayingScreen()
        case .playerInfo: PlayerView()
        case .section:
            NavigationStack(path: $rack.path) {
                Group {
                    if rack.search.isEmpty { sectionPage } else { SearchResultsView(text: rack.search) }
                }
                .navigationDestination(for: Page.self) { PageDestination(page: $0) }
            }
        }
    }

    @ViewBuilder private var sectionPage: some View {
        switch rack.section {
        case .albums: AlbumsGridView()
        case .artists: ArtistsView()
        case .genres: GenresView()
        case .tracks: TracksView()
        case .playlists: PlaylistsPage()
        case .folders:
            if player.connection == .connected {
                DriveView()
            } else {
                ContentUnavailableView("Player not connected", systemImage: "externaldrive",
                                       description: Text("The drive can be opened once the player is found."))
            }
        }
    }
}

/// A page opened from a list: album, artist or genre.
struct PageDestination: View {
    @Environment(PlayerModel.self) private var model
    let page: Page

    var body: some View {
        switch page {
        case .album(let id):
            if let album = model.library?.albums.first(where: { $0.albumid == id }) {
                AlbumDetailView(album: album)
            } else {
                ContentUnavailableView("Album not found", systemImage: "square.stack")
            }
        case .artist(let name): ArtistDetailView(name: name)
        case .genre(let name): GenreDetailView(name: name)
        }
    }
}
