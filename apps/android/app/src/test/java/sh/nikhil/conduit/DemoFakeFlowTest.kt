package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.ui.PipelineStepDraft

/**
 * Pins [SessionStore.demoStartFlow] -- the Flow wizard's demo-mode "Start
 * flow" fake-flow builder (no network, extends the demo home's FLOWS list).
 * Mirror of iOS `DemoFakeFlowTests`.
 */
class DemoFakeFlowTest {

    private fun steps(): List<PipelineStepDraft> = listOf(
        PipelineStepDraft(agentType = "claude", role = "researcher", promptTemplate = "p1", inputFromPrev = "none", gateAfter = false),
        PipelineStepDraft(agentType = "codex", role = "engineer", promptTemplate = "p2", inputFromPrev = "output", gateAfter = false),
    )

    @Test
    fun firstFakeFlowGetsIndexOneId() {
        val store = SessionStore()
        val (id, status) = store.demoStartFlow(title = "Test flow", task = "do the thing", cwd = "", steps = steps())
        assertEquals("demo-fake-1", id)
        assertEquals("demo-fake-1", status.id)
    }

    @Test
    fun fakeFlowIsRunningWithFirstStepRunning() {
        val store = SessionStore()
        val (_, status) = store.demoStartFlow(title = "Test flow", task = "do the thing", cwd = "", steps = steps())
        assertEquals("running", status.state)
        assertEquals(2, status.steps.size)
        assertEquals("running", status.steps[0].phase)
        assertNotNull(status.steps[0].sessionId)
        assertNull(status.steps[1].phase)
        assertNull(status.steps[1].sessionId)
    }

    @Test
    fun fakeFlowIsPrependedToDemoExtraPipelines() {
        val store = SessionStore()
        store.demoStartFlow(title = "Test flow", task = "do the thing", cwd = "", steps = steps())
        assertEquals("demo-fake-1", store.demoExtraPipelines.value.first().id)
        assertEquals(1, store.demoExtraPipelines.value.size)
    }

    @Test
    fun demoPipelineStatusFallsBackToStaticFixtures() {
        val store = SessionStore()
        assertEquals("Add rate limiter to broker", store.demoPipelineStatus("demo-flow-1")?.title)
        assertNull(store.demoPipelineStatus("not-a-real-flow"))
    }

    @Test
    fun demoPipelineStatusResolvesTheFakeFlow() {
        val store = SessionStore()
        val (id, _) = store.demoStartFlow(title = "Test flow", task = "do the thing", cwd = "", steps = steps())
        assertEquals("do the thing", store.demoPipelineStatus(id)?.task)
    }

    @Test
    fun branchStepsAreExcludedFromTheFakeFlow() {
        val store = SessionStore()
        val branch = PipelineStepDraft(kind = "branch")
        val (_, status) = store.demoStartFlow(title = "Test flow", task = "t", cwd = "", steps = steps() + branch)
        assertEquals(2, status.steps.size)
    }

    @Test
    fun deactivateDemoClearsFakeFlows() {
        val store = SessionStore()
        store.demoStartFlow(title = "Test flow", task = "do the thing", cwd = "", steps = steps())
        assertTrue(store.demoExtraPipelines.value.isNotEmpty())
        store.deactivateDemo()
        assertTrue(store.demoExtraPipelines.value.isEmpty())
    }
}
