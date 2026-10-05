import Testing
@testable import HAPPlayer

struct SeekBarTests {
    @Test func aPointOnTheBarIsASecondInTheTrack() {
        #expect(SeekBar.second(at: 0.5, duration: 292) == 146)
        #expect(SeekBar.second(at: 0, duration: 292) == 0)
    }

    @Test func outsideTheBarStaysInsideTheTrack() {
        // Dragging past either end: the start, or one second before the end (not past it).
        #expect(SeekBar.second(at: -0.3, duration: 292) == 0)
        #expect(SeekBar.second(at: 1.4, duration: 292) == 291)
    }

    @Test func noDurationMeansNoSeek() {
        #expect(SeekBar.second(at: 0.5, duration: 0) == nil)
    }
}
