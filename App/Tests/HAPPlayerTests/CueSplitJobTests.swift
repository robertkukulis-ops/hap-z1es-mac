import Testing
@testable import HAPPlayer

struct CueSplitJobTests {
    @Test func verifiedAndCompleteAsksToDelete() {
        #expect(CueSplitJob.outcome(verified: true, uploaded: 12, expected: 12) == .askToDeleteOriginal)
    }

    @Test func failedCheckDeletesNothing() {
        guard case .failed(let message) = CueSplitJob.outcome(verified: false, uploaded: 12, expected: 12) else {
            Issue.record("a failed check must not offer deleting"); return
        }
        #expect(message.contains("nothing was deleted"))
    }

    @Test func missingSongsDeleteNothing() {
        guard case .failed(let message) = CueSplitJob.outcome(verified: true, uploaded: 11, expected: 12) else {
            Issue.record("missing songs must not offer deleting"); return
        }
        #expect(message.contains("nothing was deleted"))
    }
}
