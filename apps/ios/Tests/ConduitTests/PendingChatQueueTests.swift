import XCTest
@testable import Conduit

/// Pins the optimistic-send pending-queue state machine: queue on send →
/// flush when ready → ack clears → failure path after retries → retry
/// re-arms. Pure logic, no live WS. Mirror of Android
/// `PendingChatQueueTest`.
final class PendingChatQueueTests: XCTestCase {
    func testEnqueueMarksPending() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "hi", ts: "t0")
        XCTAssertTrue(q.isPending("local-1", in: "s1"))
        XCTAssertFalse(q.isFailed("local-1", in: "s1"))
        XCTAssertEqual(q.entries(for: "s1").count, 1)
    }

    func testEnqueueIsIdempotentOnLocalID() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "hi", ts: "t0")
        q.enqueue(sessionID: "s1", localID: "local-1", message: "hi", ts: "t0")
        XCTAssertEqual(q.entries(for: "s1").count, 1)
    }

    func testFlushableReturnsPendingNotFailed() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.enqueue(sessionID: "s1", localID: "local-2", message: "b", ts: "t1")
        XCTAssertEqual(q.flushable(for: "s1").map { $0.localID }, ["local-1", "local-2"])
    }

    func testMarkDeliveredAcksAndClears() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markDelivered(sessionID: "s1", localID: "local-1")
        XCTAssertFalse(q.isPending("local-1", in: "s1"))
        XCTAssertTrue(q.entries(for: "s1").isEmpty)
        // Empty session prunes its key so persistence stays compact.
        XCTAssertTrue(q.bySession.isEmpty)
    }

    func testTransientFailureKeepsEntryQueuedAndPending() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        let crossed = q.markAttemptFailed(sessionID: "s1", localID: "local-1")
        XCTAssertFalse(crossed)
        XCTAssertTrue(q.isPending("local-1", in: "s1"))
        XCTAssertFalse(q.isFailed("local-1", in: "s1"))
        // Still in the flush set — a later reconnect retries it.
        XCTAssertEqual(q.flushable(for: "s1").count, 1)
    }

    func testFailsAfterMaxAttempts() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        var crossed = false
        for _ in 0..<PendingChatQueue.maxAttempts {
            crossed = q.markAttemptFailed(sessionID: "s1", localID: "local-1")
        }
        XCTAssertTrue(crossed)
        XCTAssertTrue(q.isFailed("local-1", in: "s1"))
        // A failed entry is no longer auto-flushed (waits for explicit retry).
        XCTAssertTrue(q.flushable(for: "s1").isEmpty)
        // ...but it stays queued so the bubble can offer retry.
        XCTAssertTrue(q.isPending("local-1", in: "s1"))
    }

    func testRetryReArmsFailedEntry() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        for _ in 0..<PendingChatQueue.maxAttempts {
            q.markAttemptFailed(sessionID: "s1", localID: "local-1")
        }
        XCTAssertTrue(q.isFailed("local-1", in: "s1"))
        q.retry(sessionID: "s1", localID: "local-1")
        XCTAssertFalse(q.isFailed("local-1", in: "s1"))
        XCTAssertEqual(q.flushable(for: "s1").count, 1)
        // Attempts reset so the entry gets a fresh maxAttempts budget.
        XCTAssertEqual(q.entries(for: "s1").first?.attempts, 0)
    }

    func testClearDropsSessionQueue() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.clear(sessionID: "s1")
        XCTAssertTrue(q.entries(for: "s1").isEmpty)
    }

    func testQueueRoundTripsThroughCodable() throws {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markAttemptFailed(sessionID: "s1", localID: "local-1")
        let data = try JSONEncoder().encode(q.bySession)
        let decoded = try JSONDecoder().decode([String: [PendingChat]].self, from: data)
        let restored = PendingChatQueue(bySession: decoded)
        XCTAssertTrue(restored.isPending("local-1", in: "s1"))
        XCTAssertEqual(restored.entries(for: "s1").first?.attempts, 1)
    }

    func testIndependentSessions() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.enqueue(sessionID: "s2", localID: "local-2", message: "b", ts: "t1")
        q.markDelivered(sessionID: "s1", localID: "local-1")
        XCTAssertFalse(q.isPending("local-1", in: "s1"))
        XCTAssertTrue(q.isPending("local-2", in: "s2"))
    }
}
