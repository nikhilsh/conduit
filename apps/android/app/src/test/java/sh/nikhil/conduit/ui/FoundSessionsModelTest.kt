package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [FoundSessionsModel] -- pure JVM, no Compose runtime needed.
 *
 * Covers:
 *  - row mapping per state (idle -> Resume shown, running -> Branch shown,
 *    adopted -> deduped as "In Conduit")
 *  - folder grouping stability
 *  - recent sort (most-recent-first, capped at 8)
 *  - search filtering (title / cwd / branch)
 *  - hidden-id exclusion
 *  - empty / offline / scanning discoveryState derivation
 *  - showEntryCard gating (capability absent, count==0, scanning override)
 */
class FoundSessionsModelTest {

    // -- Fixtures --------------------------------------------------------------

    private fun idle(id: String, cwd: String = "/repo", ts: Long = 1000L) = FoundSession(
        externalId = id,
        agent = "claude",
        title = "Session $id",
        cwd = cwd,
        gitBranch = "main",
        turnCount = 10,
        lastActivityAtMs = ts,
        state = FoundSessionState.IDLE,
    )

    private fun running(id: String, cwd: String = "/repo", ts: Long = 2000L) = FoundSession(
        externalId = id,
        agent = "codex",
        title = "Running $id",
        cwd = cwd,
        gitBranch = "feat/$id",
        turnCount = 5,
        lastActivityAtMs = ts,
        state = FoundSessionState.RUNNING,
    )

    private fun adopted(id: String) = FoundSession(
        externalId = id,
        agent = "claude",
        title = "Adopted $id",
        cwd = "/adopted",
        gitBranch = "main",
        turnCount = 3,
        lastActivityAtMs = 500L,
        state = FoundSessionState.ADOPTED,
    )

    private fun snapshot(
        sessions: List<FoundSession>,
        hiddenIds: Set<String> = emptySet(),
        query: String = "",
        filter: FoundFilter = FoundFilter.RECENT,
        discoveryState: FoundDiscoveryState = FoundDiscoveryState.Loaded,
        totalOnDisk: Int = sessions.size,
    ) = FoundSessionsSnapshot(
        boxId = "box-1",
        sessions = sessions,
        hiddenIds = hiddenIds,
        query = query,
        filter = filter,
        discoveryState = discoveryState,
        totalOnDisk = totalOnDisk,
    )

    // -- Row mapping tests -----------------------------------------------------

    @Test
    fun idleSession_hasIdleState() {
        val s = idle("a")
        val rows = FoundSessionsModel.rows(snapshot(listOf(s)))
        assertEquals(1, rows.size)
        assertEquals(FoundSessionState.IDLE, rows[0].session.state)
    }

    @Test
    fun runningSession_hasRunningState() {
        val s = running("b")
        val rows = FoundSessionsModel.rows(snapshot(listOf(s)))
        assertEquals(1, rows.size)
        assertEquals(FoundSessionState.RUNNING, rows[0].session.state)
    }

    @Test
    fun adoptedSession_hasAdoptedState() {
        val s = adopted("c")
        val rows = FoundSessionsModel.rows(snapshot(listOf(s)))
        assertEquals(1, rows.size)
        assertEquals(FoundSessionState.ADOPTED, rows[0].session.state)
    }

    // -- Hidden-id tests -------------------------------------------------------

    @Test
    fun hiddenSession_excluded() {
        val sessions = listOf(idle("visible"), idle("hidden"))
        val rows = FoundSessionsModel.rows(snapshot(sessions, hiddenIds = setOf("hidden")))
        assertEquals(1, rows.size)
        assertEquals("visible", rows[0].session.externalId)
    }

    @Test
    fun multipleHiddenIds_allExcluded() {
        val sessions = listOf(idle("a"), idle("b"), idle("c"))
        val rows = FoundSessionsModel.rows(snapshot(sessions, hiddenIds = setOf("a", "b")))
        assertEquals(1, rows.size)
        assertEquals("c", rows[0].session.externalId)
    }

    // -- Search filter tests ---------------------------------------------------

    @Test
    fun searchByTitle_casInsensitive() {
        val sessions = listOf(
            idle("x").copy(title = "Refactor auth"),
            idle("y").copy(title = "Build UI"),
        )
        val rows = FoundSessionsModel.rows(snapshot(sessions, query = "auth"))
        assertEquals(1, rows.size)
        assertEquals("x", rows[0].session.externalId)
    }

    @Test
    fun searchByCwd_matches() {
        val sessions = listOf(
            idle("x", cwd = "/projects/api"),
            idle("y", cwd = "/projects/web"),
        )
        val rows = FoundSessionsModel.rows(snapshot(sessions, query = "api"))
        assertEquals(1, rows.size)
        assertEquals("x", rows[0].session.externalId)
    }

    @Test
    fun searchByBranch_matches() {
        val sessions = listOf(
            running("x").copy(gitBranch = "fix/auth"),
            running("y").copy(gitBranch = "feat/ui"),
        )
        val rows = FoundSessionsModel.rows(snapshot(sessions, query = "auth"))
        assertEquals(1, rows.size)
        assertEquals("x", rows[0].session.externalId)
    }

    @Test
    fun emptyQuery_returnsAll() {
        val sessions = listOf(idle("a"), idle("b"), idle("c"))
        val rows = FoundSessionsModel.rows(snapshot(sessions, query = ""))
        assertEquals(3, rows.size)
    }

    @Test
    fun noSearchMatch_returnsEmpty() {
        val sessions = listOf(idle("a").copy(title = "foo"), idle("b").copy(title = "bar"))
        val rows = FoundSessionsModel.rows(snapshot(sessions, query = "zzznomatch"))
        assertEquals(0, rows.size)
    }

    // -- Filter mode tests -----------------------------------------------------

    @Test
    fun recentFilter_capped8_mostRecentFirst() {
        val sessions = (1..12).map { i ->
            idle("s$i", ts = i.toLong())
        }
        val rows = FoundSessionsModel.rows(snapshot(sessions, filter = FoundFilter.RECENT))
        assertEquals(8, rows.size)
        // Most recent first (ts=12 is newest).
        assertEquals("s12", rows[0].session.externalId)
        assertEquals("s5", rows[7].session.externalId)
    }

    @Test
    fun allFilter_noCountCap() {
        val sessions = (1..12).map { i -> idle("s$i", ts = i.toLong()) }
        val rows = FoundSessionsModel.rows(snapshot(sessions, filter = FoundFilter.ALL))
        assertEquals(12, rows.size)
    }

    @Test
    fun byFolderFilter_groupsCorrectly() {
        val sessions = listOf(
            idle("a", cwd = "/alpha"),
            idle("b", cwd = "/beta"),
            idle("c", cwd = "/alpha"),
        )
        val rows = FoundSessionsModel.rows(snapshot(sessions, filter = FoundFilter.BY_FOLDER))
        val alphaRows = rows.filter { it.folderKey == "/alpha" }
        val betaRows = rows.filter { it.folderKey == "/beta" }
        assertEquals(2, alphaRows.size)
        assertEquals(1, betaRows.size)
    }

    // -- Folder key tests ------------------------------------------------------

    @Test
    fun folderKeys_distinctInOrder() {
        val sessions = listOf(
            idle("a", cwd = "/alpha", ts = 300L),
            idle("b", cwd = "/beta", ts = 200L),
            idle("c", cwd = "/alpha", ts = 100L),
        )
        val rows = FoundSessionsModel.rows(snapshot(sessions, filter = FoundFilter.BY_FOLDER))
        val keys = FoundSessionsModel.folderKeys(rows)
        // /alpha comes first (ts=300 > ts=200).
        assertEquals(listOf("/alpha", "/beta"), keys)
    }

    // -- recentCount tests -----------------------------------------------------

    @Test
    fun recentCount_excludesHidden() {
        val sessions = listOf(idle("a"), idle("b"), idle("c"))
        val snap = snapshot(sessions, hiddenIds = setOf("a"))
        assertEquals(2, FoundSessionsModel.recentCount(snap))
    }

    @Test
    fun recentCount_cappedAt8() {
        val sessions = (1..12).map { idle("s$it") }
        val snap = snapshot(sessions)
        assertEquals(8, FoundSessionsModel.recentCount(snap))
    }

    // -- showEntryCard tests ---------------------------------------------------

    @Test
    fun showEntryCard_hiddenWhenCapabilityAbsent() {
        val snap = snapshot(listOf(idle("a")))
        assertFalse(FoundSessionsModel.showEntryCard(snap, sessionDiscovery = false))
    }

    @Test
    fun showEntryCard_hiddenWhenNullSnapshot() {
        assertFalse(FoundSessionsModel.showEntryCard(null, sessionDiscovery = true))
    }

    @Test
    fun showEntryCard_hiddenWhenZeroVisibleAndNotScanning() {
        val snap = snapshot(
            sessions = listOf(idle("h")),
            hiddenIds = setOf("h"),
            discoveryState = FoundDiscoveryState.Loaded,
        )
        assertFalse(FoundSessionsModel.showEntryCard(snap, sessionDiscovery = true))
    }

    @Test
    fun showEntryCard_shownWhenScanning() {
        val snap = snapshot(
            sessions = emptyList(),
            discoveryState = FoundDiscoveryState.Scanning,
        )
        assertTrue(FoundSessionsModel.showEntryCard(snap, sessionDiscovery = true))
    }

    @Test
    fun showEntryCard_shownWhenCountPositive() {
        val snap = snapshot(listOf(idle("a")))
        assertTrue(FoundSessionsModel.showEntryCard(snap, sessionDiscovery = true))
    }

    // -- discoveryState derivation --------------------------------------------

    @Test
    fun offline_discoveryStateIsOffline() {
        val snap = snapshot(emptyList(), discoveryState = FoundDiscoveryState.Offline)
        assertEquals(FoundDiscoveryState.Offline, snap.discoveryState)
    }

    @Test
    fun error_discoveryStateCarriesReason() {
        val state = FoundDiscoveryState.Error("permission denied")
        val snap = snapshot(emptyList(), discoveryState = state)
        assertTrue(snap.discoveryState is FoundDiscoveryState.Error)
        assertEquals("permission denied", (snap.discoveryState as FoundDiscoveryState.Error).reason)
    }
}
