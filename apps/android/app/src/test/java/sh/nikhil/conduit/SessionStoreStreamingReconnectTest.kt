package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.conduit_core.ChatEvent
import uniffi.conduit_core.SessionStatus

/**
 * Pins Bug B fix: streaming state survives broker replay on WS reconnect.
 *
 * Root cause: [SessionStore.onChatEvent] unconditionally cleared
 * [SessionStore._streamingMessage] and [SessionStore._turnPhaseBySession]
 * for every replayed older assistant event. On reconnect the broker replays
 * the last 200 settled messages; each replay evicted the live streaming
 * overlay, making the chat look dead mid-turn ("looks dead" bug).
 *
 * Fix: guard the clear with a timestamp comparison against
 * [SessionStore._streamingTurnTs]. Only clear when the event ts is >=
 * the streaming turn ts (current or newer turn). A safety net in
 * [SessionStore.onStatus] covers cancelled turns / clock skew.
 *
 * Mirror of iOS SessionStoreTests "Bug B" suite.
 */
class SessionStoreStreamingReconnectTest {

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
     * A replayed OLD assistant event (ts < active streamingTurnTs) must NOT
     * clear streamingMessage or turnPhaseBySession.
     */
    @Test
    fun oldReplayedAssistantEventDoesNotClearStreamingState() {
        val store = SessionStore()
        val sessionId = "test-replay-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:00:01.000Z"

        // Simulate an active streaming turn via ingestChatStreaming.
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Partial response so far...",
            "turn_ts" to turnTs,
        ))
        // Manually seed the turn phase (mirrors what ingestTurnPhase sets).
        store.ingestTurnPhase(sessionId, mapOf("turn_phase" to "writing"))

        // Broker replays an OLDER settled assistant message (ts < turnTs).
        val olderReplay = ChatEvent(
            role = "assistant",
            content = "This is a prior completed reply.",
            ts = "2026-07-01T12:00:00.000Z", // older than turnTs
            files = emptyList(),
        )
        store.onChatEvent(sessionId, olderReplay)

        // The live streaming state must be intact.
        assertEquals(
            "old replay must not clear in-flight streamingMessage",
            "Partial response so far...",
            store.streamingMessage.value[sessionId],
        )
        assertEquals(
            "old replay must not clear in-flight turnPhaseBySession",
            "writing",
            store.turnPhaseBySession.value[sessionId],
        )
    }

    /**
     * The current-turn final assistant event (ts >= streamingTurnTs) DOES
     * clear streaming state — normal turn-complete path must still work.
     */
    @Test
    fun currentTurnAssistantEventClearsStreamingState() {
        val store = SessionStore()
        val sessionId = "test-current-turn-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:00:01.000Z"

        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "Streaming...",
            "turn_ts" to turnTs,
        ))
        store.ingestTurnPhase(sessionId, mapOf("turn_phase" to "writing"))

        // The final message arrives with the SAME ts as the streaming turn.
        val finalMsg = ChatEvent(
            role = "assistant",
            content = "Final completed reply.",
            ts = turnTs, // same ts as the streaming turn
            files = emptyList(),
        )
        store.onChatEvent(sessionId, finalMsg)

        // Streaming state must be cleared.
        assertNull(
            "final turn message must clear streamingMessage",
            store.streamingMessage.value[sessionId],
        )
        assertNull(
            "final turn message must clear turnPhaseBySession",
            store.turnPhaseBySession.value[sessionId],
        )
    }

    /**
     * A status frame with turnActive=false clears streaming state
     * (safety net for cancelled turns / clock skew where no matching
     * final assistant event arrives).
     */
    @Test
    fun statusTurnActiveFalseClearsStreamingState() {
        val store = SessionStore()
        val sessionId = "test-turn-done-${java.util.UUID.randomUUID()}"

        // Seed active streaming state.
        store.ingestChatStreaming(sessionId, mapOf(
            "content" to "In progress...",
            "turn_ts" to "2026-07-01T12:00:01.000Z",
        ))
        store.ingestTurnPhase(sessionId, mapOf("turn_phase" to "working"))

        // Mark the turn active first so the transition is detected.
        store.onStatus(status(sessionId, phase = "running", turnActive = true))

        // Now turn transitions to idle.
        store.onStatus(status(sessionId, phase = "idle", turnActive = false))

        // Safety net must have cleared the streaming state.
        assertNull(
            "turnActive=false status must clear streamingMessage",
            store.streamingMessage.value[sessionId],
        )
        assertNull(
            "turnActive=false status must clear turnPhaseBySession",
            store.turnPhaseBySession.value[sessionId],
        )
    }
}
