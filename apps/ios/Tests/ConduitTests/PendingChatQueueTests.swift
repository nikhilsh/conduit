import XCTest
@testable import Conduit

/// Pins the optimistic-send pending-queue state machine: queue on send ->
/// flush when ready -> ack clears -> failure path after retries -> retry
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
        // Still in the flush set -- a later reconnect retries it.
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

    // MARK: - Durable delivery / broker ack (task K)

    /// markSent keeps the entry queued (NOT acked) and flags it `sent`, so a
    /// WS-write success no longer durably delivers — only a broker chat_ack
    /// (markDelivered) does. This is the core of the "send then background ->
    /// lost but shown as sent" fix.
    func testMarkSentKeepsEntryQueued() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markSent(sessionID: "s1", localID: "local-1")
        XCTAssertTrue(q.isPending("local-1", in: "s1"),
            "a sent-but-unacked entry must stay in the outbox")
        XCTAssertEqual(q.entries(for: "s1").first?.sent, true)
    }

    /// A `sent`-but-unacked entry is STILL flushable, so an app killed after a
    /// local WS-write success re-sends it on reconnect (the broker dedups by
    /// client_msg_id so the agent never sees a double).
    func testSentEntryStillFlushable() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markSent(sessionID: "s1", localID: "local-1")
        XCTAssertEqual(q.flushable(for: "s1").map { $0.localID }, ["local-1"],
            "an un-acked sent entry must be re-attempted on the next flush")
    }

    /// The broker ack (markDelivered) is what finally clears a sent entry.
    func testBrokerAckClearsSentEntry() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markSent(sessionID: "s1", localID: "local-1")
        q.markDelivered(sessionID: "s1", localID: "local-1")
        XCTAssertFalse(q.isPending("local-1", in: "s1"))
        XCTAssertTrue(q.bySession.isEmpty)
    }

    /// retry clears the `sent` flag so a re-armed failed entry starts fresh.
    func testRetryClearsSentFlag() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "a", ts: "t0")
        q.markSent(sessionID: "s1", localID: "local-1")
        for _ in 0..<PendingChatQueue.maxAttempts {
            q.markAttemptFailed(sessionID: "s1", localID: "local-1")
        }
        q.retry(sessionID: "s1", localID: "local-1")
        XCTAssertEqual(q.entries(for: "s1").first?.sent, false)
    }

    // MARK: - Queued-Next / Steer extensions (#480 / steer-ui-spec)

    /// A `normal` entry (no active turn) still flushes on connect --
    /// regression guard for #479 behavior.
    func testNormalEntryFlushableOnConnect() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "hi", ts: "t0")
        // flushable returns .normal entries that are not failed.
        let due = q.flushable(for: "s1")
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.kind, .normal)
    }

    /// Enqueueing during an active turn produces a `.queuedTurn` entry
    /// that does NOT appear in flushable() (so it is not auto-delivered).
    func testQueuedTurnEntryNotFlushable() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q1", message: "queued", ts: "t0")
        XCTAssertTrue(q.flushable(for: "s1").isEmpty,
            "queuedTurn entry must not appear in normal flushable set")
        let panel = q.queuedTurnEntries(for: "s1")
        XCTAssertEqual(panel.count, 1)
        XCTAssertEqual(panel.first?.kind, .queuedTurn)
    }

    /// flushOnTurnComplete returns the OLDEST queuedTurn entry, in order.
    func testFlushOnTurnCompleteReturnsOldestEntry() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q1", message: "first", ts: "t0")
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q2", message: "second", ts: "t1")
        let next = q.flushOnTurnComplete(sessionID: "s1")
        XCTAssertEqual(next?.localID, "local-q1", "oldest entry must be flushed first")
        XCTAssertEqual(next?.message, "first")
    }

    /// After the first entry is delivered, the second is still available.
    func testFlushOnTurnCompleteSerializesOneAtATime() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q1", message: "first", ts: "t0")
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q2", message: "second", ts: "t1")
        // Simulate delivery of the first.
        q.markDelivered(sessionID: "s1", localID: "local-q1")
        let next = q.flushOnTurnComplete(sessionID: "s1")
        XCTAssertEqual(next?.localID, "local-q2", "second entry should be ready after first is acked")
    }

    /// markSteering transitions kind to .steering.
    func testMarkSteeringTransition() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-s1", message: "steer me", ts: "t0")
        q.markSteering(sessionID: "s1", localID: "local-s1")
        let entry = q.entries(for: "s1").first
        XCTAssertEqual(entry?.kind, .steering)
        // A .steering entry is shown in the panel but not returned by flushOnTurnComplete.
        XCTAssertNil(q.flushOnTurnComplete(sessionID: "s1"),
            ".steering entry must not be returned by flushOnTurnComplete (already in-flight)")
    }

    /// markRetrying transitions kind to .retrying, re-offered by panel and flushOnTurnComplete.
    func testMarkRetryingTransition() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-r1", message: "retry me", ts: "t0")
        q.markSteering(sessionID: "s1", localID: "local-r1")
        q.markRetrying(sessionID: "s1", localID: "local-r1")
        let entry = q.entries(for: "s1").first
        XCTAssertEqual(entry?.kind, .retrying)
        // A .retrying entry IS returned by flushOnTurnComplete.
        let next = q.flushOnTurnComplete(sessionID: "s1")
        XCTAssertEqual(next?.localID, "local-r1")
    }

    /// Cancel removes the entry entirely.
    func testCancelRemovesEntry() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-c1", message: "cancel me", ts: "t0")
        q.markDelivered(sessionID: "s1", localID: "local-c1") // cancel = markDelivered
        XCTAssertFalse(q.isPending("local-c1", in: "s1"))
        XCTAssertTrue(q.queuedTurnEntries(for: "s1").isEmpty)
    }

    /// Persistence round-trip preserves the kind field.
    func testKindRoundTripsThroughCodable() throws {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-k1", message: "kind test", ts: "t0")
        q.markSteering(sessionID: "s1", localID: "local-k1")
        let data = try JSONEncoder().encode(q.bySession)
        let decoded = try JSONDecoder().decode([String: [PendingChat]].self, from: data)
        let restored = PendingChatQueue(bySession: decoded)
        XCTAssertEqual(restored.entries(for: "s1").first?.kind, .steering)
    }

    /// Normal entries and queuedTurn entries coexist independently in the same session.
    func testNormalAndQueuedTurnCoexist() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-n1", message: "normal", ts: "t0")
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-q1", message: "queued", ts: "t1")
        // flushable only returns normal.
        XCTAssertEqual(q.flushable(for: "s1").map { $0.localID }, ["local-n1"])
        // queuedTurnEntries only returns queued.
        XCTAssertEqual(q.queuedTurnEntries(for: "s1").map { $0.localID }, ["local-q1"])
    }

    // MARK: - drainSentNormal: race-fix (first-message stuck unacked)

    /// An assistant reply drains a normal entry that has NOT yet been marked sent
    /// (i.e. markSent hasn't completed yet). This is the first-message race fix:
    /// the broker can reply before the local WS-write-success callback fires.
    func testDrainSentNormalDrainsUnsent() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-1", message: "hello", ts: "t0")
        // Do NOT call markSent -- simulate the race where the broker replied first.
        XCTAssertEqual(q.entries(for: "s1").first?.sent, false)
        let drained = q.drainSentNormal(sessionID: "s1")
        XCTAssertEqual(drained, ["local-1"], "unsent normal entry must be drained on assistant reply")
        XCTAssertFalse(q.isPending("local-1", in: "s1"), "entry must be removed after drain")
        XCTAssertTrue(q.bySession.isEmpty, "empty session must prune its key")
    }

    /// A failed normal entry is NOT drained -- the user must explicitly retry it.
    func testDrainSentNormalPreservesFailedEntry() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-fail", message: "oops", ts: "t0")
        for _ in 0..<PendingChatQueue.maxAttempts {
            q.markAttemptFailed(sessionID: "s1", localID: "local-fail")
        }
        XCTAssertTrue(q.isFailed("local-fail", in: "s1"))
        let drained = q.drainSentNormal(sessionID: "s1")
        XCTAssertTrue(drained.isEmpty, "failed entry must not be drained")
        XCTAssertTrue(q.isPending("local-fail", in: "s1"), "failed entry must remain in queue")
    }

    /// A queuedTurn entry is NOT drained -- it may genuinely be undelivered.
    func testDrainSentNormalPreservesQueuedTurnEntry() {
        var q = PendingChatQueue()
        q.enqueueForActiveTurn(sessionID: "s1", localID: "local-qt", message: "queued", ts: "t0")
        let drained = q.drainSentNormal(sessionID: "s1")
        XCTAssertTrue(drained.isEmpty, "queuedTurn entry must not be drained by drainSentNormal")
        XCTAssertTrue(q.isPending("local-qt", in: "s1"), "queuedTurn entry must remain in queue")
    }

    /// drainSentNormal drains both sent and unsent normal entries in one call.
    func testDrainSentNormalDrainsMixedSentAndUnsent() {
        var q = PendingChatQueue()
        q.enqueue(sessionID: "s1", localID: "local-sent", message: "a", ts: "t0")
        q.enqueue(sessionID: "s1", localID: "local-unsent", message: "b", ts: "t1")
        q.markSent(sessionID: "s1", localID: "local-sent")
        // local-unsent has sent=false; local-sent has sent=true.
        let drained = q.drainSentNormal(sessionID: "s1")
        XCTAssertEqual(Set(drained), Set(["local-sent", "local-unsent"]),
            "both sent and unsent normal entries must be drained")
        XCTAssertTrue(q.bySession.isEmpty)
    }
}
