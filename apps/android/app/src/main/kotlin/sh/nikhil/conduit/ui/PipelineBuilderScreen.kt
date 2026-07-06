package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.AgentDescriptor
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.descriptorFor
import sh.nikhil.conduit.ui.components.ActionPillVariant
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.ConduitActionPill
import sh.nikhil.conduit.ui.components.ConduitButton
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.ConduitToggleRow
import sh.nikhil.conduit.ui.components.PipelineTopologyItem
import sh.nikhil.conduit.ui.components.PipelineTopologyRail
import java.net.HttpURLConnection
import java.net.URL

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
 * PLAN-HARNESS-BUILDER Phase 3 (§4.3/§4.5): the model row shows whenever the
 * agent's descriptor reports `supports.model_override == true` AND its model
 * catalog is non-empty -- replacing the Phase-1 hardcoded gemini exclusion
 * (owner decision §8.3) now that broker PR #900 wires
 * `SpawnOverride.Model` through ACP `session/set_model` for gemini too. An
 * agent whose descriptor is missing (old broker, no `agents` map) or reports
 * `model_override == false` (opencode today) still hides the row -- a
 * visible control must always be honored.
 */
internal fun modelRowHidden(catalog: List<SessionStore.AgentModel>?, descriptor: AgentDescriptor): Boolean {
    if (catalog.isNullOrEmpty()) return true
    return !descriptor.supportsModelOverride
}
private val ROLE_PRESETS = listOf("researcher", "architect", "engineer", "custom")
private val INPUT_OPTIONS = listOf("none", "output", "memory", "memory+output")

// ---------------------------------------------------------------------------
// Themed capsule controls (config-sheet redesign)
//
// Replaces the stock `DropdownMenu`/`OutlinedTextField(readOnly)` rows and
// raw `Row` of hand-rolled capsules used throughout the step config
// sheet/inspector with `ConduitChip` in a Row -- the exact idiom the
// new-session mode picker (`AgentPickerSheet.kt` `modeBlock`) already uses.
// Owner ask: "make it look like the rest of the app".
// ---------------------------------------------------------------------------

@Composable
private fun CapsuleSegments(
    options: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
    label: (String) -> String = { it },
) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { opt ->
            ConduitChip(
                label = label(opt),
                selected = selected == opt,
                modifier = Modifier.clickable { onSelect(opt) },
            )
        }
    }
}

/** Agent segment with a leading [AgentGlyph] per option. */
@Composable
private fun AgentCapsuleSegments(
    options: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { opt ->
            val isSelected = selected == opt
            Row(
                modifier = Modifier
                    .glassCapsule(tint = if (isSelected) neon.accent else null)
                    .clickable { onSelect(opt) }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                AgentGlyph(assistant = opt, size = 14.dp)
                Text(
                    opt,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.SemiBold,
                    color = if (isSelected) neon.accentText else neon.textDim,
                    maxLines = 1,
                )
            }
        }
    }
}

/** Auto/Plan capsule + helper caption -- identical copy to the new-session
 * `modeBlock` (`AgentPickerSheet.kt`). */
@Composable
private fun ModeCapsuleRow(mode: String, onChange: (String) -> Unit) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        CapsuleSegments(
            options = listOf("", "plan"),
            selected = mode,
            onSelect = onChange,
            label = { if (it == "plan") "Plan" else "Auto" },
        )
        Text(
            "Plan = read-only; agent explores and proposes without editing.",
            fontFamily = neon.mono,
            fontSize = 10.5.sp,
            color = neon.textFaint,
        )
    }
}

/** Caption explaining the "input from prev" segments -- device feedback:
 * the control's meaning wasn't obvious (owner-hit silent no-handoff bug,
 * task 2b). */
@Composable
private fun InputFromPrevCaption() {
    val neon = LocalNeonTheme.current
    Text(
        "output = the previous step's reply is included in this step's prompt",
        fontFamily = neon.mono,
        fontSize = 10.5.sp,
        color = neon.textFaint,
    )
}

/** Preset prompt templates per role. */
private fun promptForRole(role: String): String = when (role) {
    "researcher" -> "Research the codebase and provide a detailed analysis of the relevant code."
    "architect" -> "Design the architecture for the requested change, considering existing patterns."
    "engineer" -> "Implement the requested change following the existing code patterns."
    else -> ""
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

/**
 * Breadcrumb for any step carrying non-default per-block config, at
 * create/save time. Presence only -- never the instruction text itself
 * (Telemetry standing order: no user content in telemetry).
 */
private fun logBlockConfigTelemetry(steps: List<PipelineStepDraft>) {
    steps.forEachIndexed { i, s ->
        val hasConfig = s.model.isNotEmpty() || s.reasoningEffort.isNotEmpty() ||
            s.permissionMode.isNotEmpty() || s.instructions.isNotEmpty()
        if (!hasConfig) return@forEachIndexed
        Telemetry.breadcrumb(
            "pipeline",
            "block_config_set",
            mapOf(
                "step" to i.toString(),
                "model" to if (s.model.isNotEmpty()) "set" else "",
                "effort" to if (s.reasoningEffort.isNotEmpty()) "set" else "",
                "mode" to s.permissionMode,
                "instructions" to if (s.instructions.isNotEmpty()) "set" else "",
            ),
        )
    }
}

/**
 * Pipeline builder screen. Collects a title, task, cwd, base branch, and
 * a list of steps, then POSTs to /api/pipeline and navigates to PipelineMonitorScreen.
 *
 * PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md §3): the
 * Shortcuts-style visual builder. Phone renders a stacked block-card list +
 * a config dialog per tapped block; a true tablet (sw600dp AND width
 * >=840dp, matching `AppRoot`'s gate) renders a two-pane block-list rail +
 * inline inspector. Both layouts read the SAME `PipelineBuilderViewModel`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PipelineBuilderScreen(
    store: SessionStore,
    onCreated: (pipelineId: String, title: String) -> Unit = { _, _ -> },
    onBack: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val sessions by store.sessions.collectAsState()
    val pipelineTemplates by store.pipelineTemplates.collectAsState()
    val pipelineFanout by store.pipelineFanout.collectAsState()
    val pipelineBlockConfig by store.pipelineBlockConfig.collectAsState()
    val pipelineBranch by store.pipelineBranch.collectAsState()
    val pipelineLoop by store.pipelineLoop.collectAsState()
    val agentDescriptors by store.agentDescriptors.collectAsState()
    val modelCatalogMap by store.modelCatalog.collectAsState()
    val agentOptions = remember(agentDescriptors) { liveAgentOptions(agentDescriptors) }
    val scope = rememberCoroutineScope()

    Telemetry.breadcrumb("pipeline", "builder_opened", emptyMap())

    var title by remember { mutableStateOf("") }
    var task by remember { mutableStateOf("") }
    // Default CWD from the first known session; user can override.
    var cwd by remember { mutableStateOf(sessions.firstOrNull()?.cwd ?: "") }
    var baseBranch by remember { mutableStateOf("main") }

    // PLAN-HARNESS-BUILDER Phase 2: steps + selection live in a shared view
    // model so the phone (stacked list + dialog) and tablet (two-pane rail +
    // inspector) layouts read the same state.
    val viewModel = remember { PipelineBuilderViewModel() }
    // Phone only: which step's config dialog is showing (null = none).
    var configSheetStepId by remember { mutableStateOf<String?>(null) }
    // Sub-step (Then/Else/body) full-config editor -- always a dialog on
    // BOTH phone and tablet (unlike the top-level block, which is a dialog
    // on phone / inline inspector on tablet). Nested indefinitely deep
    // two-pane inspectors aren't worth the plumbing for a depth-2-bounded
    // sub-stack, so this one level always dialogs.
    var subStepEditTarget by remember { mutableStateOf<SubStepEditTarget?>(null) }

    var isCreating by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Template state
    var templates by remember { mutableStateOf<List<PipelineTemplateDraft>>(emptyList()) }
    var isLoadingTemplates by remember { mutableStateOf(false) }
    var showTemplatePicker by remember { mutableStateOf(false) }
    var isSavingTemplate by remember { mutableStateOf(false) }
    var templateDeleteConfirm by remember { mutableStateOf<PipelineTemplateDraft?>(null) }

    val canStart = title.trim().isNotEmpty() && task.trim().isNotEmpty()

    // Helper: POST to the endpoint returning a JSONObject.
    fun postEndpointBuilder(path: String, body: JSONObject): Result<JSONObject> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                JSONObject(text)
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    // Helper: GET returning raw string.
    fun getEndpointBuilder(path: String): Result<String> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                text
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    // Helper: DELETE returning JSONObject.
    fun deleteEndpointBuilder(path: String): Result<JSONObject> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "DELETE"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                JSONObject(text)
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    fun loadTemplates() {
        isLoadingTemplates = true
        scope.launch {
            val result = withContext(Dispatchers.IO) { getEndpointBuilder("/api/pipeline-templates") }
            isLoadingTemplates = false
            result.onSuccess { raw ->
                val arr = runCatching {
                    val obj = JSONObject(raw)
                    val templatesArr = obj.optJSONArray("templates")
                    buildList {
                        if (templatesArr != null) {
                            for (i in 0 until templatesArr.length()) {
                                add(parsePipelineTemplate(templatesArr.getJSONObject(i)))
                            }
                        }
                    }
                }.getOrDefault(emptyList())
                templates = arr
            }
        }
    }

    fun applyTemplate(tmpl: PipelineTemplateDraft) {
        Telemetry.breadcrumb(
            "pipeline",
            "template_applied",
            mapOf("id" to tmpl.id, "title" to tmpl.title),
        )
        title = tmpl.title
        task = tmpl.task
        viewModel.applyTemplate(tmpl)
        configSheetStepId = null
    }

    fun saveAsTemplate() {
        if (!canStart) return
        isSavingTemplate = true
        Telemetry.breadcrumb(
            "pipeline",
            "template_saved",
            mapOf("title" to title.trim(), "steps" to viewModel.steps.size.toString()),
        )
        scope.launch {
            logBlockConfigTelemetry(viewModel.steps)
            val body = viewModel.templateSaveRequestJson(title.trim(), task.trim())
            val result = withContext(Dispatchers.IO) {
                postEndpointBuilder("/api/pipeline-templates", body)
            }
            isSavingTemplate = false
            result.onFailure { e ->
                Telemetry.capture(
                    error = e,
                    message = "pipeline template save error",
                    tags = mapOf("surface" to "android", "phase" to "pipeline-builder"),
                )
                errorMessage = e.message ?: "Template save failed"
            }
        }
    }

    fun deleteTemplate(tmpl: PipelineTemplateDraft) {
        Telemetry.breadcrumb(
            "pipeline",
            "template_deleted",
            mapOf("id" to tmpl.id, "title" to tmpl.title),
        )
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                deleteEndpointBuilder("/api/pipeline-templates/${tmpl.id}")
            }
            result.onSuccess {
                templates = templates.filter { it.id != tmpl.id }
            }.onFailure { e ->
                Telemetry.breadcrumb(
                    "pipeline",
                    "template_delete_error",
                    mapOf("id" to tmpl.id, "error" to (e.message ?: "")),
                )
            }
        }
    }

    fun postPipeline() {
        val base = endpoint.httpBaseUrl ?: run {
            errorMessage = "No active endpoint"
            return
        }
        isCreating = true
        Telemetry.breadcrumb(
            "pipeline",
            "create_start",
            mapOf("step_count" to viewModel.steps.size.toString()),
        )
        scope.launch {
            logBlockConfigTelemetry(viewModel.steps)
            val body = viewModel.createRequestJson(title.trim(), task.trim(), cwd.trim(), baseBranch.trim())
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val conn = (URL("$base/api/pipeline").openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"
                        doOutput = true
                        setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                        setRequestProperty("Content-Type", "application/json")
                        connectTimeout = 10_000
                        readTimeout = 20_000
                    }
                    try {
                        conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                        val code = conn.responseCode
                        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                        val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                        conn.disconnect()
                        JSONObject(text)
                    } catch (e: Exception) {
                        conn.disconnect()
                        throw e
                    }
                }
            }
            isCreating = false
            result.onSuccess { json ->
                val id = json.optString("id", "")
                if (id.isNotEmpty()) {
                    Telemetry.breadcrumb(
                        "pipeline",
                        "create_finish",
                        mapOf("pipeline_id" to id),
                    )
                    onCreated(id, title.trim())
                } else {
                    // PLAN-HARNESS-BUILDER Phase 3: a branch/loop validation
                    // failure (depth > 2, bad condition, max_iterations > 5)
                    // comes back as a 400 with a structured
                    // {"error":{"message":...}} body -- surface that message
                    // instead of the raw JSON blob so a rejected harness
                    // fails gracefully with a reason.
                    val serverMessage = json.optJSONObject("error")?.optString("message", "")?.takeIf { it.isNotEmpty() }
                    errorMessage = serverMessage ?: "Failed to create pipeline"
                    Telemetry.diagnostic(
                        "pipeline create failed: no id",
                        tags = mapOf("surface" to "android"),
                    )
                }
            }.onFailure { e ->
                Telemetry.capture(
                    error = e,
                    message = "pipeline create network error",
                    tags = mapOf("surface" to "android", "phase" to "pipeline-builder"),
                )
                errorMessage = e.message ?: "Network error"
            }
        }
    }

    Scaffold(
        containerColor = neon.bg,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "New pipeline",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        color = neon.text,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = neon.text)
                    }
                },
                actions = {
                    if (pipelineTemplates) {
                        TextButton(
                            onClick = {
                                loadTemplates()
                                showTemplatePicker = true
                            },
                        ) {
                            if (isLoadingTemplates) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    color = neon.accent,
                                    strokeWidth = 2.dp,
                                )
                                Spacer(Modifier.width(6.dp))
                            }
                            Text(
                                "From template",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                                color = neon.accent,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = neon.surfaceSolid,
                ),
            )
        },
    ) { paddingValues ->
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
        ) {
            // Gate on a TRUE tablet: smallest-width >= 600dp AND maxWidth >=
            // 840dp -- mirrors `AppRoot`'s gate (a phone in landscape can
            // exceed 840dp but its sw is ~360-480dp, so it stays phone).
            val isTabletForm = androidx.compose.ui.platform.LocalConfiguration.current.smallestScreenWidthDp >= 600 &&
                maxWidth >= 840.dp

            val commonProps = PipelineBuilderCommonProps(
                neon = neon,
                title = title,
                onTitleChange = { title = it },
                task = task,
                onTaskChange = { task = it },
                cwd = cwd,
                onCwdChange = { cwd = it },
                baseBranch = baseBranch,
                onBaseBranchChange = { baseBranch = it },
                viewModel = viewModel,
                showFanout = pipelineFanout,
                showBlockConfig = pipelineBlockConfig,
                showTemplates = pipelineTemplates,
                showBranch = pipelineBranch,
                showLoop = pipelineLoop,
                agentOptions = agentOptions,
                agentDescriptors = agentDescriptors,
                modelCatalogMap = modelCatalogMap,
                canStart = canStart,
                isCreating = isCreating,
                isSavingTemplate = isSavingTemplate,
                onStart = ::postPipeline,
                onSaveTemplate = ::saveAsTemplate,
                onOpenSubStepEditor = { subStepEditTarget = it },
            )

            if (isTabletForm) {
                PipelineBuilderTabletBody(commonProps)
            } else {
                PipelineBuilderPhoneBody(
                    props = commonProps,
                    configSheetStepId = configSheetStepId,
                    onOpenConfig = { configSheetStepId = it },
                    onCloseConfig = { configSheetStepId = null },
                )
            }
        }
    }

    // Sub-step (Then/Else/body) full-config editor dialog -- always
    // modal (both phone + tablet), see subStepEditTarget's doc comment.
    subStepEditTarget?.let { target ->
        val stepIdx = viewModel.steps.indexOfFirst { it.id == target.stepId }
        if (stepIdx >= 0) {
            val subStep = when (target.arm) {
                PipelineSubStepArm.THEN -> viewModel.steps[stepIdx].branchThen
                PipelineSubStepArm.ELSE_ARM -> viewModel.steps[stepIdx].branchElse
                PipelineSubStepArm.BODY -> viewModel.steps[stepIdx].loopBody
            }.firstOrNull { it.id == target.subStepId }
            if (subStep != null) {
                Dialog(
                    onDismissRequest = { subStepEditTarget = null },
                    properties = DialogProperties(usePlatformDefaultWidth = false),
                ) {
                    Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
                        Column(modifier = Modifier.fillMaxSize()) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(16.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "Step",
                                    fontFamily = neon.sans,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 16.sp,
                                    color = neon.text,
                                    modifier = Modifier.weight(1f),
                                )
                                TextButton(onClick = { subStepEditTarget = null }) {
                                    Text("Done", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.accent)
                                }
                            }
                            Column(
                                modifier = Modifier
                                    .weight(1f)
                                    .verticalScroll(rememberScrollState())
                                    .padding(horizontal = 16.dp, vertical = 4.dp),
                                verticalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                SubStepConfigEditor(
                                    sub = subStep,
                                    neon = neon,
                                    showBlockConfig = pipelineBlockConfig,
                                    agentOptions = agentOptions,
                                    agentDescriptors = agentDescriptors,
                                    modelCatalogMap = modelCatalogMap,
                                    onUpdate = { viewModel.updateSubStep(target.stepId, target.arm, it) },
                                )
                                Spacer(Modifier.height(24.dp))
                            }
                        }
                    }
                }
            }
        }
    }

    // Template picker dialog
    if (showTemplatePicker) {
        Dialog(
            onDismissRequest = { showTemplatePicker = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(neon.bg)
                    .padding(16.dp),
            ) {
                Column(modifier = Modifier.fillMaxSize()) {
                    // Dialog header
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(bottom = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "From template",
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp,
                            color = neon.text,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { showTemplatePicker = false }) {
                            Text("Cancel", fontFamily = neon.sans, color = neon.textDim)
                        }
                    }
                    if (templates.isEmpty()) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(top = 32.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                "No templates saved yet",
                                fontFamily = neon.sans,
                                fontSize = 15.sp,
                                color = neon.textDim,
                            )
                            Text(
                                "Use \"Save as template\" after filling in a pipeline.",
                                fontFamily = neon.sans,
                                fontSize = 13.sp,
                                color = neon.textFaint,
                            )
                        }
                    } else {
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            items(templates, key = { it.id }) { tmpl ->
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface),
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .clickable {
                                                applyTemplate(tmpl)
                                                showTemplatePicker = false
                                            }
                                            .padding(12.dp)
                                            .fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                tmpl.title,
                                                fontFamily = neon.sans,
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 14.sp,
                                                color = neon.text,
                                            )
                                            Text(
                                                "${tmpl.steps.size} step${if (tmpl.steps.size == 1) "" else "s"}",
                                                fontFamily = neon.mono,
                                                fontSize = 11.sp,
                                                color = neon.textFaint,
                                            )
                                        }
                                        IconButton(
                                            onClick = { templateDeleteConfirm = tmpl },
                                            modifier = Modifier.size(32.dp),
                                        ) {
                                            Icon(
                                                Icons.Default.Delete,
                                                contentDescription = "Delete template",
                                                tint = neon.red,
                                                modifier = Modifier.size(18.dp),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Template delete confirm dialog
    templateDeleteConfirm?.let { tmpl ->
        AlertDialog(
            onDismissRequest = { templateDeleteConfirm = null },
            title = { Text("Delete template?") },
            text = { Text("Delete \"${tmpl.title}\"? This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteTemplate(tmpl)
                        templateDeleteConfirm = null
                    },
                ) { Text("Delete", color = neon.red) }
            },
            dismissButton = {
                TextButton(onClick = { templateDeleteConfirm = null }) { Text("Cancel") }
            },
        )
    }

    errorMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Error") },
            text = { Text(msg) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) { Text("OK") }
            },
        )
    }
}

/**
 * Shared read-only + callback bundle passed to both the phone and tablet
 * layout composables so they stay in sync with a single source (avoids two
 * screens drifting on which props they read).
 */
private data class PipelineBuilderCommonProps(
    val neon: NeonTheme,
    val title: String,
    val onTitleChange: (String) -> Unit,
    val task: String,
    val onTaskChange: (String) -> Unit,
    val cwd: String,
    val onCwdChange: (String) -> Unit,
    val baseBranch: String,
    val onBaseBranchChange: (String) -> Unit,
    val viewModel: PipelineBuilderViewModel,
    val showFanout: Boolean,
    val showBlockConfig: Boolean,
    val showTemplates: Boolean,
    val showBranch: Boolean,
    val showLoop: Boolean,
    val agentOptions: List<String>,
    val agentDescriptors: Map<String, AgentDescriptor>,
    val modelCatalogMap: Map<String, List<SessionStore.AgentModel>>,
    val canStart: Boolean,
    val isCreating: Boolean,
    val isSavingTemplate: Boolean,
    val onStart: () -> Unit,
    val onSaveTemplate: () -> Unit,
    val onOpenSubStepEditor: (SubStepEditTarget) -> Unit,
)

/** Identifies one sub-step's full-config editor dialog. */
internal data class SubStepEditTarget(val stepId: String, val arm: PipelineSubStepArm, val subStepId: String)

@Composable
private fun PipelineMetadataFields(props: PipelineBuilderCommonProps) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = props.title,
            onValueChange = props.onTitleChange,
            label = { Text("Title") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = props.task,
            onValueChange = props.onTaskChange,
            label = { Text("Task") },
            minLines = 3,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = props.cwd,
            onValueChange = props.onCwdChange,
            label = { Text("Working directory (CWD)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = props.baseBranch,
            onValueChange = props.onBaseBranchChange,
            label = { Text("Base branch") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/**
 * Add-block affordance. A plain button when neither control-flow flag is
 * on (byte-identical UX to Phase 2); a dropdown offering Agent step /
 * If-Else / Loop once the broker advertises either (PLAN-HARNESS-BUILDER
 * Phase 3).
 */
@Composable
private fun AddStepRow(
    neon: NeonTheme,
    onClick: () -> Unit,
    showBranch: Boolean = false,
    showLoop: Boolean = false,
    onAddBranch: () -> Unit = {},
    onAddLoop: () -> Unit = {},
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ConduitActionPill(
            label = "Add step",
            leadingIcon = Icons.Default.Add,
            variant = ActionPillVariant.Soft,
            onClick = { if (showBranch || showLoop) expanded = true else onClick() },
        )
        if (showBranch || showLoop) {
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                DropdownMenuItem(
                    text = { Text("Agent step", fontFamily = neon.sans) },
                    onClick = { onClick(); expanded = false },
                )
                if (showBranch) {
                    DropdownMenuItem(
                        text = { Text("If/Else", fontFamily = neon.sans) },
                        onClick = { onAddBranch(); expanded = false },
                    )
                }
                if (showLoop) {
                    DropdownMenuItem(
                        text = { Text("Loop", fontFamily = neon.sans) },
                        onClick = { onAddLoop(); expanded = false },
                    )
                }
            }
        }
    }
}

@Composable
private fun SaveTemplateButton(neon: NeonTheme, enabled: Boolean, isSaving: Boolean, onClick: () -> Unit) {
    ConduitButton(
        title = if (isSaving) "Saving..." else "Save as template",
        onClick = onClick,
        variant = ButtonVariant.Secondary,
        tint = neon.accent,
        enabled = enabled,
        leadingContent = if (isSaving) {
            {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = neon.accent,
                    strokeWidth = 2.dp,
                )
            }
        } else {
            null
        },
    )
}

@Composable
private fun StartPipelineButton(neon: NeonTheme, enabled: Boolean, isCreating: Boolean, onClick: () -> Unit) {
    ConduitButton(
        title = if (isCreating) "Starting..." else "Start pipeline",
        onClick = onClick,
        variant = ButtonVariant.Primary,
        tint = neon.accent,
        enabled = enabled,
        leadingContent = if (isCreating) {
            {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = neon.accentText,
                    strokeWidth = 2.dp,
                )
            }
        } else {
            null
        },
    )
}

// MARK: Phone layout -- stacked block-card list + config dialog

@Composable
private fun PipelineBuilderPhoneBody(
    props: PipelineBuilderCommonProps,
    configSheetStepId: String?,
    onOpenConfig: (String) -> Unit,
    onCloseConfig: () -> Unit,
) {
    val neon = props.neon
    val vm = props.viewModel
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .navigationBarsPadding(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { PipelineMetadataFields(props) }

        item {
            Text(
                "STEPS",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )
        }

        if (vm.steps.size > 1) {
            item {
                PipelineTopologyRail(
                    items = vm.topologyItems(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface2.copy(alpha = 0.5f))
                        .padding(10.dp),
                    onSelect = onOpenConfig,
                )
            }
        }

        item {
            ReorderableBlockStack(
                steps = vm.steps,
                selectedStepId = null,
                neon = neon,
                modelCatalogMap = props.modelCatalogMap,
                onSelect = onOpenConfig,
                onDelete = { vm.removeStep(it) },
                onMove = { from, to -> vm.moveStep(from, to) },
                canDelete = vm.canDeleteStep,
            )
        }

        item {
            AddStepRow(
                neon = neon,
                onClick = { vm.addStep() },
                showBranch = props.showBranch,
                showLoop = props.showLoop,
                onAddBranch = { vm.addControlFlowStep("branch") },
                onAddLoop = { vm.addControlFlowStep("loop") },
            )
        }

        if (props.showTemplates) {
            item {
                SaveTemplateButton(
                    neon = neon,
                    enabled = props.canStart && !props.isSavingTemplate,
                    isSaving = props.isSavingTemplate,
                    onClick = props.onSaveTemplate,
                )
            }
        }

        item {
            StartPipelineButton(
                neon = neon,
                enabled = props.canStart && !props.isCreating,
                isCreating = props.isCreating,
                onClick = props.onStart,
            )
        }

        item { Spacer(Modifier.height(8.dp)) }
    }

    if (configSheetStepId != null) {
        val index = vm.steps.indexOfFirst { it.id == configSheetStepId }
        if (index >= 0) {
            val step = vm.steps[index]
            Dialog(
                onDismissRequest = onCloseConfig,
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(neon.bg),
                ) {
                    Column(modifier = Modifier.fillMaxSize()) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Step ${index + 1}",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.Bold,
                                fontSize = 16.sp,
                                color = neon.text,
                                modifier = Modifier.weight(1f),
                            )
                            if (vm.canDeleteStep) {
                                IconButton(onClick = {
                                    onCloseConfig()
                                    vm.removeStep(step.id)
                                }) {
                                    Icon(Icons.Default.Delete, contentDescription = "Delete step", tint = neon.red)
                                }
                            }
                            TextButton(onClick = onCloseConfig) {
                                Text("Done", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.accent)
                            }
                        }
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 16.dp, vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            StepConfigEditor(
                                step = step,
                                neon = neon,
                                showFanout = props.showFanout,
                                showBlockConfig = props.showBlockConfig,
                                agentOptions = props.agentOptions,
                                agentDescriptors = props.agentDescriptors,
                                modelCatalogMap = props.modelCatalogMap,
                                onUpdate = { vm.updateStep(step.id, it) },
                                onAddSubStep = { arm -> vm.addSubStep(step.id, arm) },
                                onRemoveSubStep = { arm, id -> vm.removeSubStep(step.id, arm, id) },
                                onMoveSubStep = { arm, id, dir -> vm.moveSubStep(step.id, arm, id, dir) },
                                onOpenSubStepEditor = { arm, id ->
                                    props.onOpenSubStepEditor(SubStepEditTarget(step.id, arm, id))
                                },
                            )
                            Spacer(Modifier.height(24.dp))
                        }
                    }
                }
            }
        }
    }
}

// MARK: Tablet layout -- block-list rail + inspector pane

@Composable
private fun PipelineBuilderTabletBody(props: PipelineBuilderCommonProps) {
    val neon = props.neon
    val vm = props.viewModel
    Row(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .width(380.dp)
                .fillMaxHeight()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            PipelineMetadataFields(props)

            Text(
                "STEPS",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )

            if (vm.steps.size > 1) {
                PipelineTopologyRail(
                    items = vm.topologyItems(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface2.copy(alpha = 0.5f))
                        .padding(10.dp),
                    onSelect = { vm.selectedStepId = it },
                )
            }

            ReorderableBlockStack(
                steps = vm.steps,
                selectedStepId = vm.selectedStepId,
                neon = neon,
                modelCatalogMap = props.modelCatalogMap,
                onSelect = { vm.selectedStepId = it },
                onDelete = { vm.removeStep(it) },
                onMove = { from, to -> vm.moveStep(from, to) },
                canDelete = vm.canDeleteStep,
            )

            AddStepRow(
                neon = neon,
                onClick = { vm.addStep() },
                showBranch = props.showBranch,
                showLoop = props.showLoop,
                onAddBranch = { vm.addControlFlowStep("branch") },
                onAddLoop = { vm.addControlFlowStep("loop") },
            )

            if (props.showTemplates) {
                SaveTemplateButton(
                    neon = neon,
                    enabled = props.canStart && !props.isSavingTemplate,
                    isSaving = props.isSavingTemplate,
                    onClick = props.onSaveTemplate,
                )
            }
            StartPipelineButton(
                neon = neon,
                enabled = props.canStart && !props.isCreating,
                isCreating = props.isCreating,
                onClick = props.onStart,
            )
        }

        androidx.compose.foundation.layout.Box(
            modifier = Modifier.width(1.dp).fillMaxHeight().background(neon.border),
        )

        val selectedIndex = vm.steps.indexOfFirst { it.id == vm.selectedStepId }
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
        ) {
            if (selectedIndex >= 0) {
                val step = vm.steps[selectedIndex]
                Text(
                    "STEP ${selectedIndex + 1}",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                    color = neon.textDim,
                )
                Spacer(Modifier.height(10.dp))
                Column(
                    modifier = Modifier.widthIn(max = 640.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    StepConfigEditor(
                        step = step,
                        neon = neon,
                        showFanout = props.showFanout,
                        showBlockConfig = props.showBlockConfig,
                        agentOptions = props.agentOptions,
                        agentDescriptors = props.agentDescriptors,
                        modelCatalogMap = props.modelCatalogMap,
                        onUpdate = { vm.updateStep(step.id, it) },
                        onAddSubStep = { arm -> vm.addSubStep(step.id, arm) },
                        onRemoveSubStep = { arm, id -> vm.removeSubStep(step.id, arm, id) },
                        onMoveSubStep = { arm, id, dir -> vm.moveSubStep(step.id, arm, id, dir) },
                        onOpenSubStepEditor = { arm, id ->
                            props.onOpenSubStepEditor(SubStepEditTarget(step.id, arm, id))
                        },
                    )
                }
            } else {
                Text(
                    "Select a step to configure it.",
                    fontFamily = neon.sans,
                    fontSize = 14.sp,
                    color = neon.textFaint,
                    modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}

// MARK: Reorderable block-card stack (long-press drag, PLAN-HARNESS-BUILDER §3.1)

/**
 * Vertical block-card stack with long-press drag-to-reorder. Small lists
 * (<=~10 steps) so a plain `Column` + hand-rolled drag offset (rather than
 * `LazyColumn` item animation) keeps this simple: each card tracks its own
 * measured height; crossing half a neighbor's height while dragging swaps
 * it with that neighbor via [onMove] (array-position reindex -- see
 * `PipelineBuilderViewModel.moveStep`).
 */
@Composable
private fun ReorderableBlockStack(
    steps: List<PipelineStepDraft>,
    selectedStepId: String?,
    neon: NeonTheme,
    modelCatalogMap: Map<String, List<SessionStore.AgentModel>>,
    onSelect: (String) -> Unit,
    onDelete: (String) -> Unit,
    onMove: (from: Int, to: Int) -> Unit,
    canDelete: Boolean,
) {
    val itemHeightsPx = remember { mutableStateMapOf<Int, Int>() }
    var draggingIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffsetY by remember { mutableStateOf(0f) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        steps.forEachIndexed { index, step ->
            val isDragging = draggingIndex == index
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .zIndex(if (isDragging) 1f else 0f)
                    .graphicsLayer {
                        translationY = if (isDragging) dragOffsetY else 0f
                        alpha = if (isDragging) 0.92f else 1f
                    }
                    .onGloballyPositioned { itemHeightsPx[index] = it.size.height }
                    .pointerInput(steps.size) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = {
                                draggingIndex = index
                                dragOffsetY = 0f
                                Telemetry.breadcrumb("pipeline", "builder_drag_start", mapOf("index" to index.toString()))
                            },
                            onDragEnd = { draggingIndex = null; dragOffsetY = 0f },
                            onDragCancel = { draggingIndex = null; dragOffsetY = 0f },
                            onDrag = { change, amount ->
                                change.consume()
                                dragOffsetY += amount.y
                                val current = draggingIndex ?: return@detectDragGesturesAfterLongPress
                                val myHeight = (itemHeightsPx[current] ?: return@detectDragGesturesAfterLongPress).toFloat()
                                if (dragOffsetY > myHeight / 2f && current < steps.lastIndex) {
                                    val neighborHeight = (itemHeightsPx[current + 1] ?: myHeight.toInt()).toFloat()
                                    onMove(current, current + 1)
                                    draggingIndex = current + 1
                                    dragOffsetY -= neighborHeight
                                } else if (dragOffsetY < -myHeight / 2f && current > 0) {
                                    val neighborHeight = (itemHeightsPx[current - 1] ?: myHeight.toInt()).toFloat()
                                    onMove(current, current - 1)
                                    draggingIndex = current - 1
                                    dragOffsetY += neighborHeight
                                }
                            },
                        )
                    },
            ) {
                BlockCard(
                    step = step,
                    index = index,
                    isSelected = selectedStepId == step.id,
                    neon = neon,
                    canDelete = canDelete,
                    catalog = modelCatalogMap[step.agentType],
                    onTap = { onSelect(step.id) },
                    onDelete = { onDelete(step.id) },
                )
            }
        }
    }
}

/**
 * Compact block card -- leading tinted agent avatar, role title, inline
 * chips (`agent`/`model`/`effort`/`mode`, only non-default ones), a
 * one-line instructions preview when set. Tap opens the config
 * sheet/inspector. Composed from `ConduitCard` + `ConduitChip` (component
 * library rule).
 */
@Composable
private fun BlockCard(
    step: PipelineStepDraft,
    index: Int,
    isSelected: Boolean,
    neon: NeonTheme,
    canDelete: Boolean,
    catalog: List<SessionStore.AgentModel>?,
    onTap: () -> Unit,
    onDelete: () -> Unit,
) {
    if (step.isControlFlow) {
        ControlFlowBlockCard(
            step = step,
            index = index,
            isSelected = isSelected,
            neon = neon,
            canDelete = canDelete,
            onTap = onTap,
            onDelete = onDelete,
        )
        return
    }
    ConduitCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .then(
                if (isSelected) {
                    Modifier.border(1.5.dp, neon.accent, RoundedCornerShape(ConduitTheme.cardCornerRadiusDp.dp))
                } else {
                    Modifier
                },
            ),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            AgentGlyph(assistant = step.agentType, size = 32.dp)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        "${index + 1}. ${step.role.replaceFirstChar { it.uppercase() }}",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.text,
                        maxLines = 1,
                    )
                    if (step.gateAfter) {
                        Icon(
                            Icons.Filled.PanTool,
                            contentDescription = "Gated",
                            tint = neon.yellow,
                            modifier = Modifier.size(11.dp),
                        )
                    }
                    if (step.fanoutEnabled) {
                        Icon(
                            Icons.AutoMirrored.Filled.CallSplit,
                            contentDescription = "Fan out",
                            tint = neon.accent,
                            modifier = Modifier.size(11.dp),
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ConduitChip(label = step.agentType, tint = agentAccentStrong(step.agentType))
                    if (step.model.isNotEmpty()) {
                        ConduitChip(label = forkModelLabel(step.model, catalog))
                    }
                    if (step.reasoningEffort.isNotEmpty()) {
                        ConduitChip(label = effortLabel(step.reasoningEffort))
                    }
                    if (step.permissionMode.isNotEmpty()) {
                        ConduitChip(label = if (step.permissionMode == "plan") "Plan" else step.permissionMode)
                    }
                }
                if (step.instructions.isNotEmpty()) {
                    Text(
                        step.instructions,
                        fontFamily = neon.sans,
                        fontSize = 11.sp,
                        color = neon.textFaint,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    )
                }
            }
            if (canDelete) {
                IconButton(onClick = onDelete, modifier = Modifier.size(28.dp)) {
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "Delete step",
                        tint = neon.red,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

/**
 * Compact summary card for an If/Else or Loop block -- condition + sub-
 * stack counts only. The full Then/Else/body editor lives in the config
 * dialog/inspector (`ControlFlowConfigEditor`), reached by tapping this
 * card -- same precedent as the fanout toggle today.
 */
@Composable
private fun ControlFlowBlockCard(
    step: PipelineStepDraft,
    index: Int,
    isSelected: Boolean,
    neon: NeonTheme,
    canDelete: Boolean,
    onTap: () -> Unit,
    onDelete: () -> Unit,
) {
    ConduitCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .then(
                if (isSelected) {
                    Modifier.border(1.5.dp, neon.accent, RoundedCornerShape(ConduitTheme.cardCornerRadiusDp.dp))
                } else {
                    Modifier
                },
            ),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(
                if (step.kind == "loop") Icons.Filled.Repeat else Icons.AutoMirrored.Filled.CallSplit,
                contentDescription = if (step.kind == "loop") "Loop" else "If/Else",
                tint = neon.accent,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        "${index + 1}. ${if (step.kind == "loop") "Loop" else "If/Else"}",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.text,
                        maxLines = 1,
                    )
                    if (step.kind == "loop") {
                        ConduitChip(label = "max ${step.loopMaxIterations}x")
                    }
                }
                Text(
                    conditionSummary(step),
                    fontFamily = neon.sans,
                    fontSize = 11.sp,
                    color = neon.textDim,
                    maxLines = 2,
                )
                Text(
                    if (step.kind == "branch") {
                        "${step.branchThen.size} then / ${step.branchElse.size} else"
                    } else {
                        "${step.loopBody.size} step${if (step.loopBody.size == 1) "" else "s"} in body"
                    },
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
            }
            if (canDelete) {
                IconButton(onClick = onDelete, modifier = Modifier.size(28.dp)) {
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "Delete step",
                        tint = neon.red,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

/** Compact one-line human-readable condition summary shown on the block card. */
private fun conditionSummary(step: PipelineStepDraft): String {
    val isLoop = step.kind == "loop"
    val source = if (isLoop) step.loopUntilSource else step.branchConditionSource
    val predicate = if (isLoop) step.loopUntilPredicate else step.branchConditionPredicate
    val value = if (isLoop) step.loopUntilValue else step.branchConditionValue
    val verb = if (isLoop) "until" else "if"
    if (source == "exit_status") return "$verb previous step $predicate"
    return "$verb output ${predicateLabel(predicate)} \"$value\""
}

private fun predicateLabel(p: String): String = when (p) {
    "contains" -> "contains"
    "not_contains" -> "does not contain"
    "matches" -> "matches"
    else -> p
}

/**
 * Per-step config editor (agent / per-block config / role / prompt / input
 * / gate / fanout) -- shared by the phone dialog and tablet inspector.
 * Extracted from what was previously the top half of `StepCard`'s body.
 */
@Composable
private fun StepConfigEditor(
    step: PipelineStepDraft,
    neon: NeonTheme,
    showFanout: Boolean,
    showBlockConfig: Boolean,
    agentOptions: List<String>,
    agentDescriptors: Map<String, AgentDescriptor>,
    modelCatalogMap: Map<String, List<SessionStore.AgentModel>>,
    onUpdate: (PipelineStepDraft) -> Unit,
    onAddSubStep: (PipelineSubStepArm) -> Unit = {},
    onRemoveSubStep: (PipelineSubStepArm, String) -> Unit = { _, _ -> },
    onMoveSubStep: (PipelineSubStepArm, String, Int) -> Unit = { _, _, _ -> },
    onOpenSubStepEditor: (PipelineSubStepArm, String) -> Unit = { _, _ -> },
) {
    if (step.isControlFlow) {
        ControlFlowConfigEditor(
            step = step,
            neon = neon,
            onUpdate = onUpdate,
            onAddSubStep = onAddSubStep,
            onRemoveSubStep = onRemoveSubStep,
            onMoveSubStep = onMoveSubStep,
            onOpenSubStepEditor = onOpenSubStepEditor,
        )
        return
    }
    // Agent type -- themed capsule segments + AgentGlyph, matching the
    // new-session agent picker's per-agent tinting.
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Agent")
        AgentCapsuleSegments(
            options = agentOptions,
            selected = step.agentType,
            onSelect = { onUpdate(step.copy(agentType = it)) },
        )
    }

    if (showBlockConfig) {
        BlockConfigSection(
            agentType = step.agentType,
            model = step.model,
            reasoningEffort = step.reasoningEffort,
            permissionMode = step.permissionMode,
            instructions = step.instructions,
            neon = neon,
            descriptor = descriptorFor(step.agentType, agentDescriptors),
            catalog = modelCatalogMap[step.agentType],
            onModelChange = { onUpdate(step.copy(model = it, reasoningEffort = "")) },
            onEffortChange = { onUpdate(step.copy(reasoningEffort = it)) },
            onModeChange = { onUpdate(step.copy(permissionMode = it)) },
            onInstructionsChange = { onUpdate(step.copy(instructions = it)) },
        )
    }

    // Role preset
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Role")
        CapsuleSegments(
            options = ROLE_PRESETS,
            selected = step.role,
            onSelect = { role ->
                val newPrompt = if (role != "custom") promptForRole(role) else step.promptTemplate
                onUpdate(step.copy(role = role, promptTemplate = newPrompt))
            },
        )
    }

    // Prompt template
    OutlinedTextField(
        value = step.promptTemplate,
        onValueChange = { onUpdate(step.copy(promptTemplate = it)) },
        label = { Text("Prompt template") },
        minLines = 2,
        modifier = Modifier.fillMaxWidth(),
    )

    // Input from prev
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Input from prev")
        CapsuleSegments(
            options = INPUT_OPTIONS,
            selected = step.inputFromPrev,
            onSelect = { onUpdate(step.copy(inputFromPrev = it)) },
        )
        InputFromPrevCaption()
    }

    // Gate after toggle
    ConduitToggleRow(
        icon = Icons.Filled.PanTool,
        title = "Gate after this step",
        checked = step.gateAfter,
        onCheckedChange = { onUpdate(step.copy(gateAfter = it)) },
    )

    if (showFanout) {
        FanoutStepSection(
            step = step,
            neon = neon,
            showBlockConfig = showBlockConfig,
            agentOptions = agentOptions,
            agentDescriptors = agentDescriptors,
            modelCatalogMap = modelCatalogMap,
            onUpdate = onUpdate,
        )
    }
}

// MARK: Control-flow config editor (If/Else + Loop, PLAN-HARNESS-BUILDER Phase 3)
//
// Mirrors the fanout precedent: the indented per-run/sub-step editor lives
// inside the config dialog/inspector, not inline in the compact block card.

@Composable
private fun ControlFlowConfigEditor(
    step: PipelineStepDraft,
    neon: NeonTheme,
    onUpdate: (PipelineStepDraft) -> Unit,
    onAddSubStep: (PipelineSubStepArm) -> Unit,
    onRemoveSubStep: (PipelineSubStepArm, String) -> Unit,
    onMoveSubStep: (PipelineSubStepArm, String, Int) -> Unit,
    onOpenSubStepEditor: (PipelineSubStepArm, String) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(
            if (step.kind == "loop") Icons.Filled.Repeat else Icons.AutoMirrored.Filled.CallSplit,
            contentDescription = null,
            tint = neon.accent,
            modifier = Modifier.size(18.dp),
        )
        Text(
            if (step.kind == "loop") "Loop" else "If/Else",
            fontFamily = neon.sans,
            fontWeight = FontWeight.Bold,
            fontSize = 15.sp,
            color = neon.text,
        )
    }
    Spacer(Modifier.height(4.dp))

    if (step.kind == "branch") {
        ConditionEditor(
            title = "Condition",
            source = step.branchConditionSource,
            predicate = step.branchConditionPredicate,
            value = step.branchConditionValue,
            neon = neon,
            onChange = { src, pred, v ->
                onUpdate(step.copy(branchConditionSource = src, branchConditionPredicate = pred, branchConditionValue = v))
            },
        )
        Spacer(Modifier.height(10.dp))
        SubStackEditor(
            title = "Then",
            arm = PipelineSubStepArm.THEN,
            subSteps = step.branchThen,
            neon = neon,
            onAdd = { onAddSubStep(PipelineSubStepArm.THEN) },
            onRemove = { onRemoveSubStep(PipelineSubStepArm.THEN, it) },
            onMove = { id, dir -> onMoveSubStep(PipelineSubStepArm.THEN, id, dir) },
            onOpen = { onOpenSubStepEditor(PipelineSubStepArm.THEN, it) },
        )
        Spacer(Modifier.height(10.dp))
        SubStackEditor(
            title = "Else (optional)",
            arm = PipelineSubStepArm.ELSE_ARM,
            subSteps = step.branchElse,
            neon = neon,
            onAdd = { onAddSubStep(PipelineSubStepArm.ELSE_ARM) },
            onRemove = { onRemoveSubStep(PipelineSubStepArm.ELSE_ARM, it) },
            onMove = { id, dir -> onMoveSubStep(PipelineSubStepArm.ELSE_ARM, id, dir) },
            onOpen = { onOpenSubStepEditor(PipelineSubStepArm.ELSE_ARM, it) },
        )
    } else {
        ConditionEditor(
            title = "Until",
            source = step.loopUntilSource,
            predicate = step.loopUntilPredicate,
            value = step.loopUntilValue,
            neon = neon,
            onChange = { src, pred, v ->
                onUpdate(step.copy(loopUntilSource = src, loopUntilPredicate = pred, loopUntilValue = v))
            },
        )
        Spacer(Modifier.height(10.dp))
        MaxIterationsStepper(
            value = step.loopMaxIterations,
            neon = neon,
            onChange = { onUpdate(step.copy(loopMaxIterations = it)) },
        )
        Spacer(Modifier.height(10.dp))
        SubStackEditor(
            title = "Body",
            arm = PipelineSubStepArm.BODY,
            subSteps = step.loopBody,
            neon = neon,
            onAdd = { onAddSubStep(PipelineSubStepArm.BODY) },
            onRemove = { onRemoveSubStep(PipelineSubStepArm.BODY, it) },
            onMove = { id, dir -> onMoveSubStep(PipelineSubStepArm.BODY, id, dir) },
            onOpen = { onOpenSubStepEditor(PipelineSubStepArm.BODY, it) },
        )
    }
}

/**
 * Condition source picker (prev_output / exit_status), then either a
 * predicate + value editor (prev_output) or a succeeded/failed toggle
 * (exit_status) -- mirrors `pipeline.Condition`
 * (broker/internal/pipeline/controlflow.go).
 */
@Composable
private fun ConditionEditor(
    title: String,
    source: String,
    predicate: String,
    value: String,
    neon: NeonTheme,
    onChange: (source: String, predicate: String, value: String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title.uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, color = neon.textFaint)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("prev_output" to "Prev output", "exit_status" to "Exit status").forEach { (v, label) ->
                val selected = source == v
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(if (selected) neon.accent else neon.surface2)
                        .border(1.dp, if (selected) neon.accent else neon.border, RoundedCornerShape(50))
                        .clickable {
                            // Snap the predicate to a valid one for the new
                            // source (broker validateCondition rejects a
                            // mismatched pair).
                            val newPredicate = if (v == "exit_status") {
                                if (predicate == "succeeded" || predicate == "failed") predicate else "succeeded"
                            } else {
                                if (predicate in listOf("contains", "not_contains", "matches")) predicate else "contains"
                            }
                            onChange(v, newPredicate, value)
                        }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Text(
                        label,
                        fontFamily = neon.sans,
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                        fontSize = 11.sp,
                        color = if (selected) neon.accentText else neon.textDim,
                    )
                }
            }
        }
        if (source == "exit_status") {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("succeeded" to "Succeeded", "failed" to "Failed").forEach { (v, label) ->
                    val selected = predicate == v
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(if (selected) neon.accent else neon.surface2)
                            .border(1.dp, if (selected) neon.accent else neon.border, RoundedCornerShape(50))
                            .clickable { onChange(source, v, value) }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    ) {
                        Text(
                            label,
                            fontFamily = neon.sans,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                            fontSize = 11.sp,
                            color = if (selected) neon.accentText else neon.textDim,
                        )
                    }
                }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(
                    "contains" to "Contains",
                    "not_contains" to "Not contains",
                    "matches" to "Matches (regex)",
                ).forEach { (v, label) ->
                    val selected = predicate == v
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(if (selected) neon.accent else neon.surface2)
                            .border(1.dp, if (selected) neon.accent else neon.border, RoundedCornerShape(50))
                            .clickable { onChange(source, v, value) }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    ) {
                        Text(
                            label,
                            fontFamily = neon.sans,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                            fontSize = 11.sp,
                            color = if (selected) neon.accentText else neon.textDim,
                        )
                    }
                }
            }
            OutlinedTextField(
                value = value,
                onValueChange = { onChange(source, predicate, it) },
                label = { Text("Value to match") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** max_iterations stepper, 1-5 (broker hard cap, owner decision §8.5), default 3. */
@Composable
private fun MaxIterationsStepper(value: Int, neon: NeonTheme, onChange: (Int) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            "MAX ITERATIONS",
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 10.sp,
            color = neon.textFaint,
            modifier = Modifier.weight(1f),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(50))
                    .background(if (value > 1) neon.accent.copy(alpha = 0.15f) else neon.surface2)
                    .clickable(enabled = value > 1) { onChange(value - 1) },
                contentAlignment = Alignment.Center,
            ) {
                Text("-", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = if (value > 1) neon.accent else neon.textFaint)
            }
            Text("$value", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = neon.text)
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(50))
                    .background(if (value < 5) neon.accent.copy(alpha = 0.15f) else neon.surface2)
                    .clickable(enabled = value < 5) { onChange(value + 1) },
                contentAlignment = Alignment.Center,
            ) {
                Text("+", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = if (value < 5) neon.accent else neon.textFaint)
            }
        }
    }
}

/**
 * A Then/Else/body sub-stack: an indented list of compact sub-step rows
 * (tap to open the full agent-config dialog) + an add-step affordance.
 * Reorder is up/down (not drag) -- consistent with the depth-2 bound (no
 * complex nested drag-reorder needed for a bounded sub-stack).
 */
@Composable
private fun SubStackEditor(
    title: String,
    arm: PipelineSubStepArm,
    subSteps: List<PipelineSubStepDraft>,
    neon: NeonTheme,
    onAdd: () -> Unit,
    onRemove: (String) -> Unit,
    onMove: (String, Int) -> Unit,
    onOpen: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title.uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, color = neon.textFaint)
        Column(
            modifier = Modifier.padding(start = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            subSteps.forEachIndexed { i, sub ->
                SubStepRow(
                    sub = sub,
                    index = i,
                    count = subSteps.size,
                    neon = neon,
                    onTap = { onOpen(sub.id) },
                    onDelete = { onRemove(sub.id) },
                    onMoveUp = { onMove(sub.id, -1) },
                    onMoveDown = { onMove(sub.id, 1) },
                )
            }
        }
        ConduitActionPill(
            label = "Add step",
            modifier = Modifier.padding(start = 10.dp),
            leadingIcon = Icons.Default.Add,
            variant = ActionPillVariant.Soft,
            onClick = onAdd,
        )
    }
}

@Composable
private fun SubStepRow(
    sub: PipelineSubStepDraft,
    index: Int,
    count: Int,
    neon: NeonTheme,
    onTap: () -> Unit,
    onDelete: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(neon.surface2.copy(alpha = 0.6f))
            .clickable(onClick = onTap)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AgentGlyph(assistant = sub.agentType, size = 22.dp)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "${index + 1}. ${sub.role.replaceFirstChar { it.uppercase() }}",
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 12.sp,
                color = neon.text,
                maxLines = 1,
            )
        }
        IconButton(onClick = onMoveUp, modifier = Modifier.size(22.dp), enabled = index > 0) {
            Icon(
                Icons.Default.KeyboardArrowUp,
                contentDescription = "Move up",
                tint = if (index > 0) neon.textDim else neon.textFaint,
                modifier = Modifier.size(16.dp),
            )
        }
        IconButton(onClick = onMoveDown, modifier = Modifier.size(22.dp), enabled = index < count - 1) {
            Icon(
                Icons.Default.KeyboardArrowDown,
                contentDescription = "Move down",
                tint = if (index < count - 1) neon.textDim else neon.textFaint,
                modifier = Modifier.size(16.dp),
            )
        }
        IconButton(onClick = onDelete, modifier = Modifier.size(22.dp)) {
            Icon(Icons.Default.Delete, contentDescription = "Delete step", tint = neon.red, modifier = Modifier.size(14.dp))
        }
    }
}

/**
 * Agent-only config editor for a Then/Else/body sub-step -- no fanout, no
 * kind, no nested control flow (depth-2 bound by construction,
 * `PipelineSubStepDraft` has none of those fields).
 */
@Composable
private fun SubStepConfigEditor(
    sub: PipelineSubStepDraft,
    neon: NeonTheme,
    showBlockConfig: Boolean,
    agentOptions: List<String>,
    agentDescriptors: Map<String, AgentDescriptor>,
    modelCatalogMap: Map<String, List<SessionStore.AgentModel>>,
    onUpdate: (PipelineSubStepDraft) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Agent")
        AgentCapsuleSegments(
            options = agentOptions,
            selected = sub.agentType,
            onSelect = { onUpdate(sub.copy(agentType = it)) },
        )
    }

    if (showBlockConfig) {
        BlockConfigSection(
            agentType = sub.agentType,
            model = sub.model,
            reasoningEffort = sub.reasoningEffort,
            permissionMode = sub.permissionMode,
            instructions = sub.instructions,
            neon = neon,
            descriptor = descriptorFor(sub.agentType, agentDescriptors),
            catalog = modelCatalogMap[sub.agentType],
            onModelChange = { onUpdate(sub.copy(model = it, reasoningEffort = "")) },
            onEffortChange = { onUpdate(sub.copy(reasoningEffort = it)) },
            onModeChange = { onUpdate(sub.copy(permissionMode = it)) },
            onInstructionsChange = { onUpdate(sub.copy(instructions = it)) },
        )
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Role")
        CapsuleSegments(
            options = ROLE_PRESETS,
            selected = sub.role,
            onSelect = { role ->
                val newPrompt = if (role != "custom") promptForRole(role) else sub.promptTemplate
                onUpdate(sub.copy(role = role, promptTemplate = newPrompt))
            },
        )
    }

    OutlinedTextField(
        value = sub.promptTemplate,
        onValueChange = { onUpdate(sub.copy(promptTemplate = it)) },
        label = { Text("Prompt template") },
        minLines = 2,
        modifier = Modifier.fillMaxWidth(),
    )

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Input from prev")
        CapsuleSegments(
            options = INPUT_OPTIONS,
            selected = sub.inputFromPrev,
            onSelect = { onUpdate(sub.copy(inputFromPrev = it)) },
        )
        InputFromPrevCaption()
    }

    ConduitToggleRow(
        icon = Icons.Filled.PanTool,
        title = "Gate after this step",
        checked = sub.gateAfter,
        onCheckedChange = { onUpdate(sub.copy(gateAfter = it)) },
    )
}

@Composable
private fun BlockConfigSection(
    agentType: String,
    model: String,
    reasoningEffort: String,
    permissionMode: String,
    instructions: String,
    neon: NeonTheme,
    descriptor: AgentDescriptor,
    catalog: List<SessionStore.AgentModel>?,
    onModelChange: (String) -> Unit,
    onEffortChange: (String) -> Unit,
    onModeChange: (String) -> Unit,
    onInstructionsChange: (String) -> Unit,
) {
    val showModel = !modelRowHidden(catalog, descriptor)
    val efforts = catalogEntryFor(model, catalog)?.efforts ?: emptyList()
    val showEffort = efforts.isNotEmpty()
    val showMode = descriptor.supportsPlanMode

    val tint = neonAgentColor(agentType, neon)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (showModel) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                ModelPickerSectionLabel("Model")
                ModelPickerRow(
                    assistant = agentType,
                    model = model,
                    catalog = catalog,
                    onSelect = onModelChange,
                )
            }
        }

        if (showEffort) {
            EffortDial(
                options = efforts,
                effort = reasoningEffort,
                tint = tint,
                onSelect = onEffortChange,
                allowDefault = true,
            )
        }

        if (showMode) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                ModelPickerSectionLabel("Permission mode")
                ModeCapsuleRow(mode = permissionMode, onChange = onModeChange)
            }
        }

        OutlinedTextField(
            value = instructions,
            onValueChange = onInstructionsChange,
            label = { Text("Instructions for this block") },
            placeholder = { Text("Optional standing guidance for this block...") },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun FanoutStepSection(
    step: PipelineStepDraft,
    neon: NeonTheme,
    showBlockConfig: Boolean = false,
    agentOptions: List<String> = STATIC_AGENT_TYPES,
    agentDescriptors: Map<String, AgentDescriptor> = emptyMap(),
    modelCatalogMap: Map<String, List<SessionStore.AgentModel>> = emptyMap(),
    onUpdate: (PipelineStepDraft) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(
                if (step.fanoutEnabled) neon.accent.copy(alpha = 0.07f)
                else neon.surface2.copy(alpha = 0.5f)
            )
            .border(
                1.dp,
                if (step.fanoutEnabled) neon.accent.copy(alpha = 0.25f) else neon.border.copy(alpha = 0.5f),
                RoundedCornerShape(10.dp),
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Fan out toggle row
        ConduitToggleRow(
            icon = Icons.AutoMirrored.Filled.CallSplit,
            title = "Fan out this step",
            checked = step.fanoutEnabled,
            onCheckedChange = { enabled ->
                Telemetry.breadcrumb(
                    "pipeline",
                    "fanout_toggle",
                    mapOf("enabled" to enabled.toString()),
                )
                onUpdate(step.copy(fanoutEnabled = enabled))
            },
        )

        if (step.fanoutEnabled) {
            // Run count stepper (1-6)
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "RUN COUNT",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                    modifier = Modifier.weight(1f),
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(50))
                            .background(
                                if (step.fanoutCount > 1) neon.accent.copy(alpha = 0.15f)
                                else neon.surface2
                            )
                            .clickable(enabled = step.fanoutCount > 1) {
                                val newCount = step.fanoutCount - 1
                                onUpdate(
                                    step.copy(
                                        fanoutCount = newCount,
                                        fanoutAgentTypes = step.fanoutAgentTypes.take(newCount),
                                        fanoutModels = step.fanoutModels.take(newCount),
                                        fanoutReasoningEfforts = step.fanoutReasoningEfforts.take(newCount),
                                        fanoutPermissionModes = step.fanoutPermissionModes.take(newCount),
                                    ),
                                )
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "-",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp,
                            color = if (step.fanoutCount > 1) neon.accent else neon.textFaint,
                        )
                    }
                    Text(
                        "${step.fanoutCount}",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp,
                        color = neon.text,
                    )
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(50))
                            .background(
                                if (step.fanoutCount < 6) neon.accent.copy(alpha = 0.15f)
                                else neon.surface2
                            )
                            .clickable(enabled = step.fanoutCount < 6) {
                                onUpdate(step.copy(fanoutCount = step.fanoutCount + 1))
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "+",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp,
                            color = if (step.fanoutCount < 6) neon.accent else neon.textFaint,
                        )
                    }
                }
            }

            // Per-run agent pickers
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "PER-RUN AGENTS (OPTIONAL)",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 10.sp,
                        color = neon.textFaint,
                        modifier = Modifier.weight(1f),
                    )
                    if (step.fanoutAgentTypes.isNotEmpty()) {
                        Text(
                            "Clear",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 10.sp,
                            color = neon.red,
                            modifier = Modifier.clickable {
                                onUpdate(step.copy(fanoutAgentTypes = emptyList()))
                            },
                        )
                    }
                }
                Text(
                    "Leave unset to run step agent x ${step.fanoutCount}.",
                    fontFamily = neon.sans,
                    fontSize = 11.sp,
                    color = neon.textFaint,
                )
                repeat(step.fanoutCount) { runIdx ->
                    val currentAgent = step.fanoutAgentTypes.getOrElse(runIdx) { step.agentType }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            "Run ${runIdx + 1}",
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textFaint,
                            modifier = Modifier.width(44.dp),
                        )
                        Box(modifier = Modifier.weight(1f)) {
                            AgentCapsuleSegments(
                                options = agentOptions,
                                selected = currentAgent,
                                onSelect = { agent ->
                                    val arr = step.fanoutAgentTypes.toMutableList()
                                    while (arr.size <= runIdx) arr.add(step.agentType)
                                    arr[runIdx] = agent
                                    onUpdate(step.copy(fanoutAgentTypes = arr))
                                },
                            )
                        }
                    }
                    if (showBlockConfig) {
                        RunConfigRow(
                            step = step,
                            runIdx = runIdx,
                            runAgent = currentAgent,
                            neon = neon,
                            descriptor = descriptorFor(currentAgent, agentDescriptors),
                            catalog = modelCatalogMap[currentAgent],
                            onUpdate = onUpdate,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Per-run model / reasoning-effort / permission-mode pickers
 * (PLAN-HARNESS-BUILDER §2.1/§2.5), index-aligned with the run and resolved
 * against the RUN's agent (which may differ from the step's agent) -- NOT
 * instructions, which per owner decision (§8.1) are shared from the block
 * and have no per-run UI.
 */
@Composable
private fun RunConfigRow(
    step: PipelineStepDraft,
    runIdx: Int,
    runAgent: String,
    neon: NeonTheme,
    descriptor: AgentDescriptor,
    catalog: List<SessionStore.AgentModel>?,
    onUpdate: (PipelineStepDraft) -> Unit,
) {
    val showModel = !modelRowHidden(catalog, descriptor)
    val model = step.fanoutModels.getOrElse(runIdx) { "" }
    val efforts = catalogEntryFor(model, catalog)?.efforts ?: emptyList()
    val showEffort = efforts.isNotEmpty()
    val showMode = descriptor.supportsPlanMode
    if (!showModel && !showEffort && !showMode) return

    val effort = step.fanoutReasoningEfforts.getOrElse(runIdx) { "" }
    val mode = step.fanoutPermissionModes.getOrElse(runIdx) { "" }

    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Spacer(Modifier.width(44.dp))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (showModel) {
                ModelPickerRow(
                    assistant = runAgent,
                    model = model,
                    catalog = catalog,
                    onSelect = { picked ->
                        val arr = step.fanoutModels.toMutableList()
                        while (arr.size <= runIdx) arr.add("")
                        arr[runIdx] = picked
                        onUpdate(step.copy(fanoutModels = arr))
                    },
                )
            }
            if (showEffort) {
                CapsuleSegments(
                    options = listOf("") + efforts,
                    selected = effort,
                    onSelect = { level ->
                        val arr = step.fanoutReasoningEfforts.toMutableList()
                        while (arr.size <= runIdx) arr.add("")
                        arr[runIdx] = level
                        onUpdate(step.copy(fanoutReasoningEfforts = arr))
                    },
                    label = { if (it.isEmpty()) "Default" else effortLabel(it) },
                )
            }
            if (showMode) {
                CapsuleSegments(
                    options = listOf("", "plan"),
                    selected = mode,
                    onSelect = { value ->
                        val arr = step.fanoutPermissionModes.toMutableList()
                        while (arr.size <= runIdx) arr.add("")
                        arr[runIdx] = value
                        onUpdate(step.copy(fanoutPermissionModes = arr))
                    },
                    label = { if (it == "plan") "Plan" else "Auto" },
                )
            }
        }
    }
}
