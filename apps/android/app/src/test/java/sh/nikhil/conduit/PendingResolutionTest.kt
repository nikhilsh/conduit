package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.ui.PendingQuestions

/**
 * Pins the [[conduit:resolved]] marker decoding and display-stripping
 * (iOS PR #721 Android parity).
 *
 * The broker writes `[[conduit:resolved]]{"answered":true,"answer":"<opt>"}` into a
 * persisted pending-input item's content right after the `[[conduit:needs-input]]`
 * sentinel. Android must:
 *  (1) Decode the resolution so `parsePendingResolution` returns answered=true +
 *      the chosen answer text.
 *  (2) Strip the marker line from the visible question text via `parse`.
 *  (3) A missing marker must yield null (backward-compatible unanswered state).
 */
class PendingResolutionTest {

    private val sentinel = PendingQuestions.PENDING_INPUT_SENTINEL
    private val resolvedMarker = PendingQuestions.PENDING_RESOLVED_MARKER

    // --- parsePendingResolution ---

    @Test
    fun `resolved marker with answer decodes correctly`() {
        val content = "$sentinel\n${resolvedMarker}{\"answered\":true,\"answer\":\"Option A\"}\nProceed?\n1. Option A\n2. Option B"
        val res = PendingQuestions.parsePendingResolution(content)
        assertTrue("answered should be true", res?.answered == true)
        assertEquals("Option A", res?.answer)
    }

    @Test
    fun `resolved marker answered false returns answered=false`() {
        val content = "$sentinel\n${resolvedMarker}{\"answered\":false}\nProceed?\n1. Yes\n2. No"
        val res = PendingQuestions.parsePendingResolution(content)
        assertFalse("answered should be false", res?.answered == true)
        assertNull("no answer expected", res?.answer)
    }

    @Test
    fun `no resolved marker returns null (backward compatible)`() {
        val content = "$sentinel\nDo you want to proceed?\n1. Yes\n2. No"
        val res = PendingQuestions.parsePendingResolution(content)
        assertNull("should return null when no marker present", res)
    }

    @Test
    fun `resolved marker with empty answer treats answer as null`() {
        val content = "${resolvedMarker}{\"answered\":true,\"answer\":\"\"}\nQuestion?"
        val res = PendingQuestions.parsePendingResolution(content)
        assertTrue(res?.answered == true)
        assertNull("empty string answer should be null", res?.answer)
    }

    @Test
    fun `resolved marker without json suffix returns null`() {
        val content = "${resolvedMarker}invalid-json\nQuestion?"
        val res = PendingQuestions.parsePendingResolution(content)
        assertNull("malformed JSON must return null, not throw", res)
    }

    // --- parse (display text stripping) ---

    @Test
    fun `parse strips resolved marker from question text`() {
        val content = "$sentinel\n${resolvedMarker}{\"answered\":true,\"answer\":\"Merge now\"}\nProceed with the merge?\n1. Merge now\n2. Hold off"
        val qs = PendingQuestions.parse(content)
        assertEquals(1, qs.size)
        assertEquals("Proceed with the merge?", qs[0].prompt)
        assertFalse("resolved marker must not appear in prompt", qs[0].prompt.contains(resolvedMarker))
        assertEquals(listOf("Merge now", "Hold off"), qs[0].options)
    }

    @Test
    fun `parse strips both sentinel and resolved marker`() {
        val content = "$sentinel\n${resolvedMarker}{\"answered\":true,\"answer\":\"Yes\"}\nDo it?\n1. Yes\n2. No"
        val qs = PendingQuestions.parse(content)
        assertEquals(1, qs.size)
        val allText = qs[0].prompt + qs[0].options.joinToString()
        assertFalse("sentinel must not appear in output", allText.contains(sentinel))
        assertFalse("resolved marker must not appear in output", allText.contains(resolvedMarker))
    }

    @Test
    fun `parse with no resolved marker is unchanged (backward compatible)`() {
        val content = "$sentinel\nAllow this command?\n1. Allow\n2. Deny"
        val qs = PendingQuestions.parse(content)
        assertEquals(1, qs.size)
        assertEquals("Allow this command?", qs[0].prompt)
        assertEquals(listOf("Allow", "Deny"), qs[0].options)
    }
}
