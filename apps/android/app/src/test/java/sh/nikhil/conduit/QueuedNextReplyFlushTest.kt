package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ChatEvent
import uniffi.conduit_core.SessionStatus

/**
 * Pins the belt-and-suspenders flush triggered by a live assistant reply
 * (flushOnReply). The existing trigger -- a status frame reporting
 * turnActive=false (flushOnTurnComplete) -- can be missed on reconnect.
 * A live reply is independent proof the turn ended.
 *
 * Mirror of iOS SessionStoreTests "flushQueuedOnReply" suite.
 */
class QueuedNextReplyFlushTest {

    private fun status(
        id: String,
        phase: String,
        turnActive: Boolean?,
    ) = SessionStatus(
        session = id,
        assistant = "claude",
        phase = phase,
        health = "green",
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
        turnActive = turnActive,
    )

    /**
     * A queuedTurn entry IS delivered (removed from queue) when a LIVE
     * assistant reply arrives even though turnActive is still true
     * (simulates a missed or delayed status frame).
     */
    @Test
    fun queuedTurnFlushedOnLiveAssistantReplyEvenWhenTurnStillActive() {
        val store = SessionStore()
        val sessionId = "test-flush-reply-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:01:00.000Z"

        // Seed turnActive=true.
        store.onStatus(status(sessionId, "running", turnActive = true))
        assertTrue("turn must be active", store.statusBySession.value[sessionId]?.turnActive == true)

        // Seed an active streaming turn.
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Streaming...",
            "turn_ts" to turnTs,
        ))

        // User sends a message while turn is active -- goes into QueuedNext.
        store.sendChat(sessionId, "queued message")
        assertTrue(
            "message must land in the queued-turn panel",
            _pendingChats(store).queuedTurnEntries(sessionId).isNotEmpty(),
        )

        // A LIVE assistant reply arrives (same ts as the streaming turn).
        // turnActive is still true at this point (missed status frame).
        store.onChatEvent(sessionId, ChatEvent(
            role = "assistant",
            content = "Assistant reply.",
            ts = turnTs,
            files = emptyList(),
        ))

        // The queued entry must now be gone from the panel (delivered).
        assertTrue(
            "queuedTurn entry must be flushed when a live assistant reply arrives",
            _pendingChats(store).queuedTurnEntries(sessionId).isEmpty(),
        )

        // The conversation log must contain the user echo (was there before delivery;
        // still present after flush -- not removed).
        val userMsgs = store.conversationLog.value[sessionId].orEmpty().filter { it.role == "user" }
        assertTrue(
            "flushed message must have a user echo in the conversation log",
            userMsgs.any { it.content == "queued message" },
        )
    }

    /**
     * A REPLAYED (older-ts) assistant event must NOT flush the queued-turn
     * entry (shouldClearStreaming == false path).
     */
    @Test
    fun queuedTurnNotFlushedOnReplayedOlderAssistantReply() {
        val store = SessionStore()
        val sessionId = "test-no-flush-replay-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:01:00.000Z"

        // Seed turnActive=true.
        store.onStatus(status(sessionId, "running", turnActive = true))

        // Active streaming turn at turnTs.
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Live streaming...",
            "turn_ts" to turnTs,
        ))

        // User queues a message.
        store.sendChat(sessionId, "next question")
        assertTrue(_pendingChats(store).queuedTurnEntries(sessionId).isNotEmpty())

        // Broker replays an OLDER assistant message (ts < turnTs).
        store.onChatEvent(sessionId, ChatEvent(
            role = "assistant",
            content = "Old reply from previous turn.",
            ts = "2026-07-01T12:00:00.000Z",
            files = emptyList(),
        ))

        // The queued entry must still be there -- replay must NOT flush.
        assertFalse(
            "queued entry must NOT be flushed by a replayed older assistant reply",
            _pendingChats(store).queuedTurnEntries(sessionId).isEmpty(),
        )
    }

    /**
     * No double-send: when both the reply-flush (flushOnReply) and the
     * subsequent turnActive->false status frame (flushOnTurnComplete) fire,
     * the second one is a no-op (flushOnTurnComplete returns null).
     */
    @Test
    fun noDoubleSendWhenBothReplyFlushAndStatusFrameFire() {
        val store = SessionStore()
        val sessionId = "test-double-send-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:02:00.000Z"

        // Seed turnActive=true.
        store.onStatus(status(sessionId, "running", turnActive = true))
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Streaming...",
            "turn_ts" to turnTs,
        ))

        // Queue one message.
        store.sendChat(sessionId, "only once")
        assertEquals(1, _pendingChats(store).queuedTurnEntries(sessionId).size)

        // Trigger 1: live assistant reply flushes the entry.
        store.onChatEvent(sessionId, ChatEvent(
            role = "assistant",
            content = "Reply.",
            ts = turnTs,
            files = emptyList(),
        ))
        assertTrue(
            "entry must be flushed after reply",
            _pendingChats(store).queuedTurnEntries(sessionId).isEmpty(),
        )

        // Capture user-echo count after reply-flush.
        val echoCountAfterReply = store.conversationLog.value[sessionId]
            .orEmpty().count { it.role == "user" }

        // Trigger 2: status frame reporting turnActive=false (normal path).
        store.onStatus(status(sessionId, "idle", turnActive = false))

        // No additional echo -- flushOnTurnComplete returned null (already empty).
        val echoCountAfterStatus = store.conversationLog.value[sessionId]
            .orEmpty().count { it.role == "user" }
        assertEquals(
            "status frame after reply-flush must not create a duplicate echo",
            echoCountAfterReply, echoCountAfterStatus,
        )
    }

    /**
     * bypassTurnGate=false (default) keeps existing callers byte-identical:
     * a message sent while turnActive=true still goes to the queued panel.
     */
    @Test
    fun bypassTurnGateDefaultFalseKeepsQueueGateBehavior() {
        val store = SessionStore()
        val sessionId = "test-bypass-default-${java.util.UUID.randomUUID()}"

        store.onStatus(status(sessionId, "running", turnActive = true))
        assertTrue(store.statusBySession.value[sessionId]?.turnActive == true)

        // Default sendChat (bypassTurnGate=false) must queue.
        store.sendChat(sessionId, "should be queued")
        assertFalse(
            "default sendChat must still queue when turn is active",
            _pendingChats(store).queuedTurnEntries(sessionId).isEmpty(),
        )

        // Explicit bypassTurnGate=true must bypass the queue.
        // The echo was created by the first sendChat; we only check that a
        // second sendChat with bypass goes through the normal deliver path
        // (adds a new normal pending entry, not another queuedTurn).
        val queuedCountBefore = _pendingChats(store).queuedTurnEntries(sessionId).size
        store.sendChat(sessionId, "should bypass", bypassTurnGate = true)
        // The queuedTurn panel count must NOT increase.
        val queuedCountAfter = _pendingChats(store).queuedTurnEntries(sessionId).size
        assertEquals(
            "bypassTurnGate=true must not add to the queued-turn panel",
            queuedCountBefore, queuedCountAfter,
        )
    }

    /** Access the current PendingChatQueue snapshot for assertions. */
    private fun _pendingChats(store: SessionStore): PendingChatQueue =
        store.pendingChats.value
}
