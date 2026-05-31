package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ProjectSession

/**
 * `android-multi-thread` — ThreadSwitcherSheet view model. Same
 * pattern as iOS `ThreadSwitcherTests` from PR #42: assert against the
 * pure-data [ThreadSwitcherModel] rather than hosting the composable,
 * so the shape of the sheet (same-server list, empty-state CTA,
 * multi-thread peek strip) is locked in without a Compose host.
 */
class ThreadSwitcherModelTest {

    // ---------- same-server filtering ----------

    @Test
    fun sameServerListExcludesActiveSession() {
        // The sheet's "other sessions on this server" list must skip
        // the session the user is currently inside — otherwise the
        // user can "switch" to the thread they're already on, which
        // is a confusing no-op.
        val active = makeSession(id = "active", assistant = "claude")
        val other1 = makeSession(id = "peer-a", assistant = "claude")
        val other2 = makeSession(id = "peer-b", assistant = "codex")

        val model = ThreadSwitcherModel.from(
            allSessions = listOf(active, other1, other2),
            activeSessionID = "active",
            currentServerID = "srv-1",
        )

        val ids = model.sameServerSessions.map { it.id }
        assertEquals(listOf("peer-a", "peer-b"), ids)
        assertFalse(ids.contains("active"))
    }

    @Test
    fun sameServerListOnlyContainsServerScopedSessions() {
        // The store only ever holds sessions for the currently
        // connected endpoint, so "filter by current server" collapses
        // to "all sessions in the store except the active one." This
        // test pins that behaviour so a future refactor that wires a
        // wire-side `serverID` doesn't accidentally drop sessions.
        val active = makeSession(id = "active", assistant = "claude")
        val peers = (0 until 3).map { makeSession(id = "peer-$it", assistant = "claude") }
        val model = ThreadSwitcherModel.from(
            allSessions = listOf(active) + peers,
            activeSessionID = "active",
            currentServerID = "srv-1",
        )
        assertEquals(3, model.sameServerSessions.size)
        for (s in peers) {
            assertTrue(model.sameServerSessions.any { it.id == s.id })
        }
    }

    // ---------- empty-state CTA ----------

    @Test
    fun emptyStateWhenOnlyOneSessionExists() {
        // Lone active session → no other threads to switch to → sheet
        // must surface the empty-state CTA so the user has a way
        // forward instead of staring at a blank list.
        val only = makeSession(id = "only", assistant = "claude")
        val model = ThreadSwitcherModel.from(
            allSessions = listOf(only),
            activeSessionID = "only",
            currentServerID = "srv-1",
        )
        assertTrue(model.sameServerSessions.isEmpty())
        assertTrue(model.sameServerIsEmpty)
        // All-sessions strip still has the active one — the peek
        // strip is "across all servers" and intentionally shows the
        // current thread so the user has a visual anchor.
        assertEquals(1, model.allSessions.size)
    }

    @Test
    fun nonEmptyStateHidesEmptyCTA() {
        val active = makeSession(id = "a", assistant = "claude")
        val peer = makeSession(id = "b", assistant = "codex")
        val model = ThreadSwitcherModel.from(
            allSessions = listOf(active, peer),
            activeSessionID = "a",
            currentServerID = "srv-1",
        )
        assertFalse(model.sameServerIsEmpty)
        assertEquals(1, model.sameServerSessions.size)
    }

    // ---------- multi-thread peek pill strip ----------

    @Test
    fun peekStripIncludesEverySessionAcrossServers() {
        // The pill strip is the "multi-thread peek" affordance — it
        // shows ALL sessions the client knows about, including the
        // active one (highlighted) so the user has a visual anchor.
        // On Android today that's same-server only because the store
        // never holds remote-server sessions, but the test asserts
        // the model contract so a future wire-side serverID lands
        // cleanly.
        val s1 = makeSession(id = "s-1", assistant = "claude")
        val s2 = makeSession(id = "s-2", assistant = "codex")
        val s3 = makeSession(id = "s-3", assistant = "claude")
        val model = ThreadSwitcherModel.from(
            allSessions = listOf(s1, s2, s3),
            activeSessionID = "s-1",
            currentServerID = "srv-1",
        )
        assertEquals(listOf("s-1", "s-2", "s-3"), model.allSessions.map { it.id })
        // Active session is INCLUDED in the peek strip even though
        // it's excluded from the same-server list below.
        assertTrue(model.allSessions.any { it.id == model.activeSessionID })
    }

    @Test
    fun peekStripPreservesWireOrder() {
        // Render order of the pill strip mirrors the wire order so a
        // refactor that sorts the list (by name / by activity) is
        // explicit, not accidental.
        val names = listOf("zeta", "alpha", "mu", "beta")
        val sessions = names.map { makeSession(id = it, assistant = "claude") }
        val model = ThreadSwitcherModel.from(
            allSessions = sessions,
            activeSessionID = "alpha",
            currentServerID = "srv-1",
        )
        assertEquals(names, model.allSessions.map { it.id })
    }

    // ---------- switch-target id ----------

    @Test
    fun switchTargetIdIsTheRowsSessionId() {
        // The model itself is the only contract between the row tap
        // and `store.switchTo(sessionID)`; the composable just hands
        // the row's session through. Pin the identity so a refactor
        // that, say, decorates rows with `displayName` can't accidentally
        // hand a renamed key to the store.
        val active = makeSession(id = "active", assistant = "claude")
        val peer = makeSession(id = "peer-xyz", assistant = "codex")
        val model = ThreadSwitcherModel.from(
            allSessions = listOf(active, peer),
            activeSessionID = "active",
            currentServerID = "srv-1",
        )
        val target = model.sameServerSessions.single()
        assertEquals("peer-xyz", target.id)
    }

    // ---------- helpers ----------

    private fun makeSession(id: String, assistant: String): ProjectSession =
        ProjectSession(
            id = id,
            name = id,
            assistant = assistant,
            branch = "main",
            preview = null,
            reasoningEffort = null,
            cwd = null,
            startedAt = null,
            lastActivityAt = null,
            displayName = null,
        )
}
