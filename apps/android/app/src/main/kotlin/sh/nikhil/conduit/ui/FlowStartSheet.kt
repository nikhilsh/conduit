package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitNavRow
import sh.nikhil.conduit.ui.components.ConduitButton
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.FlowTopoStep
import sh.nikhil.conduit.ui.components.NeonPillSegment
import sh.nikhil.conduit.ui.components.NeonSegmentedPill
import sh.nikhil.conduit.ui.components.TopoMini
import java.net.HttpURLConnection
import java.net.URL

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Views/ConduitFlowStartSheet.swift`.
 * "Flow" (pipeline v2) redesign, PR B. Single entry point for both a plain
 * new session AND a new flow: a segmented Session/Flow control (default
 * Session) replaces the old separate "New session" / "New pipeline"
 * affordances.
 *
 * Session tab hosts the EXISTING [AgentPickerSheet] unmodified -- it renders
 * its own ModalBottomSheet/Dialog chrome nested inside this one, which reads
 * as two stacked headers (flagged for on-device verification; functionally
 * fine since dismissing either closes this whole overlay).
 */
enum class FlowStartTab { SESSION, FLOW }

data class FlowWizardPrefill(
    val task: String = "",
    val steps: List<PipelineStepDraft>? = null,
    /** 1 = Task screen, 2 = Steps screen. */
    val startStep: Int = 1,
) {
    companion object {
        val Blank = FlowWizardPrefill()
    }
}

data class FlowTemplateOption(
    val id: String,
    val title: String,
    val topoSteps: List<FlowTopoStep>,
    val gateCount: Int,
    val build: () -> FlowWizardPrefill,
)

/** Built-in recipes shown above any user-saved templates. */
fun builtInFlowTemplates(): List<FlowTemplateOption> = listOf(
    FlowTemplateOption(
        id = "builtin.research-design-build",
        title = "Research → Design → Build",
        topoSteps = listOf(
            FlowTopoStep(agent = "claude", gateAfter = false),
            FlowTopoStep(agent = "claude", gateAfter = true),
            FlowTopoStep(agent = "codex", gateAfter = false),
        ),
        gateCount = 1,
        build = {
            FlowWizardPrefill(
                task = "Research, design, and build the change.",
                steps = listOf(
                    PipelineStepDraft(
                        agentType = "claude", role = "researcher",
                        promptTemplate = "Investigate the codebase and summarize findings.",
                        inputFromPrev = "none", gateAfter = false,
                    ),
                    PipelineStepDraft(
                        agentType = "claude", role = "architect",
                        promptTemplate = "Design the implementation. Prior work: {{prev}}",
                        inputFromPrev = "output", gateAfter = true,
                    ),
                    PipelineStepDraft(
                        agentType = "codex", role = "engineer",
                        promptTemplate = "Implement the approved design. Prior work: {{prev}}",
                        inputFromPrev = "output", gateAfter = false,
                    ),
                ),
                startStep = 2,
            )
        },
    ),
    FlowTemplateOption(
        id = "builtin.fix-verify",
        title = "Fix → Verify",
        topoSteps = listOf(
            FlowTopoStep(agent = "codex", gateAfter = false),
            FlowTopoStep(agent = "claude", gateAfter = false),
        ),
        gateCount = 0,
        build = {
            FlowWizardPrefill(
                task = "Fix the reported issue and verify the fix.",
                steps = listOf(
                    PipelineStepDraft(
                        agentType = "codex", role = "engineer",
                        promptTemplate = "Fix the reported issue in the codebase.",
                        inputFromPrev = "none", gateAfter = false,
                    ),
                    PipelineStepDraft(
                        agentType = "claude", role = "custom",
                        promptTemplate = "Verify the fix works and run any existing tests. Prior work: {{prev}}",
                        inputFromPrev = "output", gateAfter = false,
                    ),
                ),
                startStep = 2,
            )
        },
    ),
)

@Composable
fun FlowStartSheet(
    store: SessionStore,
    initialTab: FlowStartTab = FlowStartTab.SESSION,
    onStartWizard: (FlowWizardPrefill) -> Unit,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val pipelineTemplatesEnabled by store.pipelineTemplates.collectAsState()
    val isDemoMode by store.isDemoMode.collectAsState()
    var tab by remember { mutableStateOf(initialTab) }
    var templates by remember { mutableStateOf<List<PipelineTemplateDraft>>(emptyList()) }
    var isLoadingTemplates by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun loadTemplates() {
        // Demo mode is zero-network -- built-in recipes only, saved
        // templates never fetched.
        if (isDemoMode) return
        if (!pipelineTemplatesEnabled || templates.isNotEmpty() || isLoadingTemplates) return
        val base = endpoint.httpBaseUrl ?: return
        isLoadingTemplates = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val conn = (URL("$base/api/pipeline-templates").openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                        connectTimeout = 10_000
                        readTimeout = 20_000
                    }
                    val code = conn.responseCode
                    val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                    val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                    conn.disconnect()
                    text
                }
            }
            isLoadingTemplates = false
            result.onSuccess { raw ->
                val parsed = runCatching {
                    val obj = JSONObject(raw)
                    val arr = obj.optJSONArray("templates")
                    buildList {
                        if (arr != null) {
                            for (i in 0 until arr.length()) add(parsePipelineTemplate(arr.getJSONObject(i)))
                        }
                    }
                }.getOrDefault(emptyList())
                templates = parsed
            }.onFailure { e ->
                Telemetry.breadcrumb("flow_start", "templates_load_error", mapOf("error" to (e.message ?: "")))
            }
        }
    }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        Telemetry.breadcrumb("flow_start", "opened", mapOf("tab" to tab.name))
        if (tab == FlowStartTab.FLOW) loadTemplates()
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Start",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        fontSize = 17.sp,
                        color = neon.text,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = neon.textDim)
                    }
                }
                NeonSegmentedPill(
                    segments = listOf(NeonPillSegment("Session"), NeonPillSegment("Flow")),
                    selected = if (tab == FlowStartTab.SESSION) 0 else 1,
                    onSelect = { i ->
                        tab = if (i == 0) FlowStartTab.SESSION else FlowStartTab.FLOW
                        Telemetry.breadcrumb("flow_start", "tab_switch", mapOf("tab" to tab.name))
                        if (tab == FlowStartTab.FLOW) loadTemplates()
                    },
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )

                if (tab == FlowStartTab.SESSION) {
                    AgentPickerSheet(
                        store = store,
                        onOpenPipelineBuilder = {
                            Telemetry.breadcrumb("flow_start", "session_tab_pipeline_row", emptyMap())
                            onStartWizard(FlowWizardPrefill.Blank)
                            onDismiss()
                        },
                        embedded = true,
                        onDismiss = onDismiss,
                    )
                } else {
                    FlowTab(
                        neon = neon,
                        templates = templates,
                        isLoadingTemplates = isLoadingTemplates,
                        onPick = { prefill ->
                            onStartWizard(prefill)
                            onDismiss()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun FlowTab(
    neon: NeonTheme,
    templates: List<PipelineTemplateDraft>,
    isLoadingTemplates: Boolean,
    onPick: (FlowWizardPrefill) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "START FROM",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                letterSpacing = 0.6.sp,
                color = neon.textFaint,
            )
            builtInFlowTemplates().forEach { option ->
                TemplateCard(neon, option, onClick = { onPick(option.build()) })
            }
            if (isLoadingTemplates) {
                CircularProgressIndicator(modifier = Modifier.padding(vertical = 6.dp), color = neon.accent)
            }
            templates.forEach { tmpl ->
                val option = FlowTemplateOption(
                    id = tmpl.id,
                    title = tmpl.title.ifEmpty { "Untitled flow" },
                    topoSteps = tmpl.steps.map { FlowTopoStep(agent = it.agentType, gateAfter = it.gateAfter) },
                    gateCount = tmpl.steps.count { it.gateAfter },
                    build = { FlowWizardPrefill(task = tmpl.task, steps = tmpl.steps, startStep = 2) },
                )
                TemplateCard(neon, option, onClick = { onPick(option.build()) })
            }

            ConduitCard {
                ConduitNavRow(
                    icon = Icons.Default.Add,
                    title = "Blank flow",
                    subtitle = "define steps yourself",
                    iconTint = neon.accent,
                    onClick = { onPick(FlowWizardPrefill.Blank) },
                )
            }

            Text(
                "A flow chains agents in order — each step sees the last step's work. Add a gate to approve from your phone before the next step runs.",
                fontFamily = neon.sans,
                fontSize = 13.sp,
                color = neon.textFaint,
            )
            Spacer(Modifier.height(76.dp))
        }
        Box(modifier = Modifier.fillMaxWidth().background(neon.bg).padding(horizontal = 16.dp, vertical = 12.dp)) {
            ConduitButton(
                title = "Continue",
                onClick = {
                    Telemetry.breadcrumb("flow_start", "continue_tapped", emptyMap())
                    onPick(FlowWizardPrefill.Blank)
                },
                variant = ButtonVariant.Primary,
                tint = neon.accent,
            )
        }
    }
}

@Composable
private fun TemplateCard(neon: NeonTheme, option: FlowTemplateOption, onClick: () -> Unit) {
    ConduitCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                option.title,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 15.5.sp,
                color = neon.text,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = neon.textDim, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TopoMini(steps = option.topoSteps, size = 20.dp)
            Text(
                "${option.topoSteps.size} steps · ${option.gateCount} gate${if (option.gateCount == 1) "" else "s"}",
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textDim,
            )
        }
    }
}
