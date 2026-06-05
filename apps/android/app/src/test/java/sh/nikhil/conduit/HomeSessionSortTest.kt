package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Pins the Home active-session ordering + last-message timestamp source.
 * Rows must sort most-recent-activity first, STABLY (equal/missing
 * timestamps keep input order), and the row's timestamp must come from the
 * real last conversation-log item — not the reconnect-set status timestamp
 * that made every cold-boot row read "just now". Mirror of iOS
 * `ConduitHomeViewModelTests` sort coverage.
 */
class HomeSessionSortTest {

    private fun item(ts: String, role: String = "assistant"): ConversationItem =
        ConversationItem(
            id = "$ts-$role",
            role = role,
            kind = "message",
            status = "done",
            content = "",
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
    fun lastMessageTimestampIsTheFreshestLogItem() {
        val ts = lastMessageTimestampOf(
            listOf(
                item("2026-05-25T11:00:00Z", "user"),
                item("2026-05-25T11:58:00Z", "assistant"),
            ),
        )
        assertEquals("2026-05-25T11:58:00Z", ts)
    }

    @Test
    fun lastMessageTimestampNullWhenLogEmptyOrNull() {
        assertNull(lastMessageTimestampOf(null))
        assertNull(lastMessageTimestampOf(emptyList()))
    }

    @Test
    fun sortsMostRecentActivityFirst() {
        val rows = listOf("older" to "2026-05-25T11:00:00Z", "newer" to "2026-05-25T11:58:00Z")
        val sorted = sortSessionsByActivity(rows) { it.second }
        assertEquals(listOf("newer", "older"), sorted.map { it.first })
    }

    @Test
    fun sortIsStableForEqualOrMissingTimestamps() {
        // Dated rows (equal → input order) sort before undated rows (also
        // input order). The existing nil-timestamp behavior must be
        // preserved.
        val rows = listOf(
            "a" to null,
            "b" to null,
            "c" to "2026-05-25T11:00:00Z",
            "d" to "2026-05-25T11:00:00Z",
        )
        val sorted = sortSessionsByActivity(rows) { it.second }
        assertEquals(listOf("c", "d", "a", "b"), sorted.map { it.first })
    }
}
