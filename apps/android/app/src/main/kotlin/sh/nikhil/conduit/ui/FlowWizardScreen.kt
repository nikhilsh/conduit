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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.AgentDot
import sh.nikhil.conduit.ui.components.ConduitButton
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.GatePill
import sh.nikhil.conduit.ui.components.GateGlyph
import java.net.HttpURLConnection
import java.net.URL

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Views/ConduitFlowWizardView.swift`.
 * Two-step wizard (Task, Steps) that replaces `PipelineBuilderScreen` as the
 * phone create UX (tablet keeps the old builder, PR scope §6). Same model +
 * `/api/pipeline` endpoint as the old builder -- a UI reskin, not a new
 * backend.
 */
@Composable
fun FlowWizardScreen(
    store: SessionStore,
    prefill: FlowWizardPrefill,
    onCreated: (pipelineId: String, title: String) -> Unit,
    onBack: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val sessions by store.sessions.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val scope = rememberCoroutineScope()

    val viewModel = remember { PipelineBuilderViewModel(initialSteps = prefill.steps ?: listOf(PipelineStepDraft())) }
    var task by remember { mutableStateOf(prefill.task) }
    var cwd by remember { mutableStateOf(sessions.firstOrNull()?.cwd ?: "") }
    var baseBranch by remember { mutableStateOf("main") }
    var stepIndex by remember { mutableStateOf(prefill.startStep.coerceIn(1, 2)) }

    var configSheetStepId by remember { mutableStateOf<String?>(null) }
    var branchEditStepId by remember { mutableStateOf<String?>(null) }
    var showWhereEditor by remember { mutableStateOf(false) }
    var addStepMenuExpanded by remember { mutableStateOf(false) }
    var showTemplateReplace by remember { mutableStateOf(false) }

    var isCreating by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var chainGuardrailIndices by remember { mutableStateOf<List<Int>>(emptyList()) }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        Telemetry.breadcrumb("flow_wizard", "opened", mapOf("step" to stepIndex.toString()))
    }

    val trimmedTask = task.trim()
    val derivedTitle = if (trimmedTask.isEmpty()) "Flow" else if (trimmedTask.length > 34) trimmedTask.take(34) + "…" else trimmedTask
    val gateCount = viewModel.steps.count { it.gateAfter }

    fun applyBuiltIn(researchDesignBuild: Boolean) {
        Telemetry.breadcrumb("flow_wizard", "template_replace", mapOf("kind" to if (researchDesignBuild) "rdb" else "fixverify"))
        if (researchDesignBuild) {
            viewModel.applyTemplate(
                PipelineTemplateDraft(
                    id = "", title = "", task = "",
                    steps = listOf(
                        PipelineStepDraft(agentType = "claude", role = "researcher",
                            promptTemplate = "Investigate the codebase and summarize findings.",
                            inputFromPrev = "none", gateAfter = false),
                        PipelineStepDraft(agentType = "claude", role = "architect",
                            promptTemplate = "Design the implementation. Prior work: {{prev}}",
                            inputFromPrev = "output", gateAfter = true),
                        PipelineStepDraft(agentType = "codex", role = "engineer",
                            promptTemplate = "Implement the approved design. Prior work: {{prev}}",
                            inputFromPrev = "output", gateAfter = false),
                    ),
                ),
            )
            if (trimmedTask.isEmpty()) task = "Research, design, and build the change."
        } else {
            viewModel.applyTemplate(
                PipelineTemplateDraft(
                    id = "", title = "", task = "",
                    steps = listOf(
                        PipelineStepDraft(agentType = "codex", role = "engineer",
                            promptTemplate = "Fix the reported issue in the codebase.",
                            inputFromPrev = "none", gateAfter = false),
                        PipelineStepDraft(agentType = "claude", role = "custom",
                            promptTemplate = "Verify the fix works and run any existing tests. Prior work: {{prev}}",
                            inputFromPrev = "output", gateAfter = false),
                    ),
                ),
            )
            if (trimmedTask.isEmpty()) task = "Fix the reported issue and verify the fix."
        }
    }

    fun submitFlow() {
        val base = endpoint.httpBaseUrl ?: run {
            errorMessage = "No active endpoint"
            return
        }
        isCreating = true
        Telemetry.breadcrumb(
            "flow_wizard", "start_submit",
            mapOf("steps" to viewModel.steps.size.toString(), "gates" to gateCount.toString()),
        )
        scope.launch {
            val body = viewModel.createRequestJson(derivedTitle, trimmedTask, cwd.trim(), baseBranch.trim().ifEmpty { "main" })
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
                    conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                    val code = conn.responseCode
                    val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                    val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                    conn.disconnect()
                    code to JSONObject(text)
                }
            }
            isCreating = false
            result.onSuccess { (code, json) ->
                if (code in 200..299) {
                    val id = json.optString("id", "")
                    Telemetry.breadcrumb("flow_wizard", "start_ok", mapOf("id" to id))
                    onCreated(id, derivedTitle)
                } else {
                    val detail = json.optJSONObject("error")?.optString("message") ?: "HTTP $code"
                    Telemetry.capture(
                        error = Exception("flow create failed"),
                        message = "flow create failed",
                        tags = mapOf("surface" to "android", "phase" to "flow_wizard"),
                        extras = mapOf("status" to code.toString(), "detail" to detail),
                    )
                    errorMessage = detail
                }
            }.onFailure { e ->
                Telemetry.capture(
                    error = e,
                    message = "flow create network error",
                    tags = mapOf("surface" to "android", "phase" to "flow_wizard"),
                )
                errorMessage = e.message ?: "Network error"
            }
        }
    }

    fun attemptStart() {
        val indices = viewModel.unchainedStepIndices()
        if (indices.isNotEmpty()) {
            chainGuardrailIndices = indices
        } else {
            submitFlow()
        }
    }

    Dialog(onDismissRequest = onBack, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onBack) {
                        Text("Cancel", fontFamily = neon.sans, color = neon.textDim)
                    }
                    Spacer(Modifier.weight(1f))
                    Text("New flow", fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = neon.text)
                    Spacer(Modifier.weight(1f))
                    Spacer(Modifier.size(64.dp))
                }
                StepperHeader(neon = neon, step2Active = stepIndex == 2, onBackToTask = { stepIndex = 1 })

                if (stepIndex == 1) {
                    TaskStep(
                        neon = neon,
                        task = task,
                        onTaskChange = { task = it },
                        whereTitle = savedServers.firstOrNull { it.endpoint == endpoint }?.name
                            ?: endpoint.displayHost,
                        cwd = cwd,
                        baseBranch = baseBranch,
                        onWhereClick = { showWhereEditor = true },
                        onNext = {
                            Telemetry.breadcrumb("flow_wizard", "next_tapped", mapOf("task_len" to trimmedTask.length.toString()))
                            stepIndex = 2
                        },
                    )
                } else {
                    StepsStep(
                        neon = neon,
                        viewModel = viewModel,
                        gateCount = gateCount,
                        addStepMenuExpanded = addStepMenuExpanded,
                        onToggleAddStepMenu = { addStepMenuExpanded = it },
                        onUseTemplate = { showTemplateReplace = true },
                        onCardTap = { s ->
                            Telemetry.breadcrumb("flow_wizard", "step_card_tapped", mapOf("kind" to s.kind))
                            if (s.kind == "branch") branchEditStepId = s.id else configSheetStepId = s.id
                        },
                        isCreating = isCreating,
                        onStart = { attemptStart() },
                    )
                }
            }
        }
    }

    if (showWhereEditor) {
        // Reuses the SAME directory/box picker `AgentPickerSheet` uses
        // (`DirectoryStep`'s `directoryOnly` mode -- PR B follow-up):
        // Recent + live browse over `store.listDirectories`, no per-agent
        // model/effort/mode UI. That picker has no branch control of its
        // own, so an inline branch field lives INSIDE this dialog (not on
        // the wizard face) via its `branch`/`onBranchChange` params.
        Dialog(onDismissRequest = { showWhereEditor = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
                Column(modifier = Modifier.fillMaxSize()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Where", fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = neon.text, modifier = Modifier.weight(1f))
                        TextButton(onClick = { showWhereEditor = false }) { Text("Done") }
                    }
                    DirectoryStep(
                        store = store,
                        assistant = "claude",
                        agentTint = neon.accent,
                        directoryOnly = true,
                        branch = baseBranch,
                        onBranchChange = { baseBranch = it },
                        onCreate = { path, _, _, _, _, _ ->
                            cwd = path ?: ""
                            showWhereEditor = false
                        },
                    )
                }
            }
        }
    }

    if (showTemplateReplace) {
        AlertDialog(
            onDismissRequest = { showTemplateReplace = false },
            title = { Text("Use a template") },
            text = {
                Column {
                    Text(
                        "Research → Design → Build",
                        modifier = Modifier.fillMaxWidth().clickable {
                            applyBuiltIn(true)
                            showTemplateReplace = false
                        }.padding(vertical = 12.dp),
                    )
                    Text(
                        "Fix → Verify",
                        modifier = Modifier.fillMaxWidth().clickable {
                            applyBuiltIn(false)
                            showTemplateReplace = false
                        }.padding(vertical = 12.dp),
                    )
                }
            },
            confirmButton = { TextButton(onClick = { showTemplateReplace = false }) { Text("Cancel") } },
        )
    }

    errorMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Error") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { errorMessage = null }) { Text("OK") } },
        )
    }

    if (chainGuardrailIndices.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { chainGuardrailIndices = emptyList() },
            title = { Text("Steps aren't chained") },
            text = { Text("Step${if (chainGuardrailIndices.size == 1) "" else "s"} ${chainGuardrailIndices.joinToString(", ") { (it + 1).toString() }} won't see the previous step's work. Chain them so context carries forward?") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.chainUnchainedSteps()
                    chainGuardrailIndices = emptyList()
                    submitFlow()
                }) { Text("Chain steps") }
            },
            dismissButton = {
                TextButton(onClick = {
                    chainGuardrailIndices = emptyList()
                    submitFlow()
                }) { Text("Start anyway") }
            },
        )
    }

    configSheetStepId?.let { id ->
        val idx = viewModel.steps.indexOfFirst { it.id == id }
        if (idx >= 0) {
            FlowStepEditorSheet(store = store, viewModel = viewModel, stepId = id, index = idx, onDismiss = { configSheetStepId = null })
        }
    }
    branchEditStepId?.let { id ->
        val idx = viewModel.steps.indexOfFirst { it.id == id }
        if (idx >= 0) {
            FlowBranchEditorSheet(viewModel = viewModel, stepId = id, index = idx, onDismiss = { branchEditStepId = null })
        }
    }
}

@Composable
private fun StepperHeader(neon: NeonTheme, step2Active: Boolean, onBackToTask: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (step2Active) {
            Row(
                modifier = Modifier.clickable(onClick = onBackToTask),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.ChevronLeft, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(14.dp))
                Text("1 · TASK", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = neon.textFaint)
            }
        } else {
            Text("1 · TASK", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = neon.accent)
        }
        Text(" · ", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
        Text(
            "2 · STEPS",
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
            color = if (step2Active) neon.accent else neon.textFaint,
        )
    }
}

@Composable
private fun TaskStep(
    neon: NeonTheme,
    task: String,
    onTaskChange: (String) -> Unit,
    whereTitle: String,
    cwd: String,
    baseBranch: String,
    onWhereClick: () -> Unit,
    onNext: () -> Unit,
) {
    val trimmed = task.trim()
    Column(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(
                "What should this flow do?",
                fontFamily = neon.sans,
                fontWeight = FontWeight.Bold,
                fontSize = 28.sp,
                color = neon.text,
            )
            OutlinedTextField(
                value = task,
                onValueChange = onTaskChange,
                placeholder = { Text("Describe the whole job — every step will see this.") },
                modifier = Modifier.fillMaxWidth().heightIn(min = 110.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("WHERE", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textFaint)
                // A custom row (not ConduitNavRow, whose canned subtitle
                // isn't mono) -- box name title, mono "<dir> · <branch>"
                // subtitle, chevron.
                ConduitCard(modifier = Modifier.clickable(onClick = onWhereClick)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Storage, contentDescription = null, tint = neon.green, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(whereTitle, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = neon.text)
                            Text(
                                "${cwd.ifEmpty { "no folder" }} · ${baseBranch.ifEmpty { "main" }}",
                                fontFamily = neon.mono, fontSize = 12.sp, color = neon.textDim, maxLines = 1,
                            )
                        }
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = neon.textDim, modifier = Modifier.size(18.dp))
                    }
                }
            }
            Text(
                "You'll pick the steps next — working dir and branch are prefilled from the box.",
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textFaint,
            )
        }
        Box(modifier = Modifier.fillMaxWidth().background(neon.bg).padding(horizontal = 16.dp, vertical = 12.dp)) {
            ConduitButton(
                title = "Next · choose steps",
                onClick = onNext,
                variant = ButtonVariant.Primary,
                tint = neon.accent,
                enabled = trimmed.isNotEmpty(),
            )
        }
    }
}

@Composable
private fun StepsStep(
    neon: NeonTheme,
    viewModel: PipelineBuilderViewModel,
    gateCount: Int,
    addStepMenuExpanded: Boolean,
    onToggleAddStepMenu: (Boolean) -> Unit,
    onUseTemplate: () -> Unit,
    onCardTap: (PipelineStepDraft) -> Unit,
    isCreating: Boolean,
    onStart: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "STEPS · RUN IN ORDER",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.textFaint,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "Use a template",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.5.sp,
                    color = neon.accent,
                    modifier = Modifier.clickable(onClick = onUseTemplate),
                )
            }

            viewModel.steps.forEachIndexed { i, step ->
                Box(modifier = Modifier.padding(horizontal = 16.dp)) {
                    StepCard(neon = neon, step = step, index = i, onClick = { onCardTap(step) })
                }
                if (i < viewModel.steps.size - 1) {
                    Connector(neon = neon, gateAfter = step.gateAfter)
                }
            }

            AddStepControl(
                neon = neon,
                expanded = addStepMenuExpanded,
                onExpand = { onToggleAddStepMenu(true) },
                onAgentStep = { viewModel.addStep(); onToggleAddStepMenu(false) },
                onBranchStep = { viewModel.addControlFlowStep("branch"); onToggleAddStepMenu(false) },
                onCancel = { onToggleAddStepMenu(false) },
            )
            Spacer(Modifier.height(90.dp))
        }
        Column(
            modifier = Modifier.fillMaxWidth().background(neon.bg).padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (gateCount > 0) {
                    GateGlyph(size = 12.dp)
                }
                val caption = when {
                    gateCount == 0 -> "runs end-to-end — no gates"
                    gateCount == 1 -> "pauses once for your approval"
                    else -> "pauses ${gateCount}× for your approval"
                }
                Text(caption, fontFamily = neon.mono, fontSize = 11.5.sp, color = neon.textDim)
            }
            ConduitButton(title = "Start flow", onClick = onStart, variant = ButtonVariant.Primary, enabled = !isCreating)
        }
    }
}

@Composable
private fun StepCard(neon: NeonTheme, step: PipelineStepDraft, index: Int, onClick: () -> Unit) {
    val roleLabel = when {
        step.kind == "branch" -> "If / Else"
        step.role == "researcher" -> "Research"
        step.role == "architect" -> "Design"
        step.role == "engineer" -> "Build"
        else -> "Custom"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .then(Modifier)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ConduitCard(modifier = Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AgentDot(agent = if (step.kind.isEmpty()) step.agentType else null, size = 34.dp)
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "${index + 1}. $roleLabel",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.5.sp,
                        color = neon.text,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (step.kind.isEmpty()) {
                            ConduitChip(label = step.agentType, tint = agentAccent(step.agentType))
                        } else {
                            ConduitChip(label = "if / else")
                        }
                        Text(
                            if (index == 0) "reads the repo" else "sees step $index",
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textDim,
                        )
                    }
                }
                Icon(Icons.Default.ChevronRight, contentDescription = null, tint = neon.textDim, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
private fun Connector(neon: NeonTheme, gateAfter: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 44.dp, top = 4.dp, bottom = 4.dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(modifier = Modifier.width(1.5.dp).height(28.dp).background(neon.lineSoft))
        if (gateAfter) {
            GatePill(label = "Gate — you approve", active = true)
        } else {
            // design_handoff_flow audit §C.9: the ghost token reads quieter
            // than textFaint for this decorative caption.
            Text("passes work down ↓", fontFamily = neon.mono, fontSize = 11.sp, color = neon.ghost)
        }
    }
}

@Composable
private fun AddStepControl(
    neon: NeonTheme,
    expanded: Boolean,
    onExpand: () -> Unit,
    onAgentStep: () -> Unit,
    onBranchStep: () -> Unit,
    onCancel: () -> Unit,
) {
    if (expanded) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PillChoice(neon, "Agent step", accent = true, onClick = onAgentStep)
            PillChoice(neon, "If / Else", accent = true, onClick = onBranchStep)
            PillChoice(neon, "Cancel", accent = false, onClick = onCancel)
        }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onExpand).padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Add, contentDescription = null, tint = neon.accent, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text("Add step", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.accent)
        }
    }
}

/** design_handoff_flow audit §C.7: the two committing choices ("Agent step" /
 *  "If / Else") read as accent-tinted pills; "Cancel" stays a neutral
 *  hairline pill. */
@Composable
private fun PillChoice(neon: NeonTheme, label: String, accent: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier = Modifier
            .background(if (accent) neon.accent.copy(alpha = 0.08f) else Color.Transparent, shape)
            .border(1.dp, if (accent) neon.accent.copy(alpha = 0.4f) else neon.lineSoft, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(
            label,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.5.sp,
            color = if (accent) neon.accent else neon.textFaint,
        )
    }
}
