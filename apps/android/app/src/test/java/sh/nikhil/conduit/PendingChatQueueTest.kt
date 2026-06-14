package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the optimistic-send pending-queue state machine: queue on send ->
 * flush when ready -> ack clears -> failure path after retries -> retry
 * re-arms, plus JSON persistence round-trip. Pure logic, no live WS. Mirror
 * of iOS `PendingChatQueueTests`.
 *
 * Extended for the "Queued Next" / steer spec (PR #481): queue-while-active
 * ordering, steer lifecycle, cancel, and regression for #479 normal flush.
 */
class PendingChatQueueTest {
    @Test
    fun enqueueMarksPending() {
        val q = PendingChatQueue().enqueue("s1", "local-1", "hi", "t0")
        assertTrue(q.isPending("local-1", "s1"))
        assertFalse(q.isFailed("local-1", "s1"))
        assertEquals(1, q.entries("s1").size)
    }

    @Test
    fun enqueueIsIdempotentOnLocalId() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "hi", "t0")
            .enqueue("s1", "local-1", "hi", "t0")
        assertEquals(1, q.entries("s1").size)
    }

    @Test
    fun flushableReturnsPendingNotFailed() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .enqueue("s1", "local-2", "b", "t1")
        assertEquals(listOf("local-1", "local-2"), q.flushable("s1").map { it.localId })
    }

    @Test
    fun markDeliveredAcksAndClears() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markDelivered("s1", "local-1")
        assertFalse(q.isPending("local-1", "s1"))
        assertTrue(q.entries("s1").isEmpty())
        // Empty session prunes its key so persistence stays compact.
        assertTrue(q.bySession.isEmpty())
    }

    // --- Durable delivery / broker ack (task K) ---

    @Test
    fun markSentKeepsEntryQueued() {
        // A WS-write success now only marks the entry `sent`; it stays queued
        // until the broker acks. This is the core of the "send then background
        // -> lost but shown as sent" fix.
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markSent("s1", "local-1")
        assertTrue(q.isPending("local-1", "s1"))
        assertTrue(q.entries("s1").first().sent)
    }

    @Test
    fun sentEntryStillFlushable() {
        // An un-acked sent entry is re-attempted on the next flush (resend after
        // app kill); the broker dedups by client_msg_id so no double reaches the
        // agent.
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markSent("s1", "local-1")
        assertEquals(listOf("local-1"), q.flushable("s1").map { it.localId })
    }

    @Test
    fun brokerAckClearsSentEntry() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markSent("s1", "local-1")
            .markDelivered("s1", "local-1")
        assertFalse(q.isPending("local-1", "s1"))
        assertTrue(q.bySession.isEmpty())
    }

    @Test
    fun retryClearsSentFlag() {
        var q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markSent("s1", "local-1")
        repeat(PendingChatQueue.MAX_ATTEMPTS) { q = q.markAttemptFailed("s1", "local-1") }
        q = q.retry("s1", "local-1")
        assertFalse(q.entries("s1").first().sent)
    }

    @Test
    fun sentFlagRoundTripsThroughJson() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markSent("s1", "local-1")
        val restored = PendingChatQueue.decode(PendingChatQueue.encode(q))
        assertTrue(restored.entries("s1").first().sent)
    }

    @Test
    fun transientFailureKeepsEntryQueuedAndPending() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markAttemptFailed("s1", "local-1")
        assertTrue(q.isPending("local-1", "s1"))
        assertFalse(q.isFailed("local-1", "s1"))
        // Still in the flush set -- a later reconnect retries it.
        assertEquals(1, q.flushable("s1").size)
    }

    @Test
    fun failsAfterMaxAttempts() {
        var q = PendingChatQueue().enqueue("s1", "local-1", "a", "t0")
        repeat(PendingChatQueue.MAX_ATTEMPTS) { q = q.markAttemptFailed("s1", "local-1") }
        assertTrue(q.isFailed("local-1", "s1"))
        // A failed entry is no longer auto-flushed (waits for explicit retry).
        assertTrue(q.flushable("s1").isEmpty())
        // ...but stays queued so the bubble can offer retry.
        assertTrue(q.isPending("local-1", "s1"))
    }

    @Test
    fun retryReArmsFailedEntry() {
        var q = PendingChatQueue().enqueue("s1", "local-1", "a", "t0")
        repeat(PendingChatQueue.MAX_ATTEMPTS) { q = q.markAttemptFailed("s1", "local-1") }
        assertTrue(q.isFailed("local-1", "s1"))
        q = q.retry("s1", "local-1")
        assertFalse(q.isFailed("local-1", "s1"))
        assertEquals(1, q.flushable("s1").size)
        assertEquals(0, q.entries("s1").first().attempts)
    }

    @Test
    fun clearDropsSessionQueue() {
        val q = PendingChatQueue().enqueue("s1", "local-1", "a", "t0").clear("s1")
        assertTrue(q.entries("s1").isEmpty())
    }

    @Test
    fun independentSessions() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .enqueue("s2", "local-2", "b", "t1")
            .markDelivered("s1", "local-1")
        assertFalse(q.isPending("local-1", "s1"))
        assertTrue(q.isPending("local-2", "s2"))
    }

    @Test
    fun encodeDecodeRoundTrip() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "hello", "t0")
            .markAttemptFailed("s1", "local-1")
        val restored = PendingChatQueue.decode(PendingChatQueue.encode(q))
        assertTrue(restored.isPending("local-1", "s1"))
        val entry = restored.entries("s1").first()
        assertEquals("hello", entry.message)
        assertEquals(1, entry.attempts)
    }

    @Test
    fun decodeBlankIsEmpty() {
        assertTrue(PendingChatQueue.decode(null).bySession.isEmpty())
        assertTrue(PendingChatQueue.decode("").bySession.isEmpty())
        assertTrue(PendingChatQueue.decode("not json").bySession.isEmpty())
    }

    // --- "Queued Next" / steer extensions (spec PR #481) ---

    /**
     * Regression for #479: normal (no active turn) entries must still appear
     * in flushable() and NOT in queuedTurnEntries().
     */
    @Test
    fun normalEntryFlushableAndNotQueuedTurn() {
        val q = PendingChatQueue().enqueue("s1", "local-1", "hi", "t0")
        assertEquals(1, q.flushable("s1").size)
        assertTrue(q.queuedTurnEntries("s1").isEmpty())
        assertEquals(PendingChatKind.normal, q.entries("s1").first().kind)
    }

    /**
     * enqueueQueued produces a queuedTurn entry that is NOT in flushable()
     * (so the connect/foreground flush ignores it) but IS in queuedTurnEntries().
     */
    @Test
    fun enqueueQueuedIsHeldFromFlush() {
        val q = PendingChatQueue().enqueueQueued("s1", "local-1", "msg", "t0")
        assertTrue(q.flushable("s1").isEmpty())
        assertEquals(1, q.queuedTurnEntries("s1").size)
        assertEquals(PendingChatKind.queuedTurn, q.entries("s1").first().kind)
    }

    /** enqueueQueued is idempotent on localId. */
    @Test
    fun enqueueQueuedIsIdempotent() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "msg", "t0")
            .enqueueQueued("s1", "local-1", "msg", "t0")
        assertEquals(1, q.entries("s1").size)
    }

    /**
     * flushOnTurnComplete returns the OLDEST queuedTurn entry and does not
     * remove it (caller drives removal via markDelivered).
     */
    @Test
    fun flushOnTurnCompleteReturnsOldest() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "first", "t0")
            .enqueueQueued("s1", "local-2", "second", "t1")
        val next = q.flushOnTurnComplete("s1")
        assertEquals("local-1", next?.localId)
        // Entry is still present -- caller must markDelivered + re-enqueue.
        assertEquals(2, q.queuedTurnEntries("s1").size)
    }

    /** flushOnTurnComplete returns null when nothing is queued. */
    @Test
    fun flushOnTurnCompleteNullWhenEmpty() {
        val q = PendingChatQueue()
        assertNull(q.flushOnTurnComplete("s1"))
    }

    /** flushOnTurnComplete also picks up retrying entries. */
    @Test
    fun flushOnTurnCompletePicksUpRetrying() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "msg", "t0")
            .markSteeringFailed("s1", "local-1")
        val next = q.flushOnTurnComplete("s1")
        assertEquals("local-1", next?.localId)
        assertEquals(PendingChatKind.retrying, q.entries("s1").first().kind)
    }

    /** markSteering transitions kind from queuedTurn to steering. */
    @Test
    fun markSteeringTransitionsKind() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "msg", "t0")
            .markSteering("s1", "local-1")
        assertEquals(PendingChatKind.steering, q.entries("s1").first().kind)
        // Still in queuedTurnEntries (steering is part of the panel).
        assertEquals(1, q.queuedTurnEntries("s1").size)
        // NOT in flushable.
        assertTrue(q.flushable("s1").isEmpty())
    }

    /** markSteeringFailed transitions kind to retrying. */
    @Test
    fun markSteeringFailedTransitionsToRetrying() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "msg", "t0")
            .markSteering("s1", "local-1")
            .markSteeringFailed("s1", "local-1")
        assertEquals(PendingChatKind.retrying, q.entries("s1").first().kind)
    }

    /** cancel removes the entry entirely. */
    @Test
    fun cancelRemovesEntry() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "msg", "t0")
            .cancel("s1", "local-1")
        assertFalse(q.isPending("local-1", "s1"))
        assertTrue(q.queuedTurnEntries("s1").isEmpty())
    }

    /** cancel is a no-op for unknown ids. */
    @Test
    fun cancelNoOpForUnknown() {
        val q = PendingChatQueue().enqueueQueued("s1", "local-1", "msg", "t0")
        val q2 = q.cancel("s1", "local-99")
        assertEquals(1, q2.entries("s1").size)
    }

    /**
     * Queue-while-active ordering: multiple messages flush one at a time
     * (flushOnTurnComplete returns the oldest each call after markDelivered).
     */
    @Test
    fun queueWhileActiveFlushesOneAtATime() {
        var q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "first", "t0")
            .enqueueQueued("s1", "local-2", "second", "t1")
            .enqueueQueued("s1", "local-3", "third", "t2")

        // First turn-complete: flush oldest.
        val first = q.flushOnTurnComplete("s1")
        assertEquals("local-1", first?.localId)
        q = q.markDelivered("s1", first!!.localId)

        // Second turn-complete: flush next oldest.
        val second = q.flushOnTurnComplete("s1")
        assertEquals("local-2", second?.localId)
        q = q.markDelivered("s1", second!!.localId)

        // Third turn-complete: last one.
        val third = q.flushOnTurnComplete("s1")
        assertEquals("local-3", third?.localId)
        q = q.markDelivered("s1", third!!.localId)

        assertNull(q.flushOnTurnComplete("s1"))
    }

    /**
     * Persistence round-trip preserves kind field (queuedTurn / steering /
     * retrying survive encode/decode).
     */
    @Test
    fun encodeDecodePreservesKind() {
        val q = PendingChatQueue()
            .enqueueQueued("s1", "local-1", "steer me", "t0")
            .markSteering("s1", "local-1")
            .enqueueQueued("s1", "local-2", "retry me", "t1")
            .markSteeringFailed("s1", "local-2")
        val restored = PendingChatQueue.decode(PendingChatQueue.encode(q))
        val entries = restored.entries("s1")
        assertEquals(2, entries.size)
        assertEquals(PendingChatKind.steering, entries[0].kind)
        assertEquals(PendingChatKind.retrying, entries[1].kind)
    }

    /**
     * Capability decode: supportsSteer is true for codex (static descriptor)
     * and false for claude. Exercises descriptorFor() + staticAgentDescriptors.
     */
    @Test
    fun capabilityDecodeStaticDescriptors() {
        val codexDesc = staticAgentDescriptors["codex"]!!
        assertTrue("codex should supportsSteer", codexDesc.supportsSteer)
        val claudeDesc = staticAgentDescriptors["claude"]!!
        assertFalse("claude should not supportsSteer", claudeDesc.supportsSteer)
    }

    /**
     * parseAgentDescriptors decodes supports.steer from JSON.
     */
    @Test
    fun parseAgentDescriptorsDecodesSteer() {
        val raw = """
            {
              "agents": {
                "myagent": {
                  "display_name": "MyAgent",
                  "login_provider": "openai",
                  "supports": {
                    "compact": false,
                    "ask_user_question": false,
                    "effort": false,
                    "plan_mode": false,
                    "usage": false,
                    "steer": true
                  }
                },
                "nonsteer": {
                  "display_name": "NoSteer",
                  "login_provider": "",
                  "supports": {
                    "steer": false
                  }
                }
              }
            }
        """.trimIndent()
        val descriptors = parseAgentDescriptors(raw)
        assertTrue("myagent should supportsSteer", descriptors["myagent"]!!.supportsSteer)
        assertFalse("nonsteer should not supportsSteer", descriptors["nonsteer"]!!.supportsSteer)
    }

    /**
     * parseAgentDescriptors defaults steer=false when the key is absent
     * (old broker).
     */
    @Test
    fun parseAgentDescriptorsDefaultsSteerFalse() {
        val raw = """
            {
              "agents": {
                "legacy": {
                  "display_name": "Legacy",
                  "login_provider": "",
                  "supports": {}
                }
              }
            }
        """.trimIndent()
        val descriptors = parseAgentDescriptors(raw)
        assertFalse("absent steer key should default false", descriptors["legacy"]!!.supportsSteer)
    }
}
