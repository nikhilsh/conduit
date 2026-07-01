package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Android mirror of the iOS `SessionStoreTests` pending_input ts-backfill
 * suite (answered-chip ordering fix).
 *
 * Root cause: a live pending_input card is created with an empty `ts`.
 * After the user answers, [SessionStore.resolvePendingInput] marked the card
 * resolved but left `ts` empty. The sort ([sortedByConversationTs]) treats an
 * empty/unparseable `ts` as [Long.MAX_VALUE] (newest), so the collapsed chip
 * floated to the BOTTOM of the transcript, below assistant messages that
 * arrived AFTER the answer.
 *
 * Fix: [SessionStore.resolvePendingInput] now backfills `ts` to one ms past
 * the max known epoch when the card's ts is empty or unparseable
 * (tsEpochMillis <= 0). State is seeded via [SessionStore.seedConversationLogForTest]
 * — the deterministic Android equivalent of iOS assigning `conversationLog`
 * directly (sendChat is unsafe here: no dispatcher/client and the turn-gate
 * can queue rather than append).
 */
class PendingInputTsBackfillTest {

    private fun makeItem(
        id: String,
        kind: String,
        ts: String,
        role: String = "assistant",
        content: String = "",
        pendingOptions: List<String> = emptyList(),
    ): ConversationItem = ConversationItem(
        id = id,
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
        pendingOptions = pendingOptions,
        sourceAgent = null,
        targetAgent = null,
        taskText = null,
        resultSummary = null,
        planSteps = emptyList(),
    )

    // --- resolvePendingInput backfills an empty ts ---------------------------

    @Test
    fun resolvePendingInputBackfillsEmptyTs() {
        val store = SessionStore()
        val sessionId = "test-backfill-${java.util.UUID.randomUUID()}"
        val prior = makeItem("srv-prior", "message", "2026-06-01T10:00:00Z", content = "Working...")
        val pending = makeItem(
            "pi-1", "pending_input", "", content = "Approve?",
            pendingOptions = listOf("Yes", "No"),
        )
        store.seedConversationLogForTest(sessionId, listOf(prior, pending))

        store.resolvePendingInput(sessionId)

        val chip = store.conversationLog.value[sessionId].orEmpty()
            .firstOrNull { it.kind == "pending_input" }
        assertNotNull("pending_input card must still be present", chip)
        assertTrue("backfilled ts must be non-empty", chip!!.ts.isNotEmpty())
        assertTrue(
            "backfilled ts must be parseable (tsEpochMillis > 0)",
            tsEpochMillis(chip.ts) > 0L,
        )
        // Anchored one ms past the prior item, so it stays after prior content.
        assertTrue(
            "backfilled ts must sort at/after the prior real-ts item",
            tsEpochMillis(chip.ts) >= tsEpochMillis("2026-06-01T10:00:00Z"),
        )
    }

    // --- real ts is not overwritten -----------------------------------------

    @Test
    fun resolvePendingInputDoesNotOverwriteRealTs() {
        val store = SessionStore()
        val sessionId = "test-no-overwrite-${java.util.UUID.randomUUID()}"
        val realTs = "2026-06-01T09:00:00Z"
        val pending = makeItem("pi-1", "pending_input", realTs, content = "Approve?")
        store.seedConversationLogForTest(sessionId, listOf(pending))

        store.resolvePendingInput(sessionId)

        val chip = store.conversationLog.value[sessionId].orEmpty()
            .firstOrNull { it.kind == "pending_input" }
        assertEquals("real broker ts must not be overwritten", realTs, chip?.ts)
    }

    // --- sort order invariant ------------------------------------------------

    @Test
    fun answeredChipSortsBeforeLaterAssistantMessage() {
        val store = SessionStore()
        val sessionId = "test-sort-${java.util.UUID.randomUUID()}"
        val prior = makeItem("srv-prior", "message", "2026-06-01T10:00:00Z", content = "Working...")
        val pending = makeItem("pi-1", "pending_input", "", content = "Approve?")
        store.seedConversationLogForTest(sessionId, listOf(prior, pending))

        store.resolvePendingInput(sessionId)

        // A later assistant reply arrives AFTER the answer.
        val laterReply = makeItem("srv-later", "message", "2026-06-01T10:00:02Z", content = "Done!")
        val all = store.conversationLog.value[sessionId].orEmpty() + laterReply
        val sorted = all.sortedByConversationTs { it.ts }

        val chipIdx = sorted.indexOfFirst { it.kind == "pending_input" }
        val laterIdx = sorted.indexOfFirst { it.id == "srv-later" }
        assertTrue(
            "answered chip (index $chipIdx) must sort before later assistant reply (index $laterIdx)",
            chipIdx < laterIdx,
        )
    }

    // --- sortedByConversationTs treats empty ts as newest (why the fix is needed) ---

    @Test
    fun emptyTsSortsLastInSortedByConversationTs() {
        val emptyTsItem = makeItem("empty", "message", "")
        val realTsItem = makeItem("real", "message", "2026-06-01T10:00:00Z")
        val sorted = listOf(emptyTsItem, realTsItem).sortedByConversationTs { it.ts }
        assertEquals("real-ts item must sort first", "real", sorted[0].id)
        assertEquals("empty-ts item must sort last", "empty", sorted[1].id)
    }
}
