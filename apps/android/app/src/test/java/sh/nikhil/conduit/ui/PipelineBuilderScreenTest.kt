package sh.nikhil.conduit.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SessionStore
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

    // ---- modelRowHidden: gemini override is a silent no-op (§8.3) ------

    @Test
    fun modelRowHiddenForGeminiEvenWithCatalog() {
        val catalog = listOf(SessionStore.AgentModel(id = "gemini-2.5-pro", displayName = "Gemini 2.5 Pro"))
        assertTrue(modelRowHidden("gemini", catalog))
        assertTrue(modelRowHidden("Gemini", catalog))
    }

    @Test
    fun modelRowHiddenWhenCatalogEmpty() {
        assertTrue(modelRowHidden("claude", null))
        assertTrue(modelRowHidden("claude", emptyList()))
    }

    @Test
    fun modelRowShownForNonGeminiWithCatalog() {
        val catalog = listOf(SessionStore.AgentModel(id = "opus", displayName = "Opus"))
        assertFalse(modelRowHidden("claude", catalog))
    }
}
