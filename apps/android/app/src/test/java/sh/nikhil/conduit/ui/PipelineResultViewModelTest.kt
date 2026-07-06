package sh.nikhil.conduit.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [Pipeline.result] / [PipelineStep.output] decode (tolerant of
 * absence on an old broker) and [PipelineResultViewModel]'s pure
 * collapse-threshold logic -- the Monitor's Result card (#906/#907).
 * Mirror of iOS `ConduitPipelineResultViewModelTests`.
 */
class PipelineResultViewModelTest {

    // ---- Decode -------------------------------------------------------------

    @Test
    fun decodesCompleteResponseWithResult() {
        val json = JSONObject(
            """
            {"id":"p_1","title":"t","task":"t","cwd":"/","base":"main",
             "state":"complete","current_step":1,
             "steps":[{"index":0,"agent_type":"claude","role":"worker",
                       "prompt_template":"","input_from_prev":"none","gate_after":false,
                       "output":"did the thing"}],
             "result":{"output":"final output","finished":"2026-07-01T00:00:00Z",
                        "files_changed":3,"insertions":10,"deletions":2,
                        "branches":["pipeline-p_1-step-0"]}}
            """.trimIndent(),
        )
        val parsed = parsePipeline(json)
        assertTrue(parsed.isComplete)
        assertEquals("final output", parsed.result?.output)
        assertEquals(3, parsed.result?.filesChanged)
        assertEquals(10, parsed.result?.insertions)
        assertEquals(2, parsed.result?.deletions)
        assertEquals(listOf("pipeline-p_1-step-0"), parsed.result?.branches)
        assertEquals("did the thing", parsed.steps[0].output)
    }

    @Test
    fun toleratesMissingResultOnOldBroker() {
        // An older broker (or a pipeline that completed before #906
        // shipped) has state == "complete" but no result field at all.
        val json = JSONObject(
            """{"id":"p_2","title":"t","task":"t","cwd":"/","base":"main","state":"complete","current_step":1,"steps":[]}""",
        )
        val parsed = parsePipeline(json)
        assertTrue(parsed.isComplete)
        assertNull(parsed.result)
    }

    @Test
    fun toleratesMissingStepOutput() {
        val json = JSONObject(
            """
            {"id":"p_3","title":"t","task":"t","cwd":"/","base":"main",
             "state":"running","current_step":0,
             "steps":[{"index":0,"agent_type":"claude","role":"worker",
                       "prompt_template":"","input_from_prev":"none","gate_after":false}]}
            """.trimIndent(),
        )
        val parsed = parsePipeline(json)
        assertNull(parsed.steps[0].output)
    }

    // ---- Collapse threshold ---------------------------------------------

    @Test
    fun shortOutputNeedsNoCollapse() {
        val text = (0 until 5).joinToString("\n") { "line $it" }
        assertFalse(PipelineResultViewModel.needsCollapse(text))
        assertEquals(text, PipelineResultViewModel.collapsed(text))
    }

    @Test
    fun longOutputNeedsCollapse() {
        val lines = (0 until 40).map { "line $it" }
        val text = lines.joinToString("\n")
        assertTrue(PipelineResultViewModel.needsCollapse(text))
        assertEquals(lines.take(12).joinToString("\n"), PipelineResultViewModel.collapsed(text))
    }

    @Test
    fun exactlyAtThresholdDoesNotCollapse() {
        val lines = (0 until 12).map { "line $it" }
        val text = lines.joinToString("\n")
        assertFalse(PipelineResultViewModel.needsCollapse(text))
    }

    @Test
    fun oneOverThresholdCollapses() {
        val lines = (0 until 13).map { "line $it" }
        val text = lines.joinToString("\n")
        assertTrue(PipelineResultViewModel.needsCollapse(text))
        assertEquals(lines.take(12).joinToString("\n"), PipelineResultViewModel.collapsed(text))
    }
}
