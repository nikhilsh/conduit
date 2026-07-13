package sh.nikhil.conduit.ui

import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.AgentDescriptor

/** Mutable builder state for one pipeline step. */
data class PipelineStepDraft(
    // Stable identity across recomposition/reorder (PLAN-HARNESS-BUILDER
    // Phase 2, mirrors iOS `PipelineStep.id`); NOT part of the wire shape --
    // stepDraftToJson never reads it.
    val id: String = java.util.UUID.randomUUID().toString(),
    val agentType: String = "claude",
    val role: String = "engineer",
    val promptTemplate: String = "",
    val inputFromPrev: String = "none",
    val gateAfter: Boolean = false,
    // Per-block config (PLAN-HARNESS-BUILDER Phase 1, gated on
    // store.pipelineBlockConfig). "" = adapter default / inherit.
    val model: String = "",
    val reasoningEffort: String = "",
    val permissionMode: String = "",
    val instructions: String = "",
    // Fanout config (present only when fanoutEnabled == true)
    val fanoutEnabled: Boolean = false,
    val fanoutCount: Int = 2,
    // Per-run agent types (index-aligned); empty = use step agent for all runs
    val fanoutAgentTypes: List<String> = emptyList(),
    // Per-run config overrides (index-aligned; "" = inherit from the step).
    val fanoutModels: List<String> = emptyList(),
    val fanoutReasoningEfforts: List<String> = emptyList(),
    val fanoutPermissionModes: List<String> = emptyList(),

    // Control flow (PLAN-HARNESS-BUILDER Phase 3, gated on
    // store.pipelineBranch / store.pipelineLoop). "" = plain agent step
    // (everything above), back-compatible with Phase 1/2.
    val kind: String = "", // "" | "branch" | "loop"
    // Branch condition (used when kind == "branch")
    val branchConditionSource: String = "prev_output", // "prev_output" | "exit_status"
    val branchConditionPredicate: String = "contains", // prev_output: contains|not_contains|matches; exit_status: succeeded|failed
    val branchConditionValue: String = "",
    // Then/Else sub-stacks -- PipelineSubStepDraft (agent-only: no kind, no
    // fanout, no nested branch/loop). This is the depth-2 + no-fanout-
    // inside guard ENFORCED BY THE TYPE SYSTEM (docs/PLAN-HARNESS-BUILDER.md
    // §4.1/§4.5): there is no control to hide because the option doesn't
    // exist on this type.
    val branchThen: List<PipelineSubStepDraft> = listOf(PipelineSubStepDraft()),
    val branchElse: List<PipelineSubStepDraft> = emptyList(),
    // Loop config (used when kind == "loop")
    val loopBody: List<PipelineSubStepDraft> = listOf(PipelineSubStepDraft()),
    val loopUntilSource: String = "prev_output",
    val loopUntilPredicate: String = "contains",
    val loopUntilValue: String = "",
    val loopMaxIterations: Int = 3, // 1-5, default 3 (owner decision §8.5)
) {
    val isControlFlow: Boolean get() = kind == "branch" || kind == "loop"

    companion object {
        // Role prompt templates (shared by `PipelineBuilderViewModel`'s step
        // creation and `FlowStepEditorSheet`'s role picker/on-appear prefill
        // -- one copy so they can't drift). Pipeline vocabulary is
        // Research/Design/Build/Custom (design_handoff_flow README
        // "Interactions & state"); "custom" (and any role without a canned
        // template) leaves the prompt blank for the user to fill in. Mirror
        // of iOS `ConduitUI.PipelineStep.defaultPromptTemplate(forRole:)`.
        fun defaultPromptTemplate(role: String): String = when (role) {
            "researcher" -> "Investigate the codebase and summarize findings."
            "architect" -> "Design the implementation. Prior work: {{prev}}"
            "engineer" -> "Implement the approved design. Prior work: {{prev}}"
            else -> ""
        }

        /**
         * A single starter step for a brand-new flow/pipeline -- role
         * "researcher" with its prompt prefilled, never a blank "engineer"
         * step (device feedback: a fresh Flow opened to "Engineer" with an
         * empty prompt). Mirror of iOS `PipelineStep.starter`.
         */
        fun starter(): PipelineStepDraft {
            val role = "researcher"
            return PipelineStepDraft(role = role, promptTemplate = defaultPromptTemplate(role))
        }
    }
}

/**
 * A step nested inside a branch's Then/Else arm or a loop's body.
 * Deliberately a SEPARATE, smaller type from `PipelineStepDraft` -- it has
 * no `kind`/`branch`/`loop`/`fanout` fields, which is the depth-2 +
 * no-fanout-inside bound from PLAN-HARNESS-BUILDER §4.1/§4.5 enforced by
 * construction: there is no control to hide because a sub-step cannot
 * represent another branch/loop/fanout in the first place. Mirror of iOS
 * `ConduitUI.PipelineSubStep`.
 */
data class PipelineSubStepDraft(
    val id: String = java.util.UUID.randomUUID().toString(),
    val agentType: String = "claude",
    val role: String = "engineer",
    val promptTemplate: String = "",
    val inputFromPrev: String = "none",
    val gateAfter: Boolean = false,
    val model: String = "",
    val reasoningEffort: String = "",
    val permissionMode: String = "",
    val instructions: String = "",
)

/** Which sub-stack a [PipelineSubStepDraft] belongs to. */
enum class PipelineSubStepArm { THEN, ELSE_ARM, BODY }

/**
 * Identifies one sub-step's full-config editor sheet: which parent block,
 * which arm, which sub-step. Mirror of iOS `ConduitUI.SubStepEditTarget`.
 */
data class SubStepEditTarget(val stepId: String, val arm: PipelineSubStepArm, val subStepId: String)

/** A saved pipeline template returned by GET /api/pipeline-templates. */
data class PipelineTemplateDraft(
    val id: String,
    val title: String,
    val task: String,
    val steps: List<PipelineStepDraft>,
)

/** Parse a pipeline template from a JSON object. */
internal fun parsePipelineTemplate(obj: JSONObject): PipelineTemplateDraft {
    val stepsArr = obj.optJSONArray("steps")
    val steps = buildList {
        if (stepsArr != null) {
            for (i in 0 until stepsArr.length()) {
                add(parseStepDraft(stepsArr.getJSONObject(i)))
            }
        }
    }
    return PipelineTemplateDraft(
        id = obj.optString("id", ""),
        title = obj.optString("title", ""),
        task = obj.optString("task", ""),
        steps = steps.ifEmpty { listOf(PipelineStepDraft()) },
    )
}

/** Parses one top-level step (agent step OR kind=="branch"/"loop"). */
private fun parseStepDraft(s: JSONObject): PipelineStepDraft {
    var step = PipelineStepDraft(
        agentType = s.optString("agent_type", "claude"),
        role = s.optString("role", "engineer"),
        promptTemplate = s.optString("prompt_template", ""),
        inputFromPrev = s.optString("input_from_prev", "none"),
        gateAfter = s.optBoolean("gate_after", false),
        // Per-block config (PLAN-HARNESS-BUILDER Phase 1).
        // Absent on an older saved template -> "" (adapter default).
        model = s.optString("model", ""),
        reasoningEffort = s.optString("reasoning_effort", ""),
        permissionMode = s.optString("permission_mode", ""),
        instructions = s.optString("instructions", ""),
    )
    // Control flow (PLAN-HARNESS-BUILDER Phase 3). Absent on an older saved
    // template -> kind stays "" (plain agent step).
    when (s.optString("kind", "")) {
        "branch" -> {
            val b = s.optJSONObject("branch") ?: return step
            val cond = b.optJSONObject("condition") ?: JSONObject()
            step = step.copy(
                kind = "branch",
                branchConditionSource = cond.optString("source", "prev_output"),
                branchConditionPredicate = cond.optString("predicate", "contains"),
                branchConditionValue = cond.optString("value", ""),
                branchThen = parseSubStepArray(b.optJSONArray("then")),
                branchElse = parseSubStepArray(b.optJSONArray("else")),
            )
        }
        "loop" -> {
            val l = s.optJSONObject("loop") ?: return step
            val until = l.optJSONObject("until") ?: JSONObject()
            step = step.copy(
                kind = "loop",
                loopBody = parseSubStepArray(l.optJSONArray("body")).ifEmpty { listOf(PipelineSubStepDraft()) },
                loopUntilSource = until.optString("source", "prev_output"),
                loopUntilPredicate = until.optString("predicate", "contains"),
                loopUntilValue = until.optString("value", ""),
                loopMaxIterations = l.optInt("max_iterations", 3),
            )
        }
    }
    return step
}

private fun parseSubStepArray(arr: org.json.JSONArray?): List<PipelineSubStepDraft> {
    if (arr == null) return emptyList()
    return buildList {
        for (i in 0 until arr.length()) {
            val s = arr.optJSONObject(i) ?: continue
            add(
                PipelineSubStepDraft(
                    agentType = s.optString("agent_type", "claude"),
                    role = s.optString("role", "engineer"),
                    promptTemplate = s.optString("prompt_template", ""),
                    inputFromPrev = s.optString("input_from_prev", "none"),
                    gateAfter = s.optBoolean("gate_after", false),
                    model = s.optString("model", ""),
                    reasoningEffort = s.optString("reasoning_effort", ""),
                    permissionMode = s.optString("permission_mode", ""),
                    instructions = s.optString("instructions", ""),
                ),
            )
        }
    }
}

/**
 * Fallback assistant list used before the first successful capabilities
 * fetch (old broker, or fetch still pending). The live list comes from
 * `store.agentDescriptors` (broker `agents` map, WS-3.1) -- the same store
 * data the fork / new-session pickers consume. "shell" is excluded there --
 * it is a raw terminal, not an agent.
 */
private val STATIC_AGENT_TYPES = listOf("claude", "codex", "opencode")

/**
 * Live assistant list from the broker's capabilities descriptors -- reuses
 * [agentListFor] (`AgentPickerSheet.kt`), the SAME ordering the new-session /
 * fork pickers use (claude, codex first, then extras alphabetically), with
 * "shell" excluded (a raw terminal, not an agent). Falls back to
 * [STATIC_AGENT_TYPES] before the first successful capabilities fetch (old
 * broker, or fetch still pending) so the picker never renders empty.
 */
internal fun liveAgentOptions(descriptors: Map<String, AgentDescriptor>): List<String> {
    if (descriptors.isEmpty()) return STATIC_AGENT_TYPES
    return agentListFor(descriptors).filter { it.lowercase() != "shell" }
}

/**
 * Encode one step draft to the `/api/pipeline` / `/api/pipeline-templates`
 * step JSON shape, including the PLAN-HARNESS-BUILDER Phase 1 per-block
 * config fields (omitted when empty so an old broker's decode is
 * unaffected) and the fanout per-run parallel arrays.
 */
internal fun stepDraftToJson(step: PipelineStepDraft): JSONObject = JSONObject().apply {
    put("agent_type", step.agentType)
    put("role", step.role)
    put("prompt_template", step.promptTemplate)
    put("input_from_prev", step.inputFromPrev)
    put("gate_after", step.gateAfter)
    if (step.fanoutEnabled) {
        put("fanout", JSONObject().apply {
            put("count", step.fanoutCount)
            if (step.fanoutAgentTypes.isNotEmpty()) {
                put("agent_types", JSONArray(step.fanoutAgentTypes))
            }
            // Per-run config overrides; "" = inherit from the step. No
            // per-run instructions -- runs share the block's instructions
            // (owner decision §8.1).
            if (step.fanoutModels.isNotEmpty()) {
                put("models", JSONArray(step.fanoutModels))
            }
            if (step.fanoutReasoningEfforts.isNotEmpty()) {
                put("reasoning_efforts", JSONArray(step.fanoutReasoningEfforts))
            }
            if (step.fanoutPermissionModes.isNotEmpty()) {
                put("permission_modes", JSONArray(step.fanoutPermissionModes))
            }
        })
    }
    if (step.model.isNotEmpty()) put("model", step.model)
    if (step.reasoningEffort.isNotEmpty()) put("reasoning_effort", step.reasoningEffort)
    if (step.permissionMode.isNotEmpty()) put("permission_mode", step.permissionMode)
    if (step.instructions.isNotEmpty()) put("instructions", step.instructions)

    // Control flow (PLAN-HARNESS-BUILDER Phase 3); omitted when the step is
    // a plain agent step so the request stays byte-identical to Phase 1/2
    // for every non-control-flow block.
    when (step.kind) {
        "branch" -> {
            put("kind", "branch")
            put(
                "branch",
                JSONObject().apply {
                    put(
                        "condition",
                        conditionToJson(
                            step.branchConditionSource,
                            step.branchConditionPredicate,
                            step.branchConditionValue,
                        ),
                    )
                    if (step.branchThen.isNotEmpty()) {
                        put("then", JSONArray().apply { step.branchThen.forEach { put(subStepDraftToJson(it)) } })
                    }
                    if (step.branchElse.isNotEmpty()) {
                        put("else", JSONArray().apply { step.branchElse.forEach { put(subStepDraftToJson(it)) } })
                    }
                },
            )
        }
        "loop" -> {
            put("kind", "loop")
            put(
                "loop",
                JSONObject().apply {
                    put("body", JSONArray().apply { step.loopBody.forEach { put(subStepDraftToJson(it)) } })
                    put(
                        "until",
                        conditionToJson(step.loopUntilSource, step.loopUntilPredicate, step.loopUntilValue),
                    )
                    put("max_iterations", step.loopMaxIterations)
                },
            )
        }
    }
}

/** Recursively-encoded Then/Else/body sub-step -- mirrors [PipelineSubStepDraft]. */
internal fun subStepDraftToJson(step: PipelineSubStepDraft): JSONObject = JSONObject().apply {
    put("agent_type", step.agentType)
    put("role", step.role)
    put("prompt_template", step.promptTemplate)
    put("input_from_prev", step.inputFromPrev)
    put("gate_after", step.gateAfter)
    if (step.model.isNotEmpty()) put("model", step.model)
    if (step.reasoningEffort.isNotEmpty()) put("reasoning_effort", step.reasoningEffort)
    if (step.permissionMode.isNotEmpty()) put("permission_mode", step.permissionMode)
    if (step.instructions.isNotEmpty()) put("instructions", step.instructions)
}

/**
 * Encodes a `pipeline.Condition` (source/predicate/value) --
 * `broker/internal/pipeline/controlflow.go`. `value` is unused for
 * exit_status predicates (broker: Value string json:"value,omitempty"),
 * so it is only emitted for prev_output.
 */
internal fun conditionToJson(source: String, predicate: String, value: String): JSONObject = JSONObject().apply {
    put("source", source)
    put("predicate", predicate)
    if (source == "prev_output" && value.isNotEmpty()) put("value", value)
}

