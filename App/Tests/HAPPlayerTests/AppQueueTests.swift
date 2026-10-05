import Foundation
import HAPKit
import Testing
@testable import HAPPlayer

struct AppQueueTests {
    private func songs(_ n: Int) throws -> [Track] { try (1...n).map { try makeTrack($0) } }
    private let reverse: (inout [Track]) -> Void = { $0.reverse() }
    private func ids(_ q: AppQueue) -> [Int] { q.tracks.map(\.trackid) }

    @Test func plainListStartsAtTheClickedSong() throws {
        let q = AppQueue(songs: try songs(4), start: 2, title: "A", shuffled: false, shuffle: reverse)
        #expect(ids(q) == [1, 2, 3, 4])
        #expect(q.current.trackid == 3)
    }

    @Test func shuffledListStartsWithTheClickedSongThenTheRestShuffled() throws {
        let q = AppQueue(songs: try songs(4), start: 2, title: "A", shuffled: true, shuffle: reverse)
        #expect(ids(q) == [3, 4, 2, 1])
        #expect(q.index == 0)
    }

    @Test func shuffleOnKeepsTheCurrentSongAndShufflesWhatsLeft() throws {
        var q = AppQueue(songs: try songs(5), start: 1, title: "A", shuffled: false, shuffle: reverse)
        q.setShuffle(true, shuffle: reverse)
        #expect(ids(q) == [1, 2, 5, 4, 3])
        #expect(q.current.trackid == 2)
    }

    @Test func shuffleOffGoesBackToTheListOrderAfterTheCurrentSong() throws {
        var q = AppQueue(songs: try songs(5), start: 3, title: "A", shuffled: true, shuffle: reverse)
        q.setShuffle(false, shuffle: reverse)
        #expect(ids(q) == [1, 2, 3, 4, 5])
        #expect(q.current.trackid == 4)
    }

    @Test func endOfListStopsWithoutRepeat() throws {
        var q = AppQueue(songs: try songs(2), start: 1, title: "A", shuffled: false, shuffle: reverse)
        let r1 = q.advanceAfterSongEnded(repeat: .off, shuffled: false, shuffle: reverse)
        #expect(!r1)
    }

    @Test func repeatAllStartsAgain() throws {
        var q = AppQueue(songs: try songs(3), start: 2, title: "A", shuffled: false, shuffle: reverse)
        let r2 = q.advanceAfterSongEnded(repeat: .all, shuffled: false, shuffle: reverse)
        #expect(r2)
        #expect(q.current.trackid == 1)
    }

    @Test func repeatAllWithShuffleReshuffles() throws {
        var q = AppQueue(songs: try songs(3), start: 0, title: "A", shuffled: true, shuffle: { _ in })
        q.index = q.tracks.count - 1
        let r3 = q.advanceAfterSongEnded(repeat: .all, shuffled: true, shuffle: reverse)
        #expect(r3)
        #expect(ids(q) == [3, 2, 1])
        #expect(q.index == 0)
    }

    @Test func repeatOnePlaysTheSameSongAgain() throws {
        var q = AppQueue(songs: try songs(3), start: 1, title: "A", shuffled: false, shuffle: reverse)
        let r4 = q.advanceAfterSongEnded(repeat: .one, shuffled: false, shuffle: reverse)
        #expect(r4)
        #expect(q.current.trackid == 2)
    }

    @Test func nextStillSkipsWithRepeatOne() throws {
        var q = AppQueue(songs: try songs(3), start: 1, title: "A", shuffled: false, shuffle: reverse)
        let r5 = q.skipForward(repeat: .one, shuffled: false, shuffle: reverse)
        #expect(r5)
        #expect(q.current.trackid == 3)
        let r6 = q.skipForward(repeat: .one, shuffled: false, shuffle: reverse)
        #expect(!r6)  // last song: nowhere to go
        let r7 = q.skipForward(repeat: .all, shuffled: false, shuffle: reverse)
        #expect(r7)   // repeat all wraps
        #expect(q.current.trackid == 1)
    }

    @Test func repeatModeCyclesOffAllOne() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }
}

struct DialTests {
    @Test func listProgressCountsPlayedSongsAndTheCurrentPosition() throws {
        let songs = [try makeTrack(1, duration: 100), try makeTrack(2, duration: 200), try makeTrack(3, duration: 100)]
        var q = AppQueue(songs: songs, start: 0, title: "A", shuffled: false, shuffle: { _ in })
        #expect(q.progress(position: 50) == 50.0 / 400)
        q.index = 1
        #expect(q.progress(position: 100) == 200.0 / 400)  // song 1 done (100) + 100 into song 2
    }

    @Test func listProgressWithoutLengthsIsZero() throws {
        let q = AppQueue(songs: [try makeTrack(1)], start: 0, title: "A", shuffled: false, shuffle: { _ in })
        #expect(q.progress(position: 30) == 0)
    }

    @Test func dialTurnsRedTowardsTheEnd() {
        #expect(TimeDial.redness(0.3) == 0)
        #expect(TimeDial.redness(0.6) == 0)
        #expect(abs(TimeDial.redness(0.8) - 0.5) < 0.0001)
        #expect(TimeDial.redness(1.0) == 1)
    }
}
