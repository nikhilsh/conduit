package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
 * (tsEpochMillis <= 0).
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
        val pending = makeItem("pi-1", "pending_input", "", content = "Approve?",
            pendingOptions = listOf("Yes", "No"))
        // Seed conversationLog directly via the public API seam used in other tests.
        // sendChat with a null client writes to _conversationLog; here we use
        // ingestConversation (the HTTP replay path) to seed items.
        // Since we cannot call ingestConversation directly in the unit-test
        // classpath without a broker, we exercise resolvePendingInput by
        // planting items through the same internal path the live app does --
        // via appendAuditedApprovalLine ... but that requires a real session.
        // Instead, call sendChat to get a conversationLog entry, then manipulate
        // state via the public resolvePendingInput surface. We only need to
        // confirm the backfill path: seed a pending_input with empty ts and
        // a prior item with a real ts, then call resolvePendingInput and assert
        // the ts changed.
        //
        // The only seam available in unit-test classpath (no live client) is
        // sendChat which always writes to _conversationLog. We therefore
        // send two messages to seed two items, then overwrite their content
        // via the mutable var fields to simulate the pending_input scenario.
        store.sendChat(sessionId, "Starting task")
        store.sendChat(sessionId, "Approve?")

        val items = store.conversationLog.value[sessionId].orEmpty()
        // Overwrite the second item's kind to pending_input and clear its ts.
        items[0].ts = "2026-06-01T10:00:00Z"
        items[0].kind = "message"
        items[1].kind = "pending_input"
        items[1].ts = ""
        items[1].role = "assistant"
        // Force the updated list into the StateFlow via sendChat's side-effect
        // doesn't work; the items list is the same reference held by the state.
        // Since ConversationItem has var fields, the mutation is already reflected.

        store.resolvePendingInput(sessionId)

        val updated = store.conversationLog.value[sessionId].orEmpty()
        val chip = updated.firstOrNull { it.kind == "pending_input" }
        assertNotNull("pending_input card must still be present", chip)
        assertTrue("backfilled ts must be non-empty", chip!!.ts.isNotEmpty())
        assertTrue(
            "backfilled ts must be parseable (tsEpochMillis > 0)",
            tsEpochMillis(chip.ts) > 0L,
        )
    }

    // --- real ts is not overwritten -----------------------------------------

    @Test
    fun resolvePendingInputDoesNotOverwriteRealTs() {
        val store = SessionStore()
        val sessionId = "test-no-overwrite-${java.util.UUID.randomUUID()}"
        val realTs = "2026-06-01T09:00:00Z"

        store.sendChat(sessionId, "Approve?")
        val items = store.conversationLog.value[sessionId].orEmpty()
        items[0].kind = "pending_input"
        items[0].ts = realTs
        items[0].role = "assistant"

        store.resolvePendingInput(sessionId)

        val updated = store.conversationLog.value[sessionId].orEmpty()
        val chip = updated.firstOrNull { it.kind == "pending_input" }
        assertEquals("real broker ts must not be overwritten", realTs, chip?.ts)
    }

    // --- sort order invariant ------------------------------------------------

    @Test
    fun answeredChipSortsBeforeLaterAssistantMessage() {
        val store = SessionStore()
        val sessionId = "test-sort-${java.util.UUID.randomUUID()}"

        // Seed two items: a regular message and a pending_input with empty ts.
        store.sendChat(sessionId, "Working...")
        store.sendChat(sessionId, "Approve?")
        val items = store.conversationLog.value[sessionId].orEmpty()
        items[0].ts = "2026-06-01T10:00:00Z"
        items[0].kind = "message"
        items[1].kind = "pending_input"
        items[1].ts = ""
        items[1].role = "assistant"

        store.resolvePendingInput(sessionId)

        // A later assistant reply arrives after the answer.
        val laterReply = makeItem("srv-later", "message", "2026-06-01T10:00:02Z",
            content = "Done!")
        val all = store.conversationLog.value[sessionId].orEmpty() + laterReply
        val sorted = all.sortedByConversationTs { it.ts }

        val chipIdx = sorted.indexOfFirst { it.kind == "pending_input" }
        val laterIdx = sorted.indexOfFirst { it.id == "srv-later" }
        assertTrue(
            "answered chip (index $chipIdx) must sort before later assistant reply (index $laterIdx)",
            chipIdx < laterIdx,
        )
    }

    // --- sortedByConversationTs treats empty ts as Long.MAX_VALUE (pre-fix invariant) --------

    @Test
    fun emptyTsSortsLastInSortedByConversationTs() {
        // Confirm the sort contract: an empty ts sorts as Long.MAX_VALUE (last).
        // This is WHY the backfill is necessary.
        val emptyTsItem = makeItem("empty", "message", "")
        val realTsItem = makeItem("real", "message", "2026-06-01T10:00:00Z")
        val sorted = listOf(emptyTsItem, realTsItem).sortedByConversationTs { it.ts }
        assertEquals("real-ts item must sort first", "real", sorted[0].id)
        assertEquals("empty-ts item must sort last", "empty", sorted[1].id)
    }
}
