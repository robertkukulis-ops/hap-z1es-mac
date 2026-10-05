import HAPKit
import SwiftUI

/// Big cover and details of what's playing. ENTER = play/pause.
struct NowPlayingScreen: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let content = player.content
        HStack(spacing: 32) {
            Group {
                if let track = player.currentTrack, let album = player.album(of: track) {
                    ArtworkView(album: album, cornerRadius: 6)
                } else {
                    GeneratedArt(title: content?.albumName ?? "", subtitle: content?.artist ?? "")
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340, maxHeight: 340)
            VStack(alignment: .leading, spacing: 8) {
                Text(content?.title ?? "Nothing playing").font(.system(size: 30, weight: .semibold)).lineLimit(2)
                Text(named(content?.artist, "")).font(.title2).foregroundStyle(ScreenTheme.dim)
                Text(named(content?.albumName, "")).font(.title3).foregroundStyle(ScreenTheme.dim)
                if let format = content?.formatDescription, !format.isEmpty {
                    Text(format).font(.callout).foregroundStyle(ScreenTheme.dim).padding(.top, 8)
                }
                if let queue = player.queue {
                    Text("\(queue.title) · \(queue.index + 1) of \(queue.tracks.count)")
                        .font(.callout).foregroundStyle(ScreenTheme.dim)
                }
                if content?.title != nil {
                    HStack(spacing: 10) {
                        Text(clock(player.position)).monospacedDigit()
                        SeekBar(position: player.position, duration: player.duration, enabled: player.canSeek) { second in
                            Task { await player.send(.seek(second: second)) }
                        }
                        .frame(maxWidth: 320)
                        Text(clock(player.duration)).monospacedDigit()
                    }
                    .font(.title3)
                    .foregroundStyle(ScreenTheme.dim)
                    .padding(.top, 14)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onRackEnter { Task { await player.send(.playPause) } }
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
