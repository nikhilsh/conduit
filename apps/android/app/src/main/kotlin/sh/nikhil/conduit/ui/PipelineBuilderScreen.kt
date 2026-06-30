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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import java.net.HttpURLConnection
import java.net.URL

/** Mutable builder state for one pipeline step. */
data class PipelineStepDraft(
    val agentType: String = "claude",
    val role: String = "engineer",
    val promptTemplate: String = "",
    val inputFromPrev: String = "none",
    val gateAfter: Boolean = false,
)

private val AGENT_TYPES = listOf("claude", "codex", "opencode")
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
            val stepsJson = JSONArray().apply {
                steps.forEach { step ->
                    put(JSONObject().apply {
                        put("agent_type", step.agentType)
                        put("role", step.role)
                        put("prompt_template", step.promptTemplate)
                        put("input_from_prev", step.inputFromPrev)
                        put("gate_after", step.gateAfter)
                    })
                }
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

            // Start pipeline button
            item {
                val canStart = title.trim().isNotEmpty() && task.trim().isNotEmpty() && !isCreating
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(if (canStart) neon.accent else neon.surface2)
                        .clickable(enabled = canStart, onClick = ::postPipeline)
                        .padding(vertical = 14.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (isCreating) "Starting..." else "Start pipeline",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp,
                        color = if (canStart) neon.accentText else neon.textFaint,
                    )
                }
            }

            item { Spacer(Modifier.height(8.dp)) }
        }
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
                    AGENT_TYPES.forEach { agent ->
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
        }
    }
}
