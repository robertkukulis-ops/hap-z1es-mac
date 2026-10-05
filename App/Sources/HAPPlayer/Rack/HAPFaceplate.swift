import HAPKit
import SwiftUI

/// The top device: logo, power, play light, the big screen, HOME/BACK, dial, ENTER, ▶II.
struct HAPFaceplate: View {
    @Environment(PlayerModel.self) private var player
    @Environment(RackState.self) private var rack

    var body: some View {
        Faceplate {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    PanelLogo("HAP")
                    PowerCluster()
                    HStack(spacing: 6) {
                        PanelLabel("Play")
                        StatusLight(color: player.isPlaying ? RackColors.ledBlue : Color(white: 0.6))
                    }
                    .help("Lit while music plays")
                    Spacer()
                }
                .frame(width: 110, alignment: .leading)
                RackScreen()
                controls.frame(width: 260)
            }
            .padding(.bottom, 10)
        }
        .overlay(alignment: .bottomTrailing) { PanelLabel("HDD Audio Player").padding(8) }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            VStack(spacing: 28) {
                labelled("Home") { RoundButton(help: "Home menu") { rack.show(.home) } }
                labelled("Back") {
                    RoundButton(help: "Back") { rack.back() }
                        .disabled(!rack.canGoBack)
                        .opacity(rack.canGoBack ? 1 : 0.4)  // nothing to go back to
                }
            }
            Knob(size: 80, degreesPerStep: 30, help: "Turn for the next or previous track") { steps in
                rack.skipper.add(steps, player: player)
            }
            VStack(spacing: 20) {
                // As on the real player: ENTER and ▶II side by side at the dial's height.
                HStack(spacing: 14) {
                    labelled("Enter") { RoundButton(help: "Play what's selected") { rack.pressEnter() } }
                    labelled("▶II") { RoundButton(help: "Play / pause") { Task { await player.send(.playPause) } } }
                }
                // Not on the real player: shuffle and repeat for lists played from the app.
                HStack(spacing: 14) {
                    labelled("Shuffle") {
                        RoundButton(size: 22, lit: player.shuffleOn, help: Self.shuffleHelp) { player.toggleShuffle() }
                    }
                    labelled(player.repeatMode == .one ? "Repeat 1" : "Repeat") {
                        RoundButton(size: 22, lit: player.repeatMode != .off, help: Self.repeatHelp) { player.cycleRepeat() }
                    }
                }
            }
        }
    }

    static let shuffleHelp = "Shuffle albums, playlists and folders played from the app"
    static let repeatHelp = "Repeat off → all → one, for albums, playlists and folders played from the app"

    private func labelled<Content: View>(_ text: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 4) {
            PanelLabel(text)
            content()
        }
    }
}
