import Foundation

/// Turns knob movement (in degrees) into whole clicks, like a stepped dial. Movement smaller
/// than a click is kept, so turning slowly still clicks.
struct KnobStepper {
    let degreesPerStep: Double
    /// Total rotation, for drawing the knob's light streak.
    private(set) var angle: Double = 0
    private var remainder: Double = 0

    init(degreesPerStep: Double = 30) { self.degreesPerStep = degreesPerStep }

    /// Adds movement; returns the clicks crossed (positive = clockwise).
    mutating func turn(by degrees: Double) -> Int {
        angle += degrees
        remainder += degrees
        let steps = Int(remainder / degreesPerStep)  // rounds toward zero
        remainder -= Double(steps) * degreesPerStep
        return steps
    }

    /// A new drag or scroll gesture starts from zero: an old half-turn doesn't add up.
    mutating func startGesture() { remainder = 0 }
}

/// How far one scroll event turns a knob.
enum KnobScroll {
    /// A mouse-wheel notch is one 30° click; trackpad / Magic Mouse scrolling turns gently
    /// (about 40 points per click); the coasting after the fingers lift is ignored, so a
    /// flick can't keep skipping tracks by itself. nil = ignore the event.
    static func degrees(deltaY: Double, precise: Bool, coasting: Bool) -> Double? {
        guard !coasting else { return nil }
        return deltaY * (precise ? 0.8 : 30)
    }
}

/// Track skips waiting to be sent. A fast spin queues at most `limit`; turning back cancels
/// skips still waiting; they go out one at a time (the player gets one command at a time).
struct SkipQueue {
    static let limit = 10
    private(set) var pending = 0

    mutating func add(_ steps: Int) {
        pending = min(max(pending + steps, -Self.limit), Self.limit)
    }

    /// The next single skip: +1 = next track, -1 = previous, nil = nothing waiting.
    mutating func take() -> Int? {
        guard pending != 0 else { return nil }
        let one = pending > 0 ? 1 : -1
        pending -= one
        return one
    }
}

/// The HAP dial: each click skips one track, sent one after another.
@MainActor
final class DialSkipper {
    private var queue = SkipQueue()
    private var running = false

    var pending: Int { queue.pending }

    func add(_ steps: Int, player: PlayerModel) {
        guard player.connection == .connected else { return }
        queue.add(steps)
        guard !running else { return }
        running = true
        Task {
            while let step = queue.take() {
                if step > 0 { await player.next() } else { await player.previous() }
            }
            running = false
        }
    }
}
