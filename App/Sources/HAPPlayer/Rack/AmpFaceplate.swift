import HAPKit
import SwiftUI

/// The bottom device: power, (decorative) phones, the five section switches, the blue display
/// (click = playlists) and the VOLUME knob (turn = scroll the screen).
struct AmpFaceplate: View {
    @Environment(PlayerModel.self) private var player
    @Environment(RackState.self) private var rack
    @State private var showPlaylists = false

    var body: some View {
        Faceplate {
            HStack(spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    PanelLogo("AMP")
                    PowerCluster()
                }
                .frame(width: 110, alignment: .leading)
                phones
                Spacer(minLength: 10)
                HStack(spacing: 30) {
                    ForEach(RackSection.allCases) { section in
                        VStack(spacing: 6) {
                            PanelLabel(section.label)
                            RoundButton(size: 28, lit: rack.mode == .section && rack.section == section,
                                        help: section.title) { rack.select(section) }
                        }
                    }
                }
                Spacer(minLength: 10)
                Button { showPlaylists.toggle() } label: { SegmentText(text: displayText) }
                    .buttonStyle(.plain)
                    .help("Playlists")
                    .popover(isPresented: $showPlaylists, arrowEdge: .top) {
                        PlaylistMenu { showPlaylists = false }
                    }
                VStack(spacing: 4) {
                    PanelLabel("Volume")
                    Knob(size: 96, degreesPerStep: 6, help: "Turn to scroll the screen") { steps in
                        ScreenScroller.scroll(by: CGFloat(steps) * 20, screenFrame: rack.screenFrame)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .overlay(alignment: .bottomTrailing) { PanelLabel("Integrated Amplifier").padding(8) }
    }

    /// Elapsed time, like a clock on the amp's display; dashes when nothing is loaded.
    private var displayText: String {
        guard player.content?.title != nil else { return "- - -" }
        let s = Int(player.position)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var phones: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(spacing: 4) {
                PanelLabel("Phones")
                Circle().fill(Color(white: 0.12)).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color(white: 0.7), lineWidth: 2))
            }
            VStack(spacing: 4) {
                PanelLabel("Impedance")
                KnobFace(angle: 200).frame(width: 22, height: 22)
            }
        }
    }
}
