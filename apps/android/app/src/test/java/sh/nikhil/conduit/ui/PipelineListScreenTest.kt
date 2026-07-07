package sh.nikhil.conduit.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [PipelineSummary] decode (incl. unknown-state tolerance) and
 * [PipelineListViewModel]'s pure sort/group helpers -- the only app-side
 * consumer of `GET /api/pipelines`. Mirror of iOS
 * `ConduitPipelineListViewModelTests`.
 */
class PipelineListScreenTest {

    private fun summary(
        id: String,
        title: String = "t",
        state: String,
        currentStep: Int = 0,
        stepCount: Int = 1,
        created: String? = null,
    ) = PipelineSummary(
        id = id, title = title, state = state,
        currentStep = currentStep, stepCount = stepCount, created = created,
    )

    private fun parseFromJson(o: JSONObject) = PipelineSummary(
        id = o.optString("id", ""),
        title = o.optString("title", ""),
        state = o.optString("state", ""),
        currentStep = o.optInt("current_step", 0),
        stepCount = o.optInt("step_count", 0),
        created = o.optString("created", "").takeIf { it.isNotEmpty() },
    )

    // ---- Decode ---------------------------------------------------------

    @Test
    fun decodesListResponseShape() {
        val json = JSONObject(
            """{"id":"p_1","title":"Fix bug","state":"running","current_step":1,"step_count":3,"created":"2026-07-01T00:00:00Z"}""",
        )
        val parsed = parseFromJson(json)
        assertEquals("p_1", parsed.id)
        assertEquals("Fix bug", parsed.title)
        assertEquals("running", parsed.state)
        assertEquals(1, parsed.currentStep)
        assertEquals(3, parsed.stepCount)
    }

    @Test
    fun toleratesUnknownState() {
        // A newer broker might introduce a state this build doesn't know
        // about yet. `state` is a raw String field, so this must not throw --
        // and the unknown state must fall into the ACTIVE sort bucket, not
        // vanish or crash.
        val json = JSONObject(
            """{"id":"p_2","title":"t","state":"some_future_state","current_step":0,"step_count":1}""",
        )
        val parsed = parseFromJson(json)
        assertEquals(PipelineListViewModel.Group.ACTIVE, PipelineListViewModel.group(parsed.state))
    }

    @Test
    fun toleratesMissingCreated() {
        val json = JSONObject(
            """{"id":"p_3","title":"t","state":"complete","current_step":0,"step_count":1}""",
        )
        val parsed = parseFromJson(json)
        assertNull(parsed.created)
    }

    // ---- Grouping ---------------------------------------------------------

    @Test
    fun groupsNeedsYouStates() {
        assertEquals(PipelineListViewModel.Group.NEEDS_YOU, PipelineListViewModel.group("awaiting_gate"))
        assertEquals(PipelineListViewModel.Group.NEEDS_YOU, PipelineListViewModel.group("awaiting_pick"))
    }

    @Test
    fun groupsTerminalStates() {
        assertEquals(PipelineListViewModel.Group.TERMINAL, PipelineListViewModel.group("complete"))
        assertEquals(PipelineListViewModel.Group.TERMINAL, PipelineListViewModel.group("failed"))
        assertEquals(PipelineListViewModel.Group.TERMINAL, PipelineListViewModel.group("cancelled"))
    }

    @Test
    fun groupsRunningAndPendingAsActive() {
        assertEquals(PipelineListViewModel.Group.ACTIVE, PipelineListViewModel.group("running"))
        assertEquals(PipelineListViewModel.Group.ACTIVE, PipelineListViewModel.group("pending"))
        assertEquals(PipelineListViewModel.Group.ACTIVE, PipelineListViewModel.group("step_done"))
    }

    // ---- Sort order ---------------------------------------------------------

    @Test
    fun sortsNeedsYouBeforeActiveBeforeTerminal() {
        val items = listOf(
            summary(id = "a", state = "complete", created = "2026-07-01T00:00:00Z"),
            summary(id = "b", state = "running"),
            summary(id = "c", state = "awaiting_gate"),
        )
        val sorted = PipelineListViewModel.sorted(items)
        assertEquals(listOf("c", "b", "a"), sorted.map { it.id })
    }

    @Test
    fun sortsTerminalPipelinesByRecencyDescending() {
        val items = listOf(
            summary(id = "old", state = "complete", created = "2026-01-01T00:00:00Z"),
            summary(id = "new", state = "complete", created = "2026-06-01T00:00:00Z"),
        )
        val sorted = PipelineListViewModel.sorted(items)
        assertEquals(listOf("new", "old"), sorted.map { it.id })
    }

    @Test
    fun preservesInputOrderWithinNonTerminalGroups() {
        val items = listOf(
            summary(id = "first", state = "running"),
            summary(id = "second", state = "running"),
        )
        val sorted = PipelineListViewModel.sorted(items)
        assertEquals(listOf("first", "second"), sorted.map { it.id })
    }

    // ---- Home affordance gate ---------------------------------------------

    @Test
    fun homeAffordanceGatesOnAllNonTerminalStates() {
        // A just-started flow (`pending`) and the brief inter-step window
        // (`step_done`) must qualify too -- device feedback: the FLOWS
        // section never appeared for a live flow because these two were
        // excluded.
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("pending"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("running"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("step_done"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("awaiting_gate"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("awaiting_pick"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("complete"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("failed"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("cancelled"))
    }

    // ---- Recent-terminal affordance gate (Home banner, bug 3) --------------

    @Test
    fun recentTerminalGatesOnCompleteOrFailedOnly() {
        val now = System.currentTimeMillis()
        val recent = java.time.Instant.ofEpochMilli(now - 60_000).toString()
        assertTrue(PipelineListViewModel.isRecentTerminal(summary(id = "a", state = "complete", created = recent), now))
        assertTrue(PipelineListViewModel.isRecentTerminal(summary(id = "b", state = "failed", created = recent), now))
        assertFalse(PipelineListViewModel.isRecentTerminal(summary(id = "c", state = "cancelled", created = recent), now))
        assertFalse(PipelineListViewModel.isRecentTerminal(summary(id = "d", state = "running", created = recent), now))
    }

    @Test
    fun recentTerminalExcludesOlderThan24h() {
        val now = System.currentTimeMillis()
        val justInside = java.time.Instant.ofEpochMilli(now - 23L * 3600 * 1000).toString()
        val justOutside = java.time.Instant.ofEpochMilli(now - 25L * 3600 * 1000).toString()
        assertTrue(PipelineListViewModel.isRecentTerminal(summary(id = "a", state = "complete", created = justInside), now))
        assertFalse(PipelineListViewModel.isRecentTerminal(summary(id = "b", state = "complete", created = justOutside), now))
    }

    @Test
    fun recentTerminalRequiresCreatedTimestamp() {
        val now = System.currentTimeMillis()
        assertFalse(PipelineListViewModel.isRecentTerminal(summary(id = "a", state = "complete", created = null), now))
    }
}
