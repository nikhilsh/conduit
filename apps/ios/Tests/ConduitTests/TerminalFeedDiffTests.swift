import Testing
@testable import Conduit

/// Stage 3 of the rebuild. Pure tail-diff logic that decides how the broker
/// terminal buffer is fed into libghostty: append (grow), nothing (unchanged),
/// or rebuild (snapshot replacement / shrink).
@Suite("Terminal feed diff")
struct TerminalFeedDiffTests {
    @Test func firstFeedFromZeroFeedsWholeBuffer() {
        #expect(TerminalFeedDiff.diff(lastFed: 0, bufferCount: 12) == .feed(0..<12))
    }

    @Test func growthFeedsOnlyTheTail() {
        #expect(TerminalFeedDiff.diff(lastFed: 10, bufferCount: 25) == .feed(10..<25))
    }

    @Test func noChangeFeedsNothing() {
        #expect(TerminalFeedDiff.diff(lastFed: 25, bufferCount: 25) == .none)
    }

    @Test func shrinkRequestsReset() {
        // Snapshot replacement on reconnect makes the buffer smaller → rebuild.
        #expect(TerminalFeedDiff.diff(lastFed: 100, bufferCount: 40) == .reset)
    }

    @Test func emptyBufferAfterDataResets() {
        #expect(TerminalFeedDiff.diff(lastFed: 5, bufferCount: 0) == .reset)
    }
}
