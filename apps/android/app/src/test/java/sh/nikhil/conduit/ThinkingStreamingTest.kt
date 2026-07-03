package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import sh.nikhil.conduit.ui.thinkingPeekLine
import uniffi.conduit_core.ChatEvent
import uniffi.conduit_core.SessionStatus

/**
 * Unit tests for the thinking_streaming view_event pipeline and the
 * thinkingPeekLine helper.
 *
 * Coverage:
 *   1. ingestThinkingStreaming sets thinkingBySession.
 *   2. thinkingBySession clears on final reply (shouldClearStreaming path).
 *   3. thinkingBySession clears on turnActive=false status frame.
 *   4. Old replay does NOT clear thinkingBySession (mirrors Bug-B guards).
 *   5. thinkingPeekLine: last non-empty line, trimmed, capped at 80 chars.
 *
 * Mirror of iOS ThinkingStreamingTests.swift.
 */
class ThinkingStreamingTest {

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

    // ── ingestThinkingStreaming ──────────────────────────────────────────────

    @Test
    fun ingestSetsThinkingBySession() {
        val store = SessionStore()
        val sessionId = "thinking-set-${java.util.UUID.randomUUID()}"

        store.ingestThinkingStreaming(sessionId, mapOf("content" to "First reasoning line."))

        assertEquals(
            "ingestThinkingStreaming must store content in thinkingBySession",
            "First reasoning line.",
            store.thinkingBySession.value[sessionId],
        )
    }

    @Test
    fun ingestUpdatesAccumulatedText() {
        val store = SessionStore()
        val sessionId = "thinking-update-${java.util.UUID.randomUUID()}"

        store.ingestThinkingStreaming(sessionId, mapOf("content" to "Part one."))
        store.ingestThinkingStreaming(sessionId, mapOf("content" to "Part one.\nPart two."))

        assertEquals(
            "second ingest should overwrite with the accumulated text",
            "Part one.\nPart two.",
            store.thinkingBySession.value[sessionId],
        )
    }

    @Test
    fun ingestIgnoresMissingContent() {
        val store = SessionStore()
        val sessionId = "thinking-no-content-${java.util.UUID.randomUUID()}"

        store.ingestThinkingStreaming(sessionId, emptyMap())

        assertNull(
            "missing content key must be a no-op",
            store.thinkingBySession.value[sessionId],
        )
    }

    // ── Clear on final reply ─────────────────────────────────────────────────

    @Test
    fun clearOnFinalReply() {
        val store = SessionStore()
        val sessionId = "thinking-clear-reply-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:00:01.000Z"

        store.ingestChatStreaming(sessionId, mapOf("content" to "Streaming prose...", "turn_ts" to turnTs))
        store.ingestThinkingStreaming(sessionId, mapOf("content" to "Some deep thoughts."))

        // Final assistant message with matching ts triggers shouldClearStreaming.
        store.onChatEvent(
            sessionId,
            ChatEvent(role = "assistant", content = "Done.", ts = turnTs, files = emptyList()),
        )

        assertNull(
            "final reply must clear thinkingBySession alongside streamingMessage",
            store.thinkingBySession.value[sessionId],
        )
    }

    @Test
    fun oldReplayDoesNotClearThinkingBySession() {
        val store = SessionStore()
        val sessionId = "thinking-no-clear-replay-${java.util.UUID.randomUUID()}"
        val turnTs = "2026-07-01T12:00:01.000Z"

        store.ingestChatStreaming(sessionId, mapOf("content" to "In-flight prose...", "turn_ts" to turnTs))
        store.ingestThinkingStreaming(sessionId, mapOf("content" to "Current reasoning."))

        // An older replayed event (ts < turnTs) must NOT clear the thinking state.
        store.onChatEvent(
            sessionId,
            ChatEvent(
                role = "assistant",
                content = "Old settled message.",
                ts = "2026-07-01T12:00:00.000Z",
                files = emptyList(),
            ),
        )

        assertEquals(
            "old replay must not clear in-flight thinkingBySession",
            "Current reasoning.",
            store.thinkingBySession.value[sessionId],
        )
    }

    // ── Clear on turnActive=false ─────────────────────────────────────────────

    @Test
    fun clearOnTurnActiveFalse() {
        val store = SessionStore()
        val sessionId = "thinking-clear-status-${java.util.UUID.randomUUID()}"

        store.ingestChatStreaming(
            sessionId,
            mapOf("content" to "Streaming...", "turn_ts" to "2026-07-01T12:00:01.000Z"),
        )
        store.ingestThinkingStreaming(sessionId, mapOf("content" to "Mid-flight thought."))

        // Prime the turn as active first.
        store.onStatus(status(sessionId, "running", turnActive = true))

        // Turn goes idle.
        store.onStatus(status(sessionId, "idle", turnActive = false))

        assertNull(
            "turnActive=false status must clear thinkingBySession",
            store.thinkingBySession.value[sessionId],
        )
    }
}

/**
 * Unit tests for the thinkingPeekLine helper function.
 * Mirror of iOS ThinkingPeekLineTests.
 */
class ThinkingPeekLineTest {

    @Test
    fun nullInputReturnsNull() {
        assertNull(thinkingPeekLine(null))
    }

    @Test
    fun emptyInputReturnsNull() {
        assertNull(thinkingPeekLine(""))
    }

    @Test
    fun whitespaceOnlyReturnsNull() {
        assertNull(thinkingPeekLine("   \n  \n  "))
    }

    @Test
    fun singleLineReturnsTrimmed() {
        assertEquals("Hello world", thinkingPeekLine("  Hello world  "))
    }

    @Test
    fun multiLineReturnsLastNonEmpty() {
        val text = "First line.\nSecond line.\nThird line."
        assertEquals("Third line.", thinkingPeekLine(text))
    }

    @Test
    fun trailingBlankLinesSkipped() {
        val text = "First line.\nSecond line.\n\n   \n"
        assertEquals("Second line.", thinkingPeekLine(text))
    }

    @Test
    fun shortLineUnchanged() {
        val line = "x".repeat(80)
        assertEquals(line, thinkingPeekLine(line))
    }

    @Test
    fun longLineCappedAt80() {
        val long = "a".repeat(100)
        val result = thinkingPeekLine(long)
        assertEquals("result must be 79 chars + ellipsis = 80 chars total", 80, result?.length)
        assertEquals(
            "capped line must end with an ellipsis",
            true,
            result?.endsWith("…"),
        )
    }

    @Test
    fun exactly79CharsUnchanged() {
        val line = "b".repeat(79)
        assertEquals(line, thinkingPeekLine(line))
    }
}
