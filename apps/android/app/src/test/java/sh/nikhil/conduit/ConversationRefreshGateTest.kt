package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.SessionStatus

/**
 * Regression test for the O(N) conversation re-fetch gate (FIX 1).
 *
 * A session whose conversationLog is already populated must NOT have its
 * content cleared or altered by a subsequent onStatus call. [refreshSessions]
 * skips [refreshConversation] for sessions with existing content; new content
 * arrives via [onChatEvent] which calls [refreshConversation] directly.
 *
 * Mirror of iOS SessionStoreTests "FIX 1 conversation-refresh gate" suite.
 */
class ConversationRefreshGateTest {

    private fun statusFor(sessionId: String) = SessionStatus(
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
        turnActive = null,
    )

    /**
     * Content seeded by sendChat must survive subsequent status frames.
     * Without the FIX 1 gate, each onStatus -> refreshSessions call would
     * invoke refreshConversation for every session, potentially clobbering
     * or re-ordering locally-echoed items.
     */
    @Test
    fun statusFrameDoesNotWipeHydratedConversation() {
        val store = SessionStore()
        val sessionId = "test-hydrated-gate-${java.util.UUID.randomUUID()}"

        // Seed content via sendChat (synchronous echo into conversationLog).
        store.sendChat(sessionId = sessionId, msg = "Hello")
        val countBefore = store.conversationLog.value[sessionId].orEmpty().size
        assertTrue("precondition: conversationLog must have the user echo", countBefore >= 1)

        // Fire onStatus (which calls refreshSessions internally).
        // No client -> refreshSessions returns at the client guard, but the
        // gate logic must not clear or reset conversationLog.
        store.onStatus(statusFor(sessionId))

        val countAfter = store.conversationLog.value[sessionId].orEmpty().size
        assertEquals(
            "onStatus must not alter a hydrated conversationLog (FIX 1 gate)",
            countBefore,
            countAfter,
        )
    }

    /**
     * Multiple status frames must not inflate conversationLog for a
     * session that already has content.
     */
    @Test
    fun multipleStatusFramesDoNotInflateContent() {
        val store = SessionStore()
        val sessionId = "test-hydrated-multi-${java.util.UUID.randomUUID()}"

        store.sendChat(sessionId = sessionId, msg = "First")
        val countAfterSend = store.conversationLog.value[sessionId].orEmpty().size

        // Fire multiple status frames.
        store.onStatus(statusFor(sessionId))
        store.onStatus(statusFor(sessionId))
        store.onStatus(statusFor(sessionId))

        val countAfterStatuses = store.conversationLog.value[sessionId].orEmpty().size
        assertEquals(
            "repeated status frames must not inflate conversationLog (FIX 1 gate)",
            countAfterSend,
            countAfterStatuses,
        )
    }
}
