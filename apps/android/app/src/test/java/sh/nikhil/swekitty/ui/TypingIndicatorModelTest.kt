package sh.nikhil.swekitty.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-data tests for the "agent is typing…" indicator (Bug 3 / iOS
 * `isStreaming` parity). Pins the grow → show, quiet → hide, user-turn →
 * hide contract entirely client-side so the indicator is never stuck on.
 */
class TypingIndicatorModelTest {

    @Test fun freshModelIsNotStreaming() {
        assertFalse(TypingIndicatorModel().isStreaming(nowMs = 1_000))
    }

    @Test fun userTurnDoesNotStream() {
        val m = TypingIndicatorModel().onTrailingTurn("user", 42, nowMs = 100)
        assertFalse(m.isStreaming(nowMs = 100))
    }

    @Test fun growingAssistantTurnStreams() {
        val m = TypingIndicatorModel().onTrailingTurn("assistant", 10, nowMs = 100)
        assertTrue(m.isStreaming(nowMs = 100))
    }

    @Test fun continuedGrowthKeepsStreaming() {
        var m = TypingIndicatorModel().onTrailingTurn("assistant", 10, nowMs = 100)
        m = m.onTrailingTurn("assistant", 25, nowMs = 300)
        assertTrue(m.isStreaming(nowMs = 300))
    }

    @Test fun goingQuietPastWindowHides() {
        val m = TypingIndicatorModel().onTrailingTurn("assistant", 50, nowMs = 100)
        // Window default is 700ms; 100 + 800 = 900 is past it.
        assertFalse(m.isStreaming(nowMs = 900))
    }

    @Test fun withinQuietWindowStillStreams() {
        val m = TypingIndicatorModel().onTrailingTurn("assistant", 50, nowMs = 100)
        assertTrue(m.isStreaming(nowMs = 100 + 500))
    }

    @Test fun newUserTurnAfterStreamingDisarms() {
        var m = TypingIndicatorModel().onTrailingTurn("assistant", 50, nowMs = 100)
        assertTrue(m.isStreaming(nowMs = 100))
        // User sends a new message — the trailing turn is now the user.
        m = m.onTrailingTurn("user", 5, nowMs = 200)
        assertFalse(m.isStreaming(nowMs = 200))
    }

    @Test fun toolTurnAlsoStreams() {
        val m = TypingIndicatorModel().onTrailingTurn("tool", 10, nowMs = 100)
        assertTrue(m.isStreaming(nowMs = 100))
    }

    @Test fun nullRoleDisarms() {
        val m = TypingIndicatorModel().onTrailingTurn(null, 0, nowMs = 100)
        assertFalse(m.isStreaming(nowMs = 100))
    }

    @Test fun assistantTurnThatStoppedGrowingButReEvaluatedStaysWithinWindow() {
        // Last grew at 100; re-eval at 100 (no growth) keeps the stamp,
        // so within-window it still streams.
        var m = TypingIndicatorModel().onTrailingTurn("assistant", 50, nowMs = 100)
        m = m.onTrailingTurn("assistant", 50, nowMs = 100) // same length, no growth
        assertTrue(m.isStreaming(nowMs = 100))
    }
}
