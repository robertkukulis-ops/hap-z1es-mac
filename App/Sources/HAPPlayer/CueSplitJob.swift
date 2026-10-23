import Foundation

/// Splitting a .cue album that's already on the player: after the songs are copied back, the
/// original big file may be deleted only if every song arrived and the songs together are
/// sample-for-sample identical to it.
enum CueSplitJob {
    enum Outcome: Equatable {
        case askToDeleteOriginal
        case failed(String)
    }

    static func outcome(verified: Bool, uploaded: Int, expected: Int) -> Outcome {
        guard uploaded == expected else {
            return .failed("only \(uploaded) of \(expected) songs arrived, so nothing was deleted.")
        }
        guard verified else {
            return .failed("the check found a difference from the original, so nothing was deleted.")
        }
        return .askToDeleteOriginal
    }
}

/// A stop request that splitting and checking (plain loops, not Swift tasks) can look at.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
