package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Pins the Home "needs you" banner derivation (design handoff §B.10). The
 * banner appears ONLY on a real signal — a session whose LAST transcript item
 * is an unanswered non-user `pending_input` — and never fabricates a count.
 * Mirror of iOS `ConduitHomeViewModelTests` needs-you coverage.
 */
class NeedsYouBannerTest {

    private fun item(
        role: String,
        kind: String,
        content: String = "",
        ts: String = "2026-06-05T18:00:00Z",
    ): ConversationItem = ConversationItem(
        id = "$ts-$role-$kind",
        role = role,
        kind = kind,
        status = "done",
        content = content,
        ts = ts,
        files = emptyList(),
        toolName = null,
        command = null,
        exitCode = null,
        durationMs = null,
        diffSummary = null,
        pendingOptions = emptyList(),
        sourceAgent = null,
        targetAgent = null,
        taskText = null,
        resultSummary = null,
        planSteps = emptyList(),
    )

    @Test
    fun awaitingInputOnlyForUnansweredPendingInput() {
        assertTrue(isAwaitingInput(listOf(item("assistant", "pending_input"))))
        // A user reply after the prompt clears it (last item is the user's).
        assertFalse(
            isAwaitingInput(
                listOf(item("assistant", "pending_input"), item("user", "message")),
            ),
        )
        // A normal assistant message is not a block.
        assertFalse(isAwaitingInput(listOf(item("assistant", "message"))))
        // No transcript at all -> not waiting.
        assertFalse(isAwaitingInput(null))
        assertFalse(isAwaitingInput(emptyList()))
    }

    // Bug A: pending_input followed by trailing assistant items should still be pending.
    @Test
    fun awaitingInputTrueWhenTrailingAssistantItemsAfterPendingInput() {
        // The old check looked at the LAST item; a trailing assistant message
        // would mask the pending_input. Fixed by scanning for the last
        // non-user pending_input item specifically.
        assertTrue(
            isAwaitingInput(
                listOf(
                    item("assistant", "pending_input"),
                    item("assistant", "message", content = "Thinking..."),
                ),
            ),
        )
    }

    // Bug B1: a resolved pending_input (broker marker in content) must not show in banner.
    @Test
    fun awaitingInputFalseWhenPendingInputIsResolved() {
        val resolvedContent = "[[conduit:needs-input]]\n[[conduit:resolved]]{\"answered\":true,\"answer\":\"Yes\"}\nApprove?"
        assertFalse(
            isAwaitingInput(
                listOf(item("assistant", "pending_input", content = resolvedContent)),
            ),
        )
    }

    // Bug A+B1: resolved pending_input with trailing chatter must not show in banner.
    @Test
    fun awaitingInputFalseWhenResolvedPendingInputFollowedByChatter() {
        val resolvedContent = "[[conduit:needs-input]]\n[[conduit:resolved]]{\"answered\":true,\"answer\":\"Yes\"}\nApprove?"
        assertFalse(
            isAwaitingInput(
                listOf(
                    item("assistant", "pending_input", content = resolvedContent),
                    item("assistant", "message", content = "Done!"),
                ),
            ),
        )
    }

    @Test
    fun bannerHiddenWhenNoSessionWaiting() {
        val banner = needsYouBanner(
            listOf(
                NeedsYouItem("a", "Fix auth", "claude") to listOf(item("assistant", "message")),
            ),
        )
        assertTrue(banner.isEmpty)
        assertEquals(0, banner.count)
        assertNull(banner.primaryId)
    }

    @Test
    fun bannerCollectsWaitingSessionsInOrder() {
        val banner = needsYouBanner(
            listOf(
                NeedsYouItem("a", "Fix auth", "claude") to listOf(item("assistant", "pending_input")),
                NeedsYouItem("b", "Idle one", "codex") to listOf(item("assistant", "message")),
                NeedsYouItem("c", "Approve push", "codex") to listOf(item("assistant", "pending_input")),
            ),
        )
        assertEquals(2, banner.count)
        assertEquals("a", banner.primaryId)
        assertEquals(listOf("a", "c"), banner.sessions.map { it.id })
    }
}
