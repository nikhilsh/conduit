package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md §3.4): the
 * visual Builder's `PipelineBuilderViewModel` must be a pure reshape of the
 * Phase-1 form -- same steps in, same `/api/pipeline` create-request JSON
 * out -- and drag-reorder must reindex the list (steps carry no
 * client-side index; the broker assigns the index from array position at
 * create time, so "reindexing" IS reordering the list). Mirrors iOS
 * `ConduitPipelineBuilderViewModelTests`.
 */
class PipelineBuilderViewModelTest {

    @Test
    fun createRequestJsonMatchesPhase1FormEncoding() {
        val stepA = PipelineStepDraft(agentType = "claude", role = "engineer", model = "opus", reasoningEffort = "high")
        val stepB = PipelineStepDraft(agentType = "codex", role = "researcher", gateAfter = true)

        // The "Phase-1 form" shape: build the request body directly from
        // stepDraftToJson, exactly as PipelineBuilderScreen did before Phase 2.
        val legacySteps = listOf(stepA, stepB)
        val legacyJson = org.json.JSONObject().apply {
            put("title", "Title")
            put("task", "Task")
            put("cwd", "/tmp")
            put("base", "main")
            put("steps", org.json.JSONArray().apply { legacySteps.forEach { put(stepDraftToJson(it)) } })
        }

        val vm = PipelineBuilderViewModel(legacySteps)
        val vmJson = vm.createRequestJson("Title", "Task", "/tmp", "main")

        assertEquals(legacyJson.toString(), vmJson.toString())
    }

    @Test
    fun templateSaveRequestJsonMatchesPhase1FormEncoding() {
        val step = PipelineStepDraft(agentType = "gemini", instructions = "Be terse.")
        val legacyJson = org.json.JSONObject().apply {
            put("title", "T")
            put("task", "Do it")
            put("steps", org.json.JSONArray().apply { put(stepDraftToJson(step)) })
        }
        val vm = PipelineBuilderViewModel(listOf(step))
        val vmJson = vm.templateSaveRequestJson("T", "Do it")
        assertEquals(legacyJson.toString(), vmJson.toString())
    }

    @Test
    fun moveStepReordersList() {
        val a = PipelineStepDraft(agentType = "claude")
        val b = PipelineStepDraft(agentType = "codex")
        val c = PipelineStepDraft(agentType = "gemini")
        val vm = PipelineBuilderViewModel(listOf(a, b, c))

        // Move the first step ("claude") to the end.
        vm.moveStep(0, 2)

        assertEquals(listOf("codex", "gemini", "claude"), vm.steps.map { it.agentType })
    }

    @Test
    fun moveStepReindexesCreateRequestOrder() {
        val a = PipelineStepDraft(agentType = "claude")
        val b = PipelineStepDraft(agentType = "codex")
        val c = PipelineStepDraft(agentType = "gemini")
        val vm = PipelineBuilderViewModel(listOf(a, b, c))

        vm.moveStep(2, 0)

        val json = vm.createRequestJson("T", "task", "", "main")
        val steps = json.getJSONArray("steps")
        // The broker assigns the index from ARRAY POSITION at create time
        // (ws/pipeline.go serveCreatePipeline) -- so the reordered list
        // order IS the reindexed 0..n-1 order sent over the wire.
        assertEquals("gemini", steps.getJSONObject(0).getString("agent_type"))
        assertEquals("claude", steps.getJSONObject(1).getString("agent_type"))
        assertEquals("codex", steps.getJSONObject(2).getString("agent_type"))
    }

    @Test
    fun addAndRemoveStepKeepsAtLeastOne() {
        val vm = PipelineBuilderViewModel()
        assertEquals(1, vm.steps.size)
        vm.removeStep(vm.steps[0].id)
        assertEquals("must never remove the last step", 1, vm.steps.size)

        vm.addStep()
        assertEquals(2, vm.steps.size)
        val firstId = vm.steps[0].id
        vm.removeStep(firstId)
        assertEquals(1, vm.steps.size)
        assertNotEquals(firstId, vm.steps.first().id)
    }

    @Test
    fun applyTemplateReplacesSteps() {
        val vm = PipelineBuilderViewModel()
        val tmpl = PipelineTemplateDraft(
            id = "t1",
            title = "Refactor",
            task = "Refactor auth",
            steps = listOf(
                PipelineStepDraft(
                    agentType = "codex",
                    role = "architect",
                    gateAfter = true,
                    model = "gpt-5-codex",
                    reasoningEffort = "high",
                    permissionMode = "plan",
                    instructions = "focus on the API",
                ),
            ),
        )
        vm.applyTemplate(tmpl)
        assertEquals(1, vm.steps.size)
        assertEquals("codex", vm.steps[0].agentType)
        assertEquals("gpt-5-codex", vm.steps[0].model)
        assertEquals("focus on the API", vm.steps[0].instructions)
        assertTrue(vm.selectedStepId == vm.steps[0].id)
    }
}
