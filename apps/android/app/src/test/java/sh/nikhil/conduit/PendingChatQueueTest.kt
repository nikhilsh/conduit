package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the optimistic-send pending-queue state machine: queue on send ->
 * flush when ready -> ack clears -> failure path after retries -> retry
 * re-arms, plus JSON persistence round-trip. Pure logic, no live WS. Mirror
 * of iOS `PendingChatQueueTests`.
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

    @Test
    fun transientFailureKeepsEntryQueuedAndPending() {
        val q = PendingChatQueue()
            .enqueue("s1", "local-1", "a", "t0")
            .markAttemptFailed("s1", "local-1")
        assertTrue(q.isPending("local-1", "s1"))
        assertFalse(q.isFailed("local-1", "s1"))
        // Still in the flush set — a later reconnect retries it.
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
}
