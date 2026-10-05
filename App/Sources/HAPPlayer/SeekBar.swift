import SwiftUI

/// A progress bar you can click or drag to jump within the track. One jump is sent when you
/// let go, so dragging doesn't flood the player with commands.
struct SeekBar: View {
    let position: Double
    let duration: Double
    /// Only while a song is playing or paused (a stopped player refuses jumps).
    var enabled = true
    let onSeek: (Int) -> Void
    /// Where the finger/mouse is while dragging, and briefly after letting go (until the
    /// player reports the new position), so the bar doesn't jump back.
    @State private var shown: Double?
    @State private var hovering = false

    /// The second at a point on the bar (0 = start, 1 = end), kept inside the track.
    static func second(at fraction: Double, duration: Double) -> Int? {
        guard duration >= 1 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return min(Int((clamped * duration).rounded(.down)), Int(duration) - 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = shown ?? (duration > 0 ? min(position / duration, 1) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 4)
                Capsule().fill(.white).frame(width: width * fraction, height: 4)
                Circle().fill(.white).frame(width: 11, height: 11)
                    .offset(x: width * fraction - 5.5)
                    .opacity(hovering || shown != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { shown = min(max($0.location.x / width, 0), 1) }
                    .onEnded { value in
                        let target = value.location.x / width
                        if let second = Self.second(at: target, duration: duration) {
                            onSeek(second)
                            Task { try? await Task.sleep(for: .seconds(1.5)); shown = nil }
                        } else {
                            shown = nil
                        }
                    }
            )
        }
        .frame(height: 14)
        .help(duration >= 1 && enabled ? "Click or drag to jump" : "")
        .allowsHitTesting(duration >= 1 && enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A small round dial for the time: a ring that fills as the track plays, with tick marks
/// like a watch and a dot at the current point. Looks only.
struct TimeDial: View {
    /// How much is played, 0…1 (the app's list, or the current song).
    let fraction: Double
    let visible: Bool

    /// How red the dial is: none until 60 %, then gradually, fully red at the end.
    static func redness(_ fraction: Double) -> Double {
        min(max((fraction - 0.6) / 0.4, 0), 1)
    }

    var body: some View {
        let red = Self.redness(fraction)
        let tint = Color(red: 1, green: 1 - 0.7 * red, blue: 1 - 0.7 * red)
        ZStack {
            ForEach(0..<12) { tick in
                Capsule()
                    .fill(.white.opacity(tick % 3 == 0 ? 0.55 : 0.25))
                    .frame(width: 1.5, height: tick % 3 == 0 ? 4 : 2.5)
                    .offset(y: -16)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            Circle().stroke(.white.opacity(0.18), lineWidth: 2.5).padding(5)
            Circle().trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
            Circle().fill(tint).frame(width: 5, height: 5)
                .offset(y: -14)
                .rotationEffect(.degrees(fraction * 360))
                .opacity(visible ? 1 : 0)
        }
        .animation(.linear(duration: 0.9), value: fraction)
    }
}
