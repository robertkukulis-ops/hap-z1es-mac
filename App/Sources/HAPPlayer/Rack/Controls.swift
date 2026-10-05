import AppKit
import SwiftUI

/// A small round metal push button. `lit` adds the glowing ring of the amp's active input.
struct RoundButton: View {
    var size: CGFloat = 26
    var lit = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.96), Color(white: 0.62), Color(white: 0.9),
                                               Color(white: 0.6), Color(white: 0.96)], center: .center))
                .overlay(Circle().strokeBorder(Color(white: 0.35), lineWidth: 1))
                .overlay(
                    Circle().stroke(RackColors.ringGlow, lineWidth: 2.5)
                        .shadow(color: RackColors.ledBlue, radius: 5)
                        .padding(-3)
                        .opacity(lit ? 1 : 0)
                )
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressedStyle())
        .help(help)
    }
}

/// Buttons dip slightly when pressed.
struct PressedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

struct StatusLight: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3)
    }
}

/// Power light, power button and remote-control window, as on both devices. The light is
/// the connection: green = connected, orange = standby, yellow = looking, red = not found
/// (click to try again). The power button is decoration: the app never switches the player off.
struct PowerCluster: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 5) {
                PanelLabel("I/⏻")
                Button {
                    if case .failed = player.connection { Task { await player.connect() } }
                } label: {
                    StatusLight(color: lightColor).padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpText)
                Circle()
                    .fill(AngularGradient(colors: [Color(white: 0.95), Color(white: 0.65), Color(white: 0.95)], center: .center))
                    .overlay(Circle().strokeBorder(Color(white: 0.4), lineWidth: 1))
                    .frame(width: 28, height: 28)
            }
            Capsule().fill(Color(white: 0.32)).frame(width: 34, height: 15).padding(.bottom, 6)
        }
    }

    private var lightColor: Color {
        switch player.connection {
        case .connected: player.power?.isActive == false ? .orange : RackColors.ledGreen
        case .searching: .yellow
        case .failed: .red
        }
    }

    private var helpText: String {
        switch player.connection {
        case .connected: player.power?.isActive == false ? "Player in standby" : "Connected to the player"
        case .searching: "Looking for the player…"
        case .failed(let message): "Not connected: \(message) Click to try again."
        }
    }
}

/// A big metal knob with the light streak from the photos; `angle` turns the streak.
struct KnobFace: View {
    let angle: Double

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.5)).shadow(color: .black.opacity(0.45), radius: 4, y: 3)
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.98), Color(white: 0.58), Color(white: 0.86),
                                               Color(white: 0.55), Color(white: 0.98)],
                                      center: .center, angle: .degrees(angle)))
                .padding(4)
            Circle().strokeBorder(Color(white: 0.38), lineWidth: 1).padding(4)
        }
    }
}

/// A knob you turn by dragging up/down or with the scroll wheel; reports whole clicks.
struct Knob: View {
    let size: CGFloat
    let help: String
    let onStep: (Int) -> Void
    @State private var stepper: KnobStepper

    init(size: CGFloat, degreesPerStep: Double, help: String, onStep: @escaping (Int) -> Void) {
        self.size = size
        self.help = help
        self.onStep = onStep
        _stepper = State(initialValue: KnobStepper(degreesPerStep: degreesPerStep))
    }

    var body: some View {
        KnobFace(angle: stepper.angle)
            .frame(width: size, height: size)
            .overlay(KnobInput(toolTip: help, onGestureStart: { stepper.startGesture() }) { degrees in
                let steps = stepper.turn(by: degrees)
                if steps != 0 { onStep(steps) }
            })
    }
}

/// Catches dragging and the scroll wheel over a knob (SwiftUI has no scroll-wheel event on
/// macOS) and reports the movement in degrees: up / away = clockwise.
struct KnobInput: NSViewRepresentable {
    let toolTip: String
    let onGestureStart: () -> Void
    let onTurn: (Double) -> Void

    func makeNSView(context: Context) -> KnobInputView {
        let view = KnobInputView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: KnobInputView, context: Context) {
        view.onGestureStart = onGestureStart
        view.onTurn = onTurn
        view.toolTip = toolTip
    }
}

final class KnobInputView: NSView {
    var onGestureStart: (() -> Void)?
    var onTurn: ((Double) -> Void)?
    private var lastY: CGFloat?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
        onGestureStart?()
    }
    override func mouseUp(with event: NSEvent) { lastY = nil }

    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        if let lastY { onTurn?(Double(y - lastY) * 2) }  // 1 point of dragging = 2°
        lastY = y
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { onGestureStart?() }
        // Same direction for everyone, whatever the "natural scrolling" setting.
        let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard let degrees = KnobScroll.degrees(deltaY: Double(raw), precise: event.hasPreciseScrollingDeltas,
                                               coasting: !event.momentumPhase.isEmpty) else { return }
        onTurn?(degrees)
    }
}

/// The amp's small blue segment display.
struct SegmentText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium, design: .monospaced))
            .foregroundStyle(RackColors.ledBlue)
            .shadow(color: RackColors.ledBlue.opacity(0.8), radius: 4)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(minWidth: 86)
            .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
    }
}
