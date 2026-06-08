package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/ConduitUI/
 * ConduitPendingInputTests.swift` (the parsePendingQuestions half). Pins
 * per-question grouping recovered from the broker's flattened pending-input
 * body, the multi-select marker → flag, and the sentinel strip — so the
 * Android AskUserQuestion card groups/checkboxes identically to iOS.
 */
class PendingQuestionsTest {

    @Test fun parsesSingleQuestion() {
        val qs = PendingQuestions.parse("Proceed with the merge?\n1. Merge now\n2. Hold off")
        assertEquals(1, qs.size)
        assertEquals("Proceed with the merge?", qs[0].prompt)
        assertEquals(listOf("Merge now", "Hold off"), qs[0].options)
        assertFalse(qs[0].multiSelect)
    }

    @Test fun parsesTwoQuestionsAsSeparateGroups() {
        // Broker shape: blocks separated by a blank line, renumbered per block.
        val qs = PendingQuestions.parse("Color?\n1. Red\n2. Blue\n\nSize?\n1. S\n2. M")
        assertEquals(2, qs.size)
        assertEquals(PendingQuestion("Color?", listOf("Red", "Blue")), qs[0])
        assertEquals(PendingQuestion("Size?", listOf("S", "M")), qs[1])
    }

    @Test fun parsesQuestionWithoutOptions() {
        val qs = PendingQuestions.parse("Anything else?")
        assertEquals(1, qs.size)
        assertEquals("Anything else?", qs[0].prompt)
        assertTrue(qs[0].options.isEmpty())
    }

    @Test fun parsesBulletedOptions() {
        val qs = PendingQuestions.parse("Pick one\n- Alpha\n* Beta")
        assertEquals(1, qs.size)
        assertEquals(listOf("Alpha", "Beta"), qs[0].options)
    }

    @Test fun stripsMultiSelectMarkerIntoFlag() {
        val qs = PendingQuestions.parse(
            "Pick colors (select all that apply)\n1. Red\n2. Green\n\nPick one\n1. A\n2. B",
        )
        assertEquals(2, qs.size)
        assertTrue(qs[0].multiSelect)
        assertEquals("Pick colors", qs[0].prompt)
        assertEquals(listOf("Red", "Green"), qs[0].options)
        assertFalse(qs[1].multiSelect)
        assertEquals("Pick one", qs[1].prompt)
    }

    @Test fun plainQuestionHasNoMultiFlag() {
        val qs = PendingQuestions.parse("Proceed?\n1. Yes\n2. No")
        assertEquals(1, qs.size)
        assertFalse(qs[0].multiSelect)
    }

    @Test fun stripsBrokerSentinelLine() {
        // The deterministic sentinel must never reach the user; the parser
        // drops it and parses the real question/options beneath.
        val qs = PendingQuestions.parse("[[conduit:needs-input]]\nProceed?\n1. Yes\n2. No")
        assertEquals(1, qs.size)
        assertEquals("Proceed?", qs[0].prompt)
        assertEquals(listOf("Yes", "No"), qs[0].options)
    }

    @Test fun parenInOptionMarkerForm() {
        // `1)` is a valid option marker too (mirror of iOS optionText).
        val qs = PendingQuestions.parse("Choose\n1) First\n2) Second")
        assertEquals(listOf("First", "Second"), qs[0].options)
    }
}
