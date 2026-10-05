import SwiftUI

/// Colours of the rack: brushed silver, small lights.
enum RackColors {
    static let metalLight = Color(white: 0.87)
    static let metalDark = Color(white: 0.68)
    static let engraving = Color(white: 0.28)
    static let ledGreen = Color(red: 0.35, green: 0.88, blue: 0.35)
    static let ledBlue = Color(red: 0.45, green: 0.66, blue: 1.0)
    static let ringGlow = Color(red: 0.82, green: 0.91, blue: 1.0)
}

/// Brushed aluminium: a soft sheen across the panel with fine horizontal lines.
struct BrushedAluminium: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [RackColors.metalLight, Color(white: 0.94), RackColors.metalDark, RackColors.metalLight],
                           startPoint: .leading, endPoint: .trailing)
            Canvas { context, size in
                var y: CGFloat = 0
                var seed: UInt64 = 7
                while y < size.height {
                    // A fixed pseudo-random shade per line, so the brushing doesn't flicker.
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let shade = Double((seed >> 33) % 100) / 100
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)),
                                 with: .color(.white.opacity(0.08 + shade * 0.14)))
                    y += 1.3
                }
            }
            .blendMode(.overlay)
        }
    }
}

/// One device's front: aluminium with a thin dark edge.
struct Faceplate<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(BrushedAluminium())
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
    }
}

/// Small capitals printed on the panel ("HOME", "LINE 1").
struct PanelLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(RackColors.engraving.opacity(0.85))
            .fixedSize()
    }
}

/// The maker-style name at the top left of each faceplate (neutral lettering, no trademarks).
struct PanelLogo: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.custom("Times New Roman", size: 19).weight(.bold))
            .tracking(1.5)
            .foregroundStyle(RackColors.engraving)
    }
}

