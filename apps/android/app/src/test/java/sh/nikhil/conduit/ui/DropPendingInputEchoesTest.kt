package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Android mirror of the dedup tests added to iOS
 * `ConduitPendingInputTests` for the resolved-card collapse fix.
 *
 * Root cause: the broker re-publishes an answered AskUserQuestion card
 * with an extra `[[conduit:resolved]]{...}` marker line.  The old dedup
 * keyed on raw trimmed content, so the original and resolved cards had
 * DIFFERENT keys and both survived -- the user saw the question twice and
 * the raw marker text could render as visible chat prose.
 *
 * Fix: key on stripped content ([PendingQuestions.strippedKey]); among
 * duplicates the resolved-marker card wins.
 */
class DropPendingInputEchoesTest {

    private fun item(
        kind: String,
        content: String,
        pendingOptions: List<String> = emptyList(),
        role: String = "assistant",
    ): ConversationItem = ConversationItem(
        id = "${kind}-${content.hashCode()}",
        role = role,
        kind = kind,
        status = "done",
        content = content,
        ts = "2026-06-05T10:00:00Z",
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

    private val sentinel = "[[conduit:needs-input]]"
    private val resolvedMarker = "[[conduit:resolved]]"

    private val originalContent = "$sentinel\nProceed with the merge?\n1. Merge now\n2. Hold off"
    private val resolvedContent =
        "$sentinel\n${resolvedMarker}{\"answered\":true,\"answer\":\"Merge now\"}\n" +
            "Proceed with the merge?\n1. Merge now\n2. Hold off"

    /** Returns true when the content carries a resolution marker line. */
    private fun hasResolutionMarker(content: String): Boolean =
        content.split("\n").any { it.trim().startsWith(resolvedMarker) }

    // --- Core dedup: original + resolved collapse to ONE answered card --------

    @Test fun collapseOriginalAndResolvedToAnsweredCard_resolvedFirst() {
        val resolved = item("pending_input", resolvedContent)
        val original = item("pending_input", originalContent)
        val result = dropPendingInputEchoes(listOf(resolved, original))
        assertEquals("must collapse to exactly 1 card", 1, result.size)
        assertTrue(
            "surviving card must carry the resolution marker",
            hasResolutionMarker(result[0].content),
        )
    }

    @Test fun collapseOriginalAndResolvedToAnsweredCard_originalFirst() {
        val original = item("pending_input", originalContent)
        val resolved = item("pending_input", resolvedContent)
        val result = dropPendingInputEchoes(listOf(original, resolved))
        assertEquals("must collapse to exactly 1 card", 1, result.size)
        assertTrue(
            "surviving card must carry the resolution marker even when original came first",
            hasResolutionMarker(result[0].content),
        )
    }

    // --- Distinct questions are never merged ---------------------------------

    @Test fun distinctQuestionsAreNotMerged() {
        val q1 = item("pending_input", "$sentinel\nMerge?\n1. Yes\n2. No")
        val q2Resolved = item(
            "pending_input",
            "$sentinel\n${resolvedMarker}{\"answered\":true,\"answer\":\"Yes\"}\n" +
                "Deploy?\n1. Yes\n2. No",
        )
        val result = dropPendingInputEchoes(listOf(q1, q2Resolved))
        assertEquals(2, result.size)
    }

    // --- Echo drop still works against a resolved card -----------------------

    @Test fun echoDropWorksAgainstResolvedCard() {
        val resolved = item("pending_input", resolvedContent)
        val echo = item("message", "Proceed with the merge?")
        val result = dropPendingInputEchoes(listOf(echo, resolved))
        assertEquals(1, result.size)
        assertEquals("pending_input", result[0].kind)
    }

    // --- Backward compat: lone unanswered card is kept as-is ----------------

    @Test fun singleUnansweredCardIsKept() {
        val original = item("pending_input", originalContent)
        val result = dropPendingInputEchoes(listOf(original))
        assertEquals(1, result.size)
        assertEquals(originalContent, result[0].content)
    }

    // --- Multi-question newline-joined echo is dropped -----------------------

    @Test fun multiQuestionAnswerEchoIsDropped() {
        // Two-question AskUserQuestion; the app joins answers with "\n".
        val card = item(
            "pending_input",
            "$sentinel\nStartup behavior?\n1. Default-on for everyone\n2. Opt-in\n\n" +
                "Parallelism?\n1. Both, in parallel\n2. Sequential",
            pendingOptions = listOf("Default-on for everyone", "Opt-in", "Both, in parallel", "Sequential"),
        )
        val echo = item("message", "Default-on for everyone\nBoth, in parallel", role = "user")
        val result = dropPendingInputEchoes(listOf(card, echo))
        assertEquals("multi-question echo must be dropped", 1, result.size)
        assertEquals("pending_input", result[0].kind)
    }

    // --- strippedKey is symmetric for original and resolved ------------------

    @Test fun strippedKeyIsIdenticalForOriginalAndResolved() {
        val k1 = PendingQuestions.strippedKey(originalContent)
        val k2 = PendingQuestions.strippedKey(resolvedContent)
        assertEquals("stripped keys must match so dedup can collapse them", k1, k2)
        assertTrue("stripped key must not contain sentinel", !k1.contains(sentinel))
        assertTrue("stripped key must not contain resolved marker", !k1.contains(resolvedMarker))
    }

    // --- PendingQuestions.parse strips the resolved marker from prose --------

    @Test fun parseStripsResolvedMarkerFromQuestionText() {
        val qs = PendingQuestions.parse(resolvedContent)
        assertEquals(1, qs.size)
        assertEquals("Proceed with the merge?", qs[0].prompt)
        assertEquals(listOf("Merge now", "Hold off"), qs[0].options)
    }
}
