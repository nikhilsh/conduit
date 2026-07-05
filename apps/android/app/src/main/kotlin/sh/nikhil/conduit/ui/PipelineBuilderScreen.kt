package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
import java.net.HttpURLConnection
import java.net.URL

/** Mutable builder state for one pipeline step. */
data class PipelineStepDraft(
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
)

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
                val s = stepsArr.getJSONObject(i)
                add(
                    PipelineStepDraft(
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
                    ),
                )
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
 * Per PLAN-HARNESS-BUILDER §8.3 (owner decision, overriding the plan's
 * "disabled with caption" text): the model override is a silent no-op for
 * gemini (ACP picks its model at `session/new`, `backend_acpwire.go:611-613`),
 * so the model row is HIDDEN entirely for gemini rather than shown disabled.
 */
internal fun modelRowHidden(agentType: String, catalog: List<SessionStore.AgentModel>?): Boolean =
    agentType.lowercase() == "gemini" || catalog.isNullOrEmpty()
private val ROLE_PRESETS = listOf("researcher", "architect", "engineer", "custom")
private val INPUT_OPTIONS = listOf("none", "output", "memory", "memory+output")

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

    val steps = remember { mutableStateListOf(PipelineStepDraft()) }

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
        steps.clear()
        steps.addAll(tmpl.steps)
        if (steps.isEmpty()) steps.add(PipelineStepDraft())
    }

    fun saveAsTemplate() {
        if (!canStart) return
        isSavingTemplate = true
        Telemetry.breadcrumb(
            "pipeline",
            "template_saved",
            mapOf("title" to title.trim(), "steps" to steps.size.toString()),
        )
        scope.launch {
            logBlockConfigTelemetry(steps)
            val stepsJson = JSONArray().apply {
                steps.forEach { step -> put(stepDraftToJson(step)) }
            }
            val body = JSONObject().apply {
                put("title", title.trim())
                put("task", task.trim())
                put("steps", stepsJson)
            }
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
            mapOf("step_count" to steps.size.toString()),
        )
        scope.launch {
            logBlockConfigTelemetry(steps)
            val stepsJson = JSONArray().apply {
                steps.forEach { step -> put(stepDraftToJson(step)) }
            }
            val body = JSONObject().apply {
                put("title", title.trim())
                put("task", task.trim())
                put("cwd", cwd.trim())
                put("base", baseBranch.trim())
                put("steps", stepsJson)
            }
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
                    errorMessage = json.optString("error", "Failed to create pipeline")
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
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .navigationBarsPadding(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 16.dp,
                vertical = 14.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Pipeline fields
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        label = { Text("Title") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = task,
                        onValueChange = { task = it },
                        label = { Text("Task") },
                        minLines = 3,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = cwd,
                        onValueChange = { cwd = it },
                        label = { Text("Working directory (CWD)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = baseBranch,
                        onValueChange = { baseBranch = it },
                        label = { Text("Base branch") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            // Steps header
            item {
                Text(
                    "STEPS",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )
            }

            // Step cards
            itemsIndexed(steps) { index, step ->
                StepCard(
                    index = index,
                    step = step,
                    neon = neon,
                    canDelete = steps.size > 1,
                    showFanout = pipelineFanout,
                    showBlockConfig = pipelineBlockConfig,
                    agentOptions = agentOptions,
                    agentDescriptors = agentDescriptors,
                    modelCatalogMap = modelCatalogMap,
                    onUpdate = { updated -> steps[index] = updated },
                    onDelete = { steps.removeAt(index) },
                )
            }

            // Add step button
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .border(1.dp, neon.border, RoundedCornerShape(12.dp))
                        .clickable { steps.add(PipelineStepDraft()) }
                        .padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "Add step",
                        tint = neon.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Add step",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        color = neon.accent,
                    )
                }
            }

            // Save as template button (only when broker supports pipeline_templates)
            if (pipelineTemplates) {
                item {
                    val enabled = canStart && !isSavingTemplate
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(neon.accent.copy(alpha = 0.10f))
                            .border(1.dp, neon.accent.copy(alpha = 0.30f), RoundedCornerShape(12.dp))
                            .clickable(enabled = enabled, onClick = ::saveAsTemplate)
                            .padding(vertical = 11.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (isSavingTemplate) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    color = neon.accent,
                                    strokeWidth = 2.dp,
                                )
                            }
                            Text(
                                if (isSavingTemplate) "Saving..." else "Save as template",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                                color = if (enabled) neon.accent else neon.textFaint,
                            )
                        }
                    }
                }
            }

            // Start pipeline button
            item {
                val startEnabled = canStart && !isCreating
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(if (startEnabled) neon.accent else neon.surface2)
                        .clickable(enabled = startEnabled, onClick = ::postPipeline)
                        .padding(vertical = 14.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (isCreating) "Starting..." else "Start pipeline",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp,
                        color = if (startEnabled) neon.accentText else neon.textFaint,
                    )
                }
            }

            item { Spacer(Modifier.height(8.dp)) }
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

@Composable
private fun StepCard(
    index: Int,
    step: PipelineStepDraft,
    neon: NeonTheme,
    canDelete: Boolean,
    showFanout: Boolean = false,
    showBlockConfig: Boolean = false,
    agentOptions: List<String> = STATIC_AGENT_TYPES,
    agentDescriptors: Map<String, AgentDescriptor> = emptyMap(),
    modelCatalogMap: Map<String, List<SessionStore.AgentModel>> = emptyMap(),
    onUpdate: (PipelineStepDraft) -> Unit,
    onDelete: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Step header
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AgentAvatar(assistant = step.agentType, size = 28.dp)
                Spacer(Modifier.width(8.dp))
                Text(
                    "Step ${index + 1}",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                    color = neon.text,
                    modifier = Modifier.weight(1f),
                )
                if (canDelete) {
                    IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = "Delete step",
                            tint = neon.red,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            // Agent type dropdown
            var agentExpanded by remember { mutableStateOf(false) }
            Box {
                OutlinedTextField(
                    value = step.agentType,
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Agent type") },
                    modifier = Modifier.fillMaxWidth().clickable { agentExpanded = true },
                    enabled = false,
                )
                DropdownMenu(
                    expanded = agentExpanded,
                    onDismissRequest = { agentExpanded = false },
                ) {
                    agentOptions.forEach { agent ->
                        DropdownMenuItem(
                            text = { Text(agent, fontFamily = neon.mono) },
                            onClick = {
                                onUpdate(step.copy(agentType = agent))
                                agentExpanded = false
                            },
                        )
                    }
                }
            }

            // Per-block config (model / effort / permission mode /
            // instructions), gated on pipeline_block_config so an old
            // broker never sees controls it would silently drop.
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

            // Role preset dropdown
            var roleExpanded by remember { mutableStateOf(false) }
            Box {
                OutlinedTextField(
                    value = step.role,
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Role preset") },
                    modifier = Modifier.fillMaxWidth().clickable { roleExpanded = true },
                    enabled = false,
                )
                DropdownMenu(
                    expanded = roleExpanded,
                    onDismissRequest = { roleExpanded = false },
                ) {
                    ROLE_PRESETS.forEach { role ->
                        DropdownMenuItem(
                            text = { Text(role, fontFamily = neon.sans) },
                            onClick = {
                                val newPrompt = if (role != "custom") promptForRole(role) else step.promptTemplate
                                onUpdate(step.copy(role = role, promptTemplate = newPrompt))
                                roleExpanded = false
                            },
                        )
                    }
                }
            }

            // Prompt template
            OutlinedTextField(
                value = step.promptTemplate,
                onValueChange = { onUpdate(step.copy(promptTemplate = it)) },
                label = { Text("Prompt template") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )

            // Input from prev chips
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "Input from previous step",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    INPUT_OPTIONS.forEach { option ->
                        val selected = step.inputFromPrev == option
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) neon.accent else neon.surface2)
                                .border(
                                    1.dp,
                                    if (selected) neon.accent else neon.border,
                                    RoundedCornerShape(50),
                                )
                                .clickable { onUpdate(step.copy(inputFromPrev = option)) }
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                        ) {
                            Text(
                                option,
                                fontFamily = neon.mono,
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 11.sp,
                                color = if (selected) neon.accentText else neon.textDim,
                            )
                        }
                    }
                }
            }

            // Gate after switch
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Gate after (require approval)",
                    fontFamily = neon.sans,
                    fontSize = 13.sp,
                    color = neon.text,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = step.gateAfter,
                    onCheckedChange = { onUpdate(step.copy(gateAfter = it)) },
                )
            }

            // Fanout section (gated on pipeline_fanout capability)
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
    }
}

/**
 * Per-block model / reasoning-effort / permission-mode / instructions
 * controls (PLAN-HARNESS-BUILDER Phase 1). Mirrors iOS
 * `blockConfigSection`. Model options come from the assistant's
 * broker-discovered catalog (same store data the fork / new-session pickers
 * consume); the effort and permission-mode rows hide when the resolved
 * model/agent doesn't offer them.
 */
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
    val showModel = !modelRowHidden(agentType, catalog)
    val efforts = catalogEntryFor(model, catalog)?.efforts ?: emptyList()
    val showEffort = efforts.isNotEmpty()
    val showMode = descriptor.supportsPlanMode

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (showModel) {
            var modelExpanded by remember { mutableStateOf(false) }
            Box {
                OutlinedTextField(
                    value = forkModelLabel(model, catalog),
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Model") },
                    modifier = Modifier.fillMaxWidth().clickable { modelExpanded = true },
                    enabled = false,
                )
                DropdownMenu(
                    expanded = modelExpanded,
                    onDismissRequest = { modelExpanded = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("Default", fontFamily = neon.sans) },
                        onClick = {
                            onModelChange("")
                            modelExpanded = false
                        },
                    )
                    catalog?.forEach { m ->
                        if (m.id.isEmpty()) return@forEach
                        DropdownMenuItem(
                            text = { Text(m.displayName.ifEmpty { m.id }, fontFamily = neon.mono) },
                            onClick = {
                                onModelChange(m.id)
                                modelExpanded = false
                            },
                        )
                    }
                }
            }
        }

        if (showEffort) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "REASONING EFFORT",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    (listOf("") + efforts).forEach { level ->
                        val selected = reasoningEffort == level
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) neon.accent else neon.surface2)
                                .border(
                                    1.dp,
                                    if (selected) neon.accent else neon.border,
                                    RoundedCornerShape(50),
                                )
                                .clickable { onEffortChange(level) }
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                        ) {
                            Text(
                                if (level.isEmpty()) "Default" else effortLabel(level),
                                fontFamily = neon.mono,
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 11.sp,
                                color = if (selected) neon.accentText else neon.textDim,
                            )
                        }
                    }
                }
            }
        }

        if (showMode) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "PERMISSION MODE",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("" to "Auto", "plan" to "Plan").forEach { (value, label) ->
                        val selected = permissionMode == value
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) neon.accent else neon.surface2)
                                .border(
                                    1.dp,
                                    if (selected) neon.accent else neon.border,
                                    RoundedCornerShape(50),
                                )
                                .clickable { onModeChange(value) }
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                        ) {
                            Text(
                                label,
                                fontFamily = neon.mono,
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 11.sp,
                                color = if (selected) neon.accentText else neon.textDim,
                            )
                        }
                    }
                }
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
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Fan out this step",
                fontFamily = neon.sans,
                fontSize = 13.sp,
                color = neon.text,
                modifier = Modifier.weight(1f),
            )
            Switch(
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
        }

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
                    var agentExpanded by remember(runIdx) { mutableStateOf(false) }
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
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(neon.surface2)
                                    .border(1.dp, neon.border, RoundedCornerShape(8.dp))
                                    .clickable { agentExpanded = true }
                                    .padding(horizontal = 10.dp, vertical = 8.dp),
                            ) {
                                Text(
                                    currentAgent,
                                    fontFamily = neon.mono,
                                    fontSize = 12.sp,
                                    color = neon.text,
                                )
                            }
                            DropdownMenu(
                                expanded = agentExpanded,
                                onDismissRequest = { agentExpanded = false },
                            ) {
                                agentOptions.forEach { agent ->
                                    DropdownMenuItem(
                                        text = { Text(agent, fontFamily = neon.mono) },
                                        onClick = {
                                            val arr = step.fanoutAgentTypes.toMutableList()
                                            while (arr.size <= runIdx) arr.add(step.agentType)
                                            arr[runIdx] = agent
                                            onUpdate(step.copy(fanoutAgentTypes = arr))
                                            agentExpanded = false
                                        },
                                    )
                                }
                            }
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
    val showModel = !modelRowHidden(runAgent, catalog)
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
                var expanded by remember(runIdx) { mutableStateOf(false) }
                Box {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(neon.surface2)
                            .border(1.dp, neon.border, RoundedCornerShape(8.dp))
                            .clickable { expanded = true }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Model: " + forkModelLabel(model, catalog),
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textDim,
                        )
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(
                            text = { Text("Default", fontFamily = neon.sans) },
                            onClick = {
                                val arr = step.fanoutModels.toMutableList()
                                while (arr.size <= runIdx) arr.add("")
                                arr[runIdx] = ""
                                onUpdate(step.copy(fanoutModels = arr))
                                expanded = false
                            },
                        )
                        catalog?.forEach { m ->
                            if (m.id.isEmpty()) return@forEach
                            DropdownMenuItem(
                                text = { Text(m.displayName.ifEmpty { m.id }, fontFamily = neon.mono) },
                                onClick = {
                                    val arr = step.fanoutModels.toMutableList()
                                    while (arr.size <= runIdx) arr.add("")
                                    arr[runIdx] = m.id
                                    onUpdate(step.copy(fanoutModels = arr))
                                    expanded = false
                                },
                            )
                        }
                    }
                }
            }
            if (showEffort) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    (listOf("") + efforts).forEach { level ->
                        val selected = effort == level
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) neon.accent else neon.surface2)
                                .border(
                                    1.dp,
                                    if (selected) neon.accent else neon.border,
                                    RoundedCornerShape(50),
                                )
                                .clickable {
                                    val arr = step.fanoutReasoningEfforts.toMutableList()
                                    while (arr.size <= runIdx) arr.add("")
                                    arr[runIdx] = level
                                    onUpdate(step.copy(fanoutReasoningEfforts = arr))
                                }
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                        ) {
                            Text(
                                if (level.isEmpty()) "Default" else effortLabel(level),
                                fontFamily = neon.mono,
                                fontSize = 10.sp,
                                color = if (selected) neon.accentText else neon.textDim,
                            )
                        }
                    }
                }
            }
            if (showMode) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("" to "Auto", "plan" to "Plan").forEach { (value, label) ->
                        val selected = mode == value
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(if (selected) neon.accent else neon.surface2)
                                .border(
                                    1.dp,
                                    if (selected) neon.accent else neon.border,
                                    RoundedCornerShape(50),
                                )
                                .clickable {
                                    val arr = step.fanoutPermissionModes.toMutableList()
                                    while (arr.size <= runIdx) arr.add("")
                                    arr[runIdx] = value
                                    onUpdate(step.copy(fanoutPermissionModes = arr))
                                }
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                        ) {
                            Text(
                                label,
                                fontFamily = neon.mono,
                                fontSize = 10.sp,
                                color = if (selected) neon.accentText else neon.textDim,
                            )
                        }
                    }
                }
            }
        }
    }
}
