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
    fun homeAffordanceGatesOnExactlyThreeActiveStates() {
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("running"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("awaiting_gate"))
        assertTrue(PipelineListViewModel.isActiveForHomeAffordance("awaiting_pick"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("pending"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("complete"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("failed"))
        assertFalse(PipelineListViewModel.isActiveForHomeAffordance("cancelled"))
    }
}
