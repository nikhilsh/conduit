package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.SessionStatus

/**
 * Pins fix 2: flushOnTurnComplete / flushOnReply must deliver under the
 * ORIGINAL localId minted when the message was queued, NOT mint a new id
 * via a second sendChat call.
 *
 * A new id would orphan the original pending echo (stuck "pending" forever)
 * and break broker dedup (client_msg_id changes between a steer attempt and
 * the flush delivery). Mirror of iOS SessionStoreTests.flushPreservesOriginalLocalID.
 */
class FlushPreservesLocalIdTest {

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
    fun flushOnTurnCompletePreservesOriginalLocalId() {
        val store = SessionStore()
        val sessionId = "test-localid-${java.util.UUID.randomUUID()}"

        // Seed turnActive=true so sendChat goes through the queuedTurn path.
        store.onStatus(activeStatus(sessionId))

        // Queue a message -- echo is created in sendChat before the turn gate.
        store.sendChat(sessionId, "preserve my id")
        val queuedEntries = store.pendingChats.value.queuedTurnEntries(sessionId)
        assertEquals("one queuedTurn entry", 1, queuedEntries.size)
        val originalLocalId = queuedEntries.first().localId
        assertTrue("entry has a local- id", originalLocalId.startsWith("local-"))

        // The echo must exist in conversationLog with the original localId.
        val echoBefore = store.conversationLog.value[sessionId]
            ?.firstOrNull { it.id == originalLocalId }
        assertNotNull("echo must exist in log before flush", echoBefore)
        assertEquals("pending", echoBefore?.status)

        // Flush (turn ended).
        store.flushOnTurnComplete(sessionId)

        // The queuedTurn entry must be gone.
        assertTrue(
            "queuedTurn entry must be gone after flush",
            store.pendingChats.value.queuedTurnEntries(sessionId).isEmpty(),
        )

        // Exactly ONE user echo -- no duplicate from a second sendChat call.
        val userEchoes = store.conversationLog.value[sessionId]
            .orEmpty().filter { it.role == "user" }
        assertEquals("no duplicate echo created on flush", 1, userEchoes.size)

        // The surviving echo must carry the ORIGINAL localId.
        assertEquals(
            "echo must keep original localId after flush (broker dedup key stable)",
            originalLocalId, userEchoes.first().id,
        )

        // The entry is re-registered as .normal for delivery.
        val normalEntry = store.pendingChats.value.entries(sessionId)
            .firstOrNull { it.localId == originalLocalId }
        assertNotNull("entry re-registered as normal under original localId", normalEntry)
        assertEquals(PendingChatKind.normal, normalEntry?.kind)
    }

    @Test
    fun noOrphanedEchoAfterFlush() {
        val store = SessionStore()
        val sessionId = "test-orphan-${java.util.UUID.randomUUID()}"

        store.onStatus(activeStatus(sessionId))
        store.sendChat(sessionId, "no orphan")

        val originalLocalId = store.pendingChats.value
            .queuedTurnEntries(sessionId).first().localId

        store.flushOnTurnComplete(sessionId)

        // All user echoes must have the original localId -- no unreferenced
        // "pending" echo with a stale id floating in the log.
        val localEchoes = store.conversationLog.value[sessionId]
            .orEmpty()
            .filter { it.role == "user" && it.id.startsWith("local-") }
        assertTrue(
            "all local echoes must be the original id -- no orphan",
            localEchoes.all { it.id == originalLocalId },
        )
    }
}
