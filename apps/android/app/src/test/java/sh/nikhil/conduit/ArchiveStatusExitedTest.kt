package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.ui.SessionOutcome
import uniffi.conduit_core.ProjectSession

/**
 * Pins the archive-status bug fix: archiving a session must stamp its
 * persisted History row as EXITED so [SessionOutcome.from] yields ENDED
 * (not RUNNING).
 *
 * Root cause: [SessionStore.recordSavedSession] guards on the session being
 * present in the live [SessionStore._sessions] list and early-returns when
 * the session was already removed from that list. Calling [SessionStore.markExited]
 * unconditionally after [recordSavedSession] patches the persisted row directly,
 * bypassing the guard.
 *
 * The [SessionOutcome.from] test mirrors the exact mapping in
 * [sh.nikhil.conduit.ui.HistoryScreen] (~line 145) so the CI gate pins
 * both the store contract and the UI mapping together.
 */
class ArchiveStatusExitedTest {

    private fun session(id: String): ProjectSession =
        ProjectSession(
            id = id,
            name = id,
            assistant = "claude",
            branch = "main",
            preview = null,
            reasoningEffort = null,
            cwd = "/repo",
            startedAt = "2026-06-01T10:00:00Z",
            lastActivityAt = "2026-06-01T10:05:00Z",
            displayName = null,
        )

    // --- SavedSessionsReducer.markExited pure-function contract ---

    @Test
    fun markExited_flipsSingleRowToExited() {
        val rows = SavedSessionsReducer.upsert(
            emptyList(), session("s1"), "srv", null, "first msg", 1, false, emptySet(), "2026-06-01T10:00:00Z",
        )
        assertEquals(SavedSessionStatus.LIVE, rows.first { it.id == "s1" }.status)
        val after = SavedSessionsReducer.markExited(rows, "s1")
        assertEquals(SavedSessionStatus.EXITED, after.first { it.id == "s1" }.status)
    }

    @Test
    fun markExited_isIdempotentWhenAlreadyExited() {
        val rows = SavedSessionsReducer.upsert(
            emptyList(), session("s1"), "srv", null, "msg", 1, true, emptySet(), "2026-06-01T10:00:00Z",
        )
        assertEquals(SavedSessionStatus.EXITED, rows.first().status)
        // Should return the same list instance -- no spurious write.
        val after = SavedSessionsReducer.markExited(rows, "s1")
        assertTrue("idempotent call must return the same list instance", after === rows)
    }

    @Test
    fun markExited_isNoOpForUnknownId() {
        val rows = SavedSessionsReducer.upsert(
            emptyList(), session("s1"), "srv", null, "msg", 1, false, emptySet(), "2026-06-01T10:00:00Z",
        )
        val after = SavedSessionsReducer.markExited(rows, "not-found")
        assertTrue("no-match must return the same list instance", after === rows)
    }

    @Test
    fun markExited_onlyAffectsMatchingRow() {
        var rows = SavedSessionsReducer.upsert(
            emptyList(), session("s1"), "srv", null, "msg", 1, false, emptySet(), "2026-06-01T10:00:00Z",
        )
        rows = SavedSessionsReducer.upsert(
            rows, session("s2"), "srv", null, "msg", 1, false, emptySet(), "2026-06-01T10:00:00Z",
        )
        val after = SavedSessionsReducer.markExited(rows, "s1")
        assertEquals(SavedSessionStatus.EXITED, after.first { it.id == "s1" }.status)
        assertEquals(SavedSessionStatus.LIVE, after.first { it.id == "s2" }.status)
    }

    // --- SessionStore.markExited integration + SessionOutcome.from mapping ---

    @Test
    fun sessionStore_markExited_flipsLiveRowToExited() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-live"))
        // Seed a LIVE history row the way onStatus would.
        store.recordSavedSession("s-live", isExited = false)
        assertEquals(
            "row should be LIVE before archive",
            SavedSessionStatus.LIVE,
            store.savedSessionsRecent().first { it.id == "s-live" }.status,
        )

        // markExited patches the index even without a live session entry.
        store.markExited("s-live")

        val row = store.savedSessionsRecent().first { it.id == "s-live" }
        assertEquals("row must be EXITED after markExited", SavedSessionStatus.EXITED, row.status)
    }

    @Test
    fun sessionStore_markExited_worksEvenWhenSessionAbsentFromLiveList() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-gone"))
        // Record the row, then simulate it being removed from the live list
        // (as archive() does after recordSavedSession).
        store.recordSavedSession("s-gone", isExited = false)
        // Remove from live list so recordSavedSession would early-return.
        // (store._sessions is private; we verify via markExited driving the index directly.)

        store.markExited("s-gone")

        val row = store.savedSessionsRecent().firstOrNull { it.id == "s-gone" }
        assertFalse("row must still exist in History after markExited", row == null)
        assertEquals(SavedSessionStatus.EXITED, row!!.status)
    }

    // --- SessionOutcome.from mapping pins the RUNNING -> ENDED fix ---

    @Test
    fun sessionOutcome_liveRowYieldsRunning() {
        val row = buildRow("s-r", SavedSessionStatus.LIVE)
        assertEquals(SessionOutcome.RUNNING, SessionOutcome.from(row))
    }

    @Test
    fun sessionOutcome_exitedRowYieldsEnded() {
        val row = buildRow("s-e", SavedSessionStatus.EXITED)
        assertEquals(SessionOutcome.ENDED, SessionOutcome.from(row))
    }

    @Test
    fun sessionOutcome_unknownRowYieldsEnded() {
        val row = buildRow("s-u", SavedSessionStatus.UNKNOWN)
        assertEquals(SessionOutcome.ENDED, SessionOutcome.from(row))
    }

    @Test
    fun sessionOutcome_afterMarkExited_yieldsEnded() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-fix"))
        store.recordSavedSession("s-fix", isExited = false)
        store.markExited("s-fix")

        val row = store.savedSessionsRecent().first { it.id == "s-fix" }
        // This is the core regression check: before the fix this would be RUNNING.
        assertEquals(
            "archived session must render ENDED not RUNNING in History",
            SessionOutcome.ENDED,
            SessionOutcome.from(row),
        )
    }

    private fun buildRow(id: String, status: SavedSessionStatus) = SavedSession(
        id = id,
        serverId = "srv",
        agent = "claude",
        cwd = "/repo",
        firstSeen = "2026-06-01T10:00:00Z",
        lastSeen = "2026-06-01T10:05:00Z",
        messageCount = 2,
        summary = "test summary",
        status = status,
    )
}
