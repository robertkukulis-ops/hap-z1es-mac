import Testing
@testable import HAPPlayer

struct KnobStepperTests {
    @Test func clicksOnlyAfterAWholeStep() {
        var knob = KnobStepper(degreesPerStep: 30)
        #expect(knob.turn(by: 29) == 0)
        #expect(knob.turn(by: 1) == 1)
        #expect(knob.angle == 30)
    }

    @Test func turningBackCountsNegativeAndKeepsTheRest() {
        var knob = KnobStepper(degreesPerStep: 30)
        #expect(knob.turn(by: -65) == -2)
        #expect(knob.turn(by: -25) == -1)  // the 5° left over + 25° = one more click
    }

    @Test func smallWigglesDoNothing() {
        var knob = KnobStepper(degreesPerStep: 30)
        #expect(knob.turn(by: 20) == 0)
        #expect(knob.turn(by: -20) == 0)
        #expect(knob.turn(by: 20) == 0)
    }
}

struct SkipQueueTests {
    @Test func oppositeTurnsCancel() {
        var queue = SkipQueue()
        queue.add(3)
        queue.add(-1)
        #expect(queue.take() == 1)
        #expect(queue.take() == 1)
        #expect(queue.take() == nil)
    }

    @Test func aHardSpinIsCapped() {
        var queue = SkipQueue()
        queue.add(25)
        #expect(queue.pending == SkipQueue.limit)
        queue.add(-40)
        #expect(queue.pending == -SkipQueue.limit)
    }

    @Test func previousIsMinusOne() {
        var queue = SkipQueue()
        queue.add(-2)
        #expect(queue.take() == -1)
        #expect(queue.pending == -1)
    }
}

@MainActor
struct DialSkipperTests {
    @Test func nothingQueuesWhileNotConnected() {
        let skipper = DialSkipper()
        skipper.add(3, player: PlayerModel())  // a new PlayerModel is still "searching"
        #expect(skipper.pending == 0)
    }
}

struct KnobGestureTests {
    @Test func coastingAfterTheFingersLiftIsIgnored() {
        #expect(KnobScroll.degrees(deltaY: 5, precise: true, coasting: true) == nil)
    }

    @Test func trackpadScrollingTurnsGently() {
        // About 40 points of two-finger scrolling for one 30° click of the HAP dial.
        let degrees = KnobScroll.degrees(deltaY: 40, precise: true, coasting: false) ?? 0
        #expect(degrees >= 30 && degrees < 45)
    }

    @Test func aMouseWheelNotchIsOneClickOfTheDial() {
        #expect(KnobScroll.degrees(deltaY: 1, precise: false, coasting: false) == 30)
    }

    @Test func aNewGestureForgetsAnOldPartialTurn() {
        var knob = KnobStepper(degreesPerStep: 30)
        #expect(knob.turn(by: 20) == 0)
        knob.startGesture()
        #expect(knob.turn(by: 20) == 0)  // without the reset this would be a click
    }
}
