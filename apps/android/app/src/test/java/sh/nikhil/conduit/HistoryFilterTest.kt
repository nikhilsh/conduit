package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.ui.HistoryFilter
import sh.nikhil.conduit.ui.SessionOutcome

/**
 * Pure-logic tests for the History redesign (handoff §A.3) filter chips +
 * outcome derivation. Android mirror of the iOS
 * `SessionsScreenModelTests` filter/outcome cases — both platforms must
 * stay in lockstep on which real field drives each chip.
 */
class HistoryFilterTest {

    private fun row(
        id: String = "s",
        agent: String = "claude",
        status: SavedSessionStatus = SavedSessionStatus.UNKNOWN,
    ): SavedSession = SavedSession(
        id = id,
        serverId = "srv",
        agent = agent,
        cwd = null,
        firstSeen = "2026-05-25T09:00:00Z",
        lastSeen = "2026-05-25T09:00:00Z",
        messageCount = 0,
        summary = "",
        status = status,
    )

    @Test
    fun allFilterAdmitsEverything() {
        assertTrue(HistoryFilter.ALL.matches(row(status = SavedSessionStatus.EXITED)))
        assertTrue(HistoryFilter.ALL.matches(row(agent = "codex")))
    }

    @Test
    fun runningFilterKeepsOnlyLiveRows() {
        assertTrue(HistoryFilter.RUNNING.matches(row(status = SavedSessionStatus.LIVE)))
        assertFalse(HistoryFilter.RUNNING.matches(row(status = SavedSessionStatus.EXITED)))
        assertFalse(HistoryFilter.RUNNING.matches(row(status = SavedSessionStatus.UNKNOWN)))
    }

    @Test
    fun agentFiltersMatchCaseInsensitively() {
        assertTrue(HistoryFilter.CLAUDE.matches(row(agent = "Claude")))
        assertFalse(HistoryFilter.CLAUDE.matches(row(agent = "codex")))
        assertTrue(HistoryFilter.CODEX.matches(row(agent = "CODEX")))
        assertFalse(HistoryFilter.CODEX.matches(row(agent = "claude")))
    }

    @Test
    fun outcomeFromPersistedStatus() {
        assertEquals(SessionOutcome.RUNNING, SessionOutcome.from(row(status = SavedSessionStatus.LIVE)))
        assertEquals(SessionOutcome.ENDED, SessionOutcome.from(row(status = SavedSessionStatus.EXITED)))
        // Unknown degrades to the honest neutral, never a fabricated merged.
        assertEquals(SessionOutcome.ENDED, SessionOutcome.from(row(status = SavedSessionStatus.UNKNOWN)))
    }
}
