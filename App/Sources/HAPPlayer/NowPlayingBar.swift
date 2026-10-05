import HAPKit
import SwiftUI

/// Along the bottom of every page: cover, title, controls, position and format.
struct NowPlayingBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(RackState.self) private var rack

    var body: some View {
        let content = player.content
        let track = player.currentTrack
        VStack(spacing: 8) {
        HStack(spacing: 14) {
            Group {
                if let track, let album = player.album(of: track) {
                    Button { rack.open(.album(album.albumid)) } label: {
                        ArtworkView(album: album, cornerRadius: 4)
                    }
                    .buttonStyle(.plain)
                    .help("Open album")
                } else if content?.title != nil {
                    GeneratedArt(title: content?.albumName ?? "", subtitle: content?.artist ?? "")
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(content?.title ?? "Nothing playing").font(.callout.weight(.semibold)).lineLimit(1)
                Text([content?.artist, content?.albumName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(ScreenTheme.dim).lineLimit(1)
                if let problem = player.commandProblem {
                    Text(problem).font(.caption2).foregroundStyle(.orange).lineLimit(1).help(problem)
                } else if let queue = player.queue {
                    Text("\(queue.title) · \(queue.index + 1) of \(queue.tracks.count)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(width: 230, alignment: .leading)

            HStack(spacing: 18) {
                Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                    .help("Previous track")
                Button { Task { await player.send(.playPause) } } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }
                .help(player.isPlaying ? "Pause" : "Play")
                Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                    .help("Next track")
                Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.shuffleOn ? Color.white : ScreenTheme.dim.opacity(0.5))
                    .help(HAPFaceplate.shuffleHelp)
                Button { player.cycleRepeat() } label: { Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat") }
                    .foregroundStyle(player.repeatMode != .off ? Color.white : ScreenTheme.dim.opacity(0.5))
                    .help(HAPFaceplate.repeatHelp)
            }
            .buttonStyle(.plain)
            .font(.title3)
            .disabled(player.connection != .connected)

            Spacer(minLength: 8)

            // The time, shown on a small round dial (looks only; the bar below does the jumping).
            HStack(spacing: 10) {
                TimeDial(fraction: dialFraction, visible: player.duration > 0)
                    .frame(width: 38, height: 38)
                    .help(player.queue.map { "\($0.title): \(Int(dialFraction * 100)) % played" } ?? "This song")
                VStack(alignment: .leading, spacing: 0) {
                    Text(clock(player.position))
                        .font(.system(size: 20, weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    Text(player.duration > 0 ? "of \(clock(player.duration))" : " ")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(ScreenTheme.dim)
                }
                .frame(width: 66, alignment: .leading)
            }

            if let format = formatBadge(content) {
                Text(format)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
                    .foregroundStyle(.secondary)
            }
            if let problem = player.commandProblem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem)
            }
        }
        // The seek bar along the whole width of the screen.
        SeekBar(position: player.position, duration: player.duration, enabled: player.canSeek) { second in
            Task { await player.send(.seek(second: second)) }
        }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The dial: how much of the app's list is played, or of the current song without a list.
    private var dialFraction: Double {
        if let queue = player.queue { return queue.progress(position: player.position) }
        return player.duration > 0 ? min(player.position / player.duration, 1) : 0
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// e.g. "FLAC 44.1/24"
    private func formatBadge(_ content: PlayingContent?) -> String? {
        guard let info = content?.audioInfo?.first else { return nil }
        let codec = (content?.format ?? info.codec ?? "").uppercased()
        let rate = info.frequency.flatMap(Double.init).map { $0.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int($0 / 1000))" : String(format: "%.1f", $0 / 1000) }
        let bits = info.bandwidth
        let quality = [rate, bits].compactMap { $0 }.joined(separator: "/")
        let text = [codec == "LPCM" ? "PCM" : codec, quality].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
