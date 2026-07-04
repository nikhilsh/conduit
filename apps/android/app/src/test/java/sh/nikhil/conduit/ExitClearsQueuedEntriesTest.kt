package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.SessionStatus

/**
 * Pins fix 3: when a session exits any queuedTurn entries that were waiting
 * for the turn to end must be marked "failed" (so the user sees the visual
 * indicator that the message was not sent) and removed from the queue (so
 * flushPendingChats never attempts delivery into a dead session).
 *
 * Mirror of iOS SessionStoreTests.exitClearsQueuedEntriesAndMarksFailed.
 */
class ExitClearsQueuedEntriesTest {

    private fun activeStatus(sessionId: String) = SessionStatus(
        session = sessionId,
        assistant = "claude",
        phase = "running",
        health = "healthy",
        rows = 40u,
        cols = 120u,
        yolo = false,
        preview = null,
        sessionName = null,
        viewers = 1u,
        reasoningEffort = null,
        cwd = null,
        startedAt = null,
        lastActivityAt = null,
        displayName = null,
        turnActive = true,
    )

    @Test
    fun exitClearsQueueAndMarksEchoFailed() {
        val store = SessionStore()
        val sessionId = "test-exit-clear-${java.util.UUID.randomUUID()}"

        // Seed turnActive=true so sendChat goes into queuedTurn.
        store.onStatus(activeStatus(sessionId))

        // Queue a message while turn is active.
        store.sendChat(sessionId, "will never send")
        val queued = store.pendingChats.value.queuedTurnEntries(sessionId)
        assertTrue("message must be in queuedTurn", queued.isNotEmpty())
        val localId = queued.first().localId

        // Echo must exist in conversationLog (created by sendChat before turn gate).
        val echoBefore = store.conversationLog.value[sessionId]
            ?.firstOrNull { it.id == localId }
        assertNotNull("echo must exist before exit", echoBefore)
        assertEquals("pending", echoBefore?.status)

        // Session exits.
        store.onExit(sessionId, 1)

        // Queue must be empty -- no re-delivery into a dead session.
        assertTrue(
            "queue must be cleared on exit",
            store.pendingChats.value.entries(sessionId).isEmpty(),
        )

        // Echo must be marked "failed" so the user knows the message was not sent.
        val echoAfter = store.conversationLog.value[sessionId]
            ?.firstOrNull { it.id == localId }
        assertEquals(
            "queued echo must be marked failed when session exits",
            "failed", echoAfter?.status,
        )
    }

    @Test
    fun exitWithNoQueuedEntriesIsNoop() {
        val store = SessionStore()
        val sessionId = "test-exit-noop-${java.util.UUID.randomUUID()}"

        // Exit with no queued entries -- must not throw or corrupt state.
        store.onExit(sessionId, 0)

        assertTrue(
            "no queue entries after no-op exit",
            store.pendingChats.value.entries(sessionId).isEmpty(),
        )
    }
}
