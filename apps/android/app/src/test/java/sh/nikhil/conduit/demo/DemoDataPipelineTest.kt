package sh.nikhil.conduit.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the demo-mode Flow fixtures ([DemoData.pipelines] /
 * [DemoData.pipelineStatus]) added alongside the demo home FLOWS section +
 * PipelineMonitorScreen's static-fixture seam. Catches drift in the literal
 * titles/states the Appetize tour taps by text, and the shape the real
 * `FlowCard` / `PipelineMonitorScreen` expect. Mirror of iOS
 * `DemoDataPipelineTests`.
 */
class DemoDataPipelineTest {

    @Test
    fun seedsTwoDemoFlows() {
        assertEquals(2, DemoData.pipelines.size)
    }

    @Test
    fun gatedFlowFixtureMatchesTourTapTarget() {
        // The Appetize tour taps this exact title text -- a drift here
        // silently breaks the tour, not CI, so pin it directly.
        val flow = DemoData.pipelines.first { it.id == "demo-flow-1" }
        assertEquals("Add rate limiter to broker", flow.title)
        assertEquals("awaiting_gate", flow.state)
    }

    @Test
    fun gatedFlowFixtureHasAGateAfterStep() {
        val flow = DemoData.pipelines.first { it.id == "demo-flow-1" }
        assertTrue(flow.steps.orEmpty().any { it.gateAfter })
    }

    @Test
    fun runningFlowFixtureMatchesExpectedShape() {
        val flow = DemoData.pipelines.first { it.id == "demo-flow-2" }
        assertEquals("Migrate settings to KV store", flow.title)
        assertEquals("running", flow.state)
        assertEquals(listOf("done", "running", "queued"), flow.steps.orEmpty().map { it.status })
    }

    @Test
    fun monitorFixtureExistsForEverySummary() {
        DemoData.pipelines.forEach { summary ->
            val status = DemoData.pipelineStatus(summary.id)
            assertNotNull(status)
            assertEquals(summary.id, status?.id)
            assertEquals(summary.title, status?.title)
            assertEquals(summary.state, status?.state)
        }
    }

    @Test
    fun gatedMonitorFixtureCarriesAGatePayload() {
        val status = DemoData.pipelineStatus("demo-flow-1")
        assertNotNull(status?.gate)
        assertTrue(status?.gate?.prev?.contains("Proposed design") == true)
    }

    @Test
    fun unknownIdReturnsNull() {
        assertNull(DemoData.pipelineStatus("not-a-real-flow"))
    }
}
