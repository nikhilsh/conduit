package sh.nikhil.conduit.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.parseAgentDescriptors

/**
 * Pins the PLAN-HARNESS-BUILDER Phase 1 wire encoding/decoding for the
 * pipeline Builder: `stepDraftToJson` must emit the four per-block config
 * fields (+ fanout parallel arrays) only when non-empty, and
 * `parsePipelineTemplate` must tolerate their absence (old broker / template
 * saved before this shipped). Mirrors iOS `ConduitPipelineBuilderView`
 * request-encoder expectations.
 */
class PipelineBuilderScreenTest {

    // ---- stepDraftToJson: per-block config -----------------------------

    @Test
    fun stepDraftToJsonOmitsConfigFieldsWhenEmpty() {
        val step = PipelineStepDraft(agentType = "claude", role = "engineer")
        val json = stepDraftToJson(step)
        assertFalse(json.has("model"))
        assertFalse(json.has("reasoning_effort"))
        assertFalse(json.has("permission_mode"))
        assertFalse(json.has("instructions"))
        assertFalse(json.has("fanout"))
    }

    @Test
    fun stepDraftToJsonEmitsConfigFieldsWhenSet() {
        val step = PipelineStepDraft(
            agentType = "claude",
            model = "opus",
            reasoningEffort = "high",
            permissionMode = "plan",
            instructions = "Be terse.",
        )
        val json = stepDraftToJson(step)
        assertEquals("opus", json.getString("model"))
        assertEquals("high", json.getString("reasoning_effort"))
        assertEquals("plan", json.getString("permission_mode"))
        assertEquals("Be terse.", json.getString("instructions"))
    }

    @Test
    fun stepDraftToJsonEmitsFanoutParallelArraysWhenSet() {
        val step = PipelineStepDraft(
            agentType = "claude",
            fanoutEnabled = true,
            fanoutCount = 3,
            fanoutAgentTypes = listOf("claude", "codex", "gemini"),
            fanoutModels = listOf("opus", "", ""),
            fanoutReasoningEfforts = listOf("high", "", ""),
            fanoutPermissionModes = listOf("", "", "plan"),
        )
        val json = stepDraftToJson(step)
        val fanout = json.getJSONObject("fanout")
        assertEquals(3, fanout.getInt("count"))
        assertEquals("opus", fanout.getJSONArray("models").getString(0))
        assertEquals("high", fanout.getJSONArray("reasoning_efforts").getString(0))
        assertEquals("plan", fanout.getJSONArray("permission_modes").getString(2))
        // No per-run instructions field -- runs share the block's
        // instructions (owner decision §8.1).
        assertFalse(fanout.has("instructions"))
    }

    @Test
    fun stepDraftToJsonOmitsFanoutArraysWhenEmpty() {
        val step = PipelineStepDraft(
            agentType = "claude",
            fanoutEnabled = true,
            fanoutCount = 2,
        )
        val json = stepDraftToJson(step)
        val fanout = json.getJSONObject("fanout")
        assertFalse(fanout.has("models"))
        assertFalse(fanout.has("reasoning_efforts"))
        assertFalse(fanout.has("permission_modes"))
    }

    // ---- PLAN-HARNESS-BUILDER Phase 3: branch/loop recursive encoding --

    @Test
    fun stepDraftToJsonEncodesBranchConditionAndNestedThenElse() {
        val then1 = PipelineSubStepDraft(agentType = "codex", role = "engineer")
        val then2 = PipelineSubStepDraft(agentType = "claude", model = "opus")
        val elseStep = PipelineSubStepDraft(agentType = "claude", role = "researcher")
        val step = PipelineStepDraft(
            kind = "branch",
            branchConditionSource = "prev_output",
            branchConditionPredicate = "contains",
            branchConditionValue = "APPROVED",
            branchThen = listOf(then1, then2),
            branchElse = listOf(elseStep),
        )

        val json = stepDraftToJson(step)
        assertEquals("branch", json.getString("kind"))
        assertFalse(json.has("loop"))
        val branch = json.getJSONObject("branch")
        val condition = branch.getJSONObject("condition")
        assertEquals("prev_output", condition.getString("source"))
        assertEquals("contains", condition.getString("predicate"))
        assertEquals("APPROVED", condition.getString("value"))
        val then = branch.getJSONArray("then")
        assertEquals(2, then.length())
        assertEquals("codex", then.getJSONObject(0).getString("agent_type"))
        assertEquals("opus", then.getJSONObject(1).getString("model"))
        val elseArr = branch.getJSONArray("else")
        assertEquals(1, elseArr.length())
        assertEquals("researcher", elseArr.getJSONObject(0).getString("role"))
    }

    @Test
    fun stepDraftToJsonExitStatusConditionOmitsValue() {
        val step = PipelineStepDraft(
            kind = "branch",
            branchConditionSource = "exit_status",
            branchConditionPredicate = "succeeded",
            branchConditionValue = "", // unused for exit_status
        )
        val json = stepDraftToJson(step)
        val condition = json.getJSONObject("branch").getJSONObject("condition")
        assertEquals("exit_status", condition.getString("source"))
        assertFalse(condition.has("value"))
    }

    @Test
    fun stepDraftToJsonEncodesLoopBodyUntilAndMaxIterations() {
        val body1 = PipelineSubStepDraft(agentType = "claude", instructions = "Iterate until tests pass.")
        val step = PipelineStepDraft(
            kind = "loop",
            loopBody = listOf(body1),
            loopUntilSource = "prev_output",
            loopUntilPredicate = "contains",
            loopUntilValue = "DONE",
            loopMaxIterations = 4,
        )
        val json = stepDraftToJson(step)
        assertEquals("loop", json.getString("kind"))
        assertFalse(json.has("branch"))
        val loop = json.getJSONObject("loop")
        val body = loop.getJSONArray("body")
        assertEquals(1, body.length())
        assertEquals("Iterate until tests pass.", body.getJSONObject(0).getString("instructions"))
        assertEquals("DONE", loop.getJSONObject("until").getString("value"))
        assertEquals(4, loop.getInt("max_iterations"))
    }

    @Test
    fun stepDraftToJsonOmitsControlFlowFieldsForAgentStep() {
        val step = PipelineStepDraft(agentType = "claude")
        val json = stepDraftToJson(step)
        assertFalse(json.has("kind"))
        assertFalse(json.has("branch"))
        assertFalse(json.has("loop"))
    }

    // ---- Depth-2 guard (enforced by construction -- PipelineSubStepDraft
    // has no kind/branch/loop/fanout fields at all). A broker response with
    // a nested branch inside a Then arm (which the broker itself would
    // never produce -- PrepareSteps rejects depth > 2 at create time) still
    // parses safely: the extra keys are ignored by parseSubStepArray,
    // proving the type system bound rather than a runtime check.

    @Test
    fun parsePipelineTemplateBranchDecodesNestedThenElseSubSteps() {
        val raw = """
            {
              "id": "t3", "title": "Branch template", "task": "task",
              "steps": [
                {"agent_type": "claude", "role": "engineer", "prompt_template": "x",
                 "input_from_prev": "none", "gate_after": false,
                 "kind": "branch",
                 "branch": {
                   "condition": {"source": "prev_output", "predicate": "matches", "value": "^OK${'$'}"},
                   "then": [{"agent_type": "codex", "role": "engineer", "prompt_template": "",
                             "input_from_prev": "none", "gate_after": false,
                             "kind": "branch", "branch": {"condition": {"source": "prev_output", "predicate": "contains", "value": "x"}}}],
                   "else": [{"agent_type": "claude", "role": "researcher", "prompt_template": "",
                             "input_from_prev": "none", "gate_after": false}]
                 }}
              ]
            }
        """.trimIndent()
        val tmpl = parsePipelineTemplate(JSONObject(raw))
        val step = tmpl.steps.single()
        assertEquals("branch", step.kind)
        assertEquals("matches", step.branchConditionPredicate)
        assertEquals("codex", step.branchThen.single().agentType)
        // The nested "kind"/"branch" keys on the Then entry are ignored --
        // PipelineSubStepDraft has no such fields to populate.
        assertEquals("researcher", step.branchElse.single().role)
    }

    @Test
    fun parsePipelineTemplateLoopDecodesBodyAndUntil() {
        val raw = """
            {
              "id": "t4", "title": "Loop template", "task": "task",
              "steps": [
                {"agent_type": "claude", "role": "engineer", "prompt_template": "x",
                 "input_from_prev": "none", "gate_after": false,
                 "kind": "loop",
                 "loop": {
                   "body": [{"agent_type": "claude", "role": "engineer", "prompt_template": "",
                             "input_from_prev": "none", "gate_after": false}],
                   "until": {"source": "exit_status", "predicate": "succeeded"},
                   "max_iterations": 5
                 }}
              ]
            }
        """.trimIndent()
        val tmpl = parsePipelineTemplate(JSONObject(raw))
        val step = tmpl.steps.single()
        assertEquals("loop", step.kind)
        assertEquals(1, step.loopBody.size)
        assertEquals("exit_status", step.loopUntilSource)
        assertEquals(5, step.loopMaxIterations)
    }

    // ---- parsePipelineTemplate: tolerate absence / restore on load -----

    @Test
    fun parsePipelineTemplateToleratesAbsentConfigFields() {
        // A template saved before PLAN-HARNESS-BUILDER Phase 1 shipped.
        val raw = """
            {
              "id": "t1",
              "title": "Old template",
              "task": "Do the thing",
              "steps": [
                {"agent_type": "claude", "role": "engineer", "prompt_template": "x",
                 "input_from_prev": "none", "gate_after": false}
              ]
            }
        """.trimIndent()
        val tmpl = parsePipelineTemplate(JSONObject(raw))
        val step = tmpl.steps.single()
        assertEquals("", step.model)
        assertEquals("", step.reasoningEffort)
        assertEquals("", step.permissionMode)
        assertEquals("", step.instructions)
    }

    @Test
    fun parsePipelineTemplateRestoresConfigFieldsWhenPresent() {
        val raw = """
            {
              "id": "t2",
              "title": "New template",
              "task": "Do the thing",
              "steps": [
                {"agent_type": "claude", "role": "engineer", "prompt_template": "x",
                 "input_from_prev": "none", "gate_after": true,
                 "model": "sonnet", "reasoning_effort": "low",
                 "permission_mode": "plan", "instructions": "Only touch the parser."}
              ]
            }
        """.trimIndent()
        val tmpl = parsePipelineTemplate(JSONObject(raw))
        val step = tmpl.steps.single()
        assertEquals("sonnet", step.model)
        assertEquals("low", step.reasoningEffort)
        assertEquals("plan", step.permissionMode)
        assertEquals("Only touch the parser.", step.instructions)
    }

    // ---- liveAgentOptions: broker-driven agent list --------------------

    @Test
    fun liveAgentOptionsFallsBackToStaticListBeforeFirstFetch() {
        assertEquals(listOf("claude", "codex", "opencode"), liveAgentOptions(emptyMap()))
    }

    @Test
    fun liveAgentOptionsExcludesShellAndOrdersKnownFirst() {
        val raw = """
            {"agents": {
              "gemini": {"display_name": "Gemini"},
              "claude": {"display_name": "Claude"},
              "codex": {"display_name": "Codex"},
              "shell": {"display_name": "Shell"}
            }}
        """.trimIndent()
        val descriptors = parseAgentDescriptors(raw)
        val options = liveAgentOptions(descriptors)
        assertFalse("shell" in options)
        assertEquals("claude", options[0])
        assertEquals("codex", options[1])
        assertTrue("gemini" in options)
    }

}
