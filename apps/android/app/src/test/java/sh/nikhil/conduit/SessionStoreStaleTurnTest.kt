package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConnectionHealth
import uniffi.conduit_core.SessionStatus

/**
 * Regression test for "stuck on Stop after broker restart until force-quit".
 *
 * After a broker restart the app reconnects but the stale turn_active=true
 * status is still in memory. The composer stays on the Stop button and every
 * subsequent sendChat is silently queued -- the user sees the message appear
 * to send but the agent never receives it. Force-quitting fixed it because
 * the stale status was cleared on cold start.
 *
 * Fix: [SessionStore.onConnectionHealth] clears turnActive + streaming state
 * on [ConnectionHealth.Connecting] and non-auth [ConnectionHealth.Disconnected]
 * so the gate opens immediately without waiting for the reconnect status frame.
 * On [ConnectionHealth.Connected], any stuck [PendingChatKind.queuedTurn]
 * entries are promoted to [PendingChatKind.normal] so [flushPendingChats]
 * delivers them.
 *
 * Mirror of iOS SessionStoreTests "Stale turn state cleared on broker-restart
 * reconnect" suite.
 */
class SessionStoreStaleTurnTest {

    private fun statusWith(sessionId: String, turnActive: Boolean?) = SessionStatus(
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
        turnActive = turnActive,
    )

    private fun activeStatus(sessionId: String) = statusWith(sessionId, turnActive = true)

    /**
     * Deadlock fix (level-triggered flush): a queuedTurn entry left over after a
     * broker restart must be delivered when an idle status frame arrives, even
     * with NO turnActive true->false edge. The reconnect worker fires
     * [ConnectionHealth.Connecting] (clearStaleTurnState zeroes turnActive +
     * _lastTurnActive) WITHOUT promoting the queued entry; then the recovered
     * session's status frame comes back idle. With no edge (and if the
     * .Connected promotion did not fire first) the queued message is stuck
     * forever. The level-triggered branch in onStatus delivers it.
     *
     * Mirror of iOS SessionStoreTests.queuedTurnFlushedOnIdleStatusWithoutEdge.
     */
    @Test
    fun queuedTurnFlushedOnIdleStatusWithoutEdge() {
        val store = SessionStore()
        val sessionId = "test-flush-idle-${java.util.UUID.randomUUID()}"

        // Turn active -> the user's message is parked in "Queued Next".
        store.onStatus(activeStatus(sessionId))
        store.sendChat(sessionId = sessionId, msg = "stuck after restart")
        assertTrue(
            "precondition: message must be queued while the turn is active",
            store.pendingChats.value.queuedTurnEntries(sessionId).isNotEmpty(),
        )

        // Broker restarts: .Connecting zeroes stale turn state (no promotion).
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 5u))

        // Recovered session reports idle. No true->false edge (prior already
        // false) -> only the level-triggered flush can deliver the entry.
        store.onStatus(statusWith(sessionId, turnActive = false))

        assertTrue(
            "queued entry must flush on an idle status frame even without a turn-active edge",
            store.pendingChats.value.queuedTurnEntries(sessionId).isEmpty(),
        )
        val userMsgs = store.conversationLog.value[sessionId].orEmpty().filter { it.role == "user" }
        assertTrue(
            "flushed message must have a user echo in the conversation log",
            userMsgs.any { it.content == "stuck after restart" },
        )
    }

    /**
     * ConnectionHealth.Connecting must clear stale turnActive and streaming state
     * so the send gate opens immediately without waiting for the reconnect status
     * frame.
     */
    @Test
    fun connectingClearsStaleTurnActive() {
        val store = SessionStore()
        val sessionId = "test-stale-connecting-${java.util.UUID.randomUUID()}"

        // Seed turn_active=true + streaming state (simulates mid-turn broker restart).
        store.onStatus(activeStatus(sessionId))
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "In-flight response...",
            "turn_ts" to "2026-07-03T10:00:00.000Z",
        ))
        store.ingestTurnPhase(sessionId, mapOf("turn_phase" to "writing"))

        // Verify precondition: turn is active.
        assertTrue(
            "precondition: turnActive must be true before connecting",
            store.statusBySession.value[sessionId]?.turnActive == true,
        )

        // Simulate the Rust core firing ConnectionHealth.Connecting(1, 5).
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 5u))

        // Turn gate must be open so the next sendChat is delivered, not queued.
        assertFalse(
            "connecting must clear stale turnActive so the send gate opens",
            store.statusBySession.value[sessionId]?.turnActive == true,
        )

        // Streaming UI state must be cleared so the Stop button goes away.
        assertNull(
            "connecting must clear streamingMessage",
            store.streamingMessage.value[sessionId],
        )
        assertNull(
            "connecting must clear turnPhaseBySession",
            store.turnPhaseBySession.value[sessionId],
        )
    }

    /**
     * Non-auth ConnectionHealth.Disconnected must clear stale turnActive and
     * streaming state (broker restart / network drop).
     */
    @Test
    fun nonAuthDisconnectedClearsStaleTurnActive() {
        val store = SessionStore()
        val sessionId = "test-stale-disconnected-${java.util.UUID.randomUUID()}"

        // Seed turn_active=true + streaming state.
        store.onStatus(activeStatus(sessionId))
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Partial...",
            "turn_ts" to "2026-07-03T10:00:00.000Z",
        ))
        store.ingestTurnPhase(sessionId, mapOf("turn_phase" to "working"))

        assertTrue(
            "precondition: turnActive must be true before disconnect",
            store.statusBySession.value[sessionId]?.turnActive == true,
        )

        // Simulate a non-auth disconnection (broker restart / network drop).
        store.onConnectionHealth(sessionId, ConnectionHealth.Disconnected(reason = "EOF", auth = false))

        // Stale turn state must be gone.
        assertFalse(
            "non-auth disconnected must clear stale turnActive",
            store.statusBySession.value[sessionId]?.turnActive == true,
        )
        assertNull(
            "non-auth disconnected must clear streamingMessage",
            store.streamingMessage.value[sessionId],
        )
        assertNull(
            "non-auth disconnected must clear turnPhaseBySession",
            store.turnPhaseBySession.value[sessionId],
        )
    }

    /**
     * On Connected after a Connecting-clear, any stuck queuedTurn entries must
     * be promoted to normal so flushPendingChats can deliver them.
     */
    @Test
    fun connectedPromotesQueuedTurnEntries() {
        val store = SessionStore()
        val sessionId = "test-promote-queued-${java.util.UUID.randomUUID()}"

        // Seed turn_active=true so sendChat queues rather than delivers.
        store.onStatus(activeStatus(sessionId))

        // User sends while turn is active -- lands in queuedTurn.
        store.sendChat(sessionId = sessionId, msg = "stuck message")
        assertTrue(
            "message must be queuedTurn while turn is active",
            store.pendingChats.value.queuedTurnEntries(sessionId).isNotEmpty(),
        )

        // Broker restarts: connecting fires first (clears turn state).
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 5u))
        assertFalse(
            "turn gate must be clear after Connecting",
            store.statusBySession.value[sessionId]?.turnActive == true,
        )

        // On reconnect: Connected must promote the stuck queuedTurn entry to normal.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connected)

        // The entry must now be normal (promoted), no longer a queuedTurn entry.
        assertTrue(
            "queuedTurn entry must be promoted to normal on Connected",
            store.pendingChats.value.queuedTurnEntries(sessionId).isEmpty(),
        )
    }
}
