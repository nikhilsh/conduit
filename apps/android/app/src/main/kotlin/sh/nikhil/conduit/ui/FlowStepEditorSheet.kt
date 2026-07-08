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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip

/**
 * Which storage a [FlowStepEditorSheet] reads/writes -- a top-level step (by
 * id + rail index) or a branch Then/Else sub-step (design_handoff_review_fixes
 * R1). Mirror of iOS `ConduitUI.FlowStepEditorSheet.Target`.
 */
sealed class FlowStepEditorTarget {
    data class Step(val stepId: String, val index: Int) : FlowStepEditorTarget()
    data class SubStep(val target: SubStepEditTarget) : FlowStepEditorTarget()
}

/**
 * The fields common to `PipelineStepDraft` and `PipelineSubStepDraft` -- the
 * only ones this editor surfaces (agent/role/prompt/gate/model/effort/
 * permission). Sub-steps carry no control-flow/fanout fields, so the editor
 * never needs more than this to back either target.
 */
private data class EditableStepFields(
    val agentType: String,
    val role: String,
    val promptTemplate: String,
    val gateAfter: Boolean,
    val model: String,
    val reasoningEffort: String,
    val permissionMode: String,
)

private fun PipelineStepDraft.editableFields() =
    EditableStepFields(agentType, role, promptTemplate, gateAfter, model, reasoningEffort, permissionMode)

private fun PipelineSubStepDraft.editableFields() =
    EditableStepFields(agentType, role, promptTemplate, gateAfter, model, reasoningEffort, permissionMode)

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Views/ConduitFlowStepEditorSheet.swift`.
 * Edits one agent step (Agent / Role / Prompt / Gate / Advanced). Mutates
 * the wizard's shared [PipelineBuilderViewModel] by index -- same model +
 * `/api/pipeline` wire shape as the old builder's config sheet.
 */
@Composable
fun FlowStepEditorSheet(
    store: SessionStore,
    viewModel: PipelineBuilderViewModel,
    stepId: String,
    index: Int,
    onDismiss: () -> Unit,
) = FlowStepEditorSheet(store, viewModel, FlowStepEditorTarget.Step(stepId, index), onDismiss)

/**
 * design_handoff_review_fixes R1: a branch's Then/Else rows are FULL step
 * cards that open this SAME sheet against a [PipelineSubStepDraft] instead
 * of a top-level step.
 */
@Composable
fun FlowStepEditorSheet(
    store: SessionStore,
    viewModel: PipelineBuilderViewModel,
    subStepTarget: SubStepEditTarget,
    onDismiss: () -> Unit,
) = FlowStepEditorSheet(store, viewModel, FlowStepEditorTarget.SubStep(subStepTarget), onDismiss)

@Composable
private fun FlowStepEditorSheet(
    store: SessionStore,
    viewModel: PipelineBuilderViewModel,
    target: FlowStepEditorTarget,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val agentDescriptors by store.agentDescriptors.collectAsState()
    val modelCatalogMap by store.modelCatalog.collectAsState()
    var advancedExpanded by remember { mutableStateOf(false) }

    val fields: EditableStepFields
    val update: ((EditableStepFields) -> EditableStepFields) -> Unit
    when (target) {
        is FlowStepEditorTarget.Step -> {
            val step = viewModel.steps.getOrNull(target.index) ?: return
            fields = step.editableFields()
            update = { transform ->
                val f = transform(fields)
                viewModel.updateStep(
                    target.stepId,
                    step.copy(
                        agentType = f.agentType, role = f.role, promptTemplate = f.promptTemplate,
                        gateAfter = f.gateAfter, model = f.model, reasoningEffort = f.reasoningEffort,
                        permissionMode = f.permissionMode,
                    ),
                )
            }
        }
        is FlowStepEditorTarget.SubStep -> {
            val t = target.target
            val sub = viewModel.subStep(t.stepId, t.arm, t.subStepId) ?: return
            fields = sub.editableFields()
            update = { transform ->
                val f = transform(fields)
                viewModel.updateSubStep(
                    t.stepId, t.arm,
                    sub.copy(
                        agentType = f.agentType, role = f.role, promptTemplate = f.promptTemplate,
                        gateAfter = f.gateAfter, model = f.model, reasoningEffort = f.reasoningEffort,
                        permissionMode = f.permissionMode,
                    ),
                )
            }
        }
    }

    // Step editor prompt is empty on open -- prefill from the selected role
    // (device feedback: a fresh step opened to role "Engineer" with a blank
    // prompt). "custom" has no canned template, so it's left blank for the
    // user (a fresh branch sub-step already opens with role "custom" per
    // `addSubStep`, so this is a no-op there by construction). Mirror of iOS
    // `FlowStepEditorSheet`'s `.onAppear`.
    LaunchedEffect(target) {
        if (fields.promptTemplate.isEmpty() && fields.role != "custom") {
            update { it.copy(promptTemplate = PipelineStepDraft.defaultPromptTemplate(it.role)) }
        }
    }

    val agentOptions = remember(agentDescriptors) { liveAgentOptions(agentDescriptors) }
    val roleOptions = listOf("researcher" to "Research", "architect" to "Design", "engineer" to "Build", "custom" to "Custom")
    val roleLabel = roleOptions.firstOrNull { it.first == fields.role }?.second ?: "Custom"
    val catalog = modelCatalogMap[fields.agentType] ?: emptyList()
    // Top-level steps read "Step N · Role"; branch sub-steps have no rail
    // position to number, so they read "Step · Role".
    val title = when (target) {
        is FlowStepEditorTarget.Step -> "Step ${target.index + 1} · $roleLabel"
        is FlowStepEditorTarget.SubStep -> "Step · $roleLabel"
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        title,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp,
                        color = neon.text,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = neon.textDim)
                    }
                }
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    // Agent -- single row of equal-width tiles (design_handoff_flow
                    // audit §B.3), NOT a 2-column grid that orphaned a 3rd tile on
                    // its own row. 4+ agents split into two balanced equal-width
                    // rows rather than shrinking to illegibility.
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SectionLabel(neon, "Agent")
                        if (agentOptions.size <= 3) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                agentOptions.forEach { opt ->
                                    AgentTile(neon = neon, label = opt, selected = fields.agentType == opt, modifier = Modifier.weight(1f)) {
                                        update { it.copy(agentType = opt) }
                                    }
                                }
                            }
                        } else {
                            val mid = (agentOptions.size + 1) / 2
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    agentOptions.take(mid).forEach { opt ->
                                        AgentTile(neon = neon, label = opt, selected = fields.agentType == opt, modifier = Modifier.weight(1f)) {
                                            update { it.copy(agentType = opt) }
                                        }
                                    }
                                }
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    agentOptions.drop(mid).forEach { opt ->
                                        AgentTile(neon = neon, label = opt, selected = fields.agentType == opt, modifier = Modifier.weight(1f)) {
                                            update { it.copy(agentType = opt) }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Role
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SectionLabel(neon, "Role")
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            roleOptions.forEach { (value, label) ->
                                ConduitChip(
                                    label = label,
                                    selected = fields.role == value,
                                    modifier = Modifier.clickable {
                                        update {
                                            it.copy(
                                                role = value,
                                                promptTemplate = if (value != "custom") PipelineStepDraft.defaultPromptTemplate(value) else it.promptTemplate,
                                            )
                                        }
                                    },
                                )
                            }
                        }
                    }

                    // Prompt
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SectionLabel(neon, "Prompt")
                        androidx.compose.material3.OutlinedTextField(
                            value = fields.promptTemplate,
                            onValueChange = { update { s -> s.copy(promptTemplate = it) } },
                            modifier = Modifier.fillMaxWidth().heightIn(min = 78.dp),
                            placeholder = { Text("Custom prompt...") },
                        )
                        Text(
                            "{{prev}} = what the step before produced. Prefilled by the role — edit freely.",
                            fontFamily = neon.mono,
                            fontSize = 10.5.sp,
                            color = neon.textFaint,
                        )
                    }

                    // Gate
                    ConduitCard {
                        sh.nikhil.conduit.ui.components.FlowGateToggleRow(
                            title = "Pause for my approval",
                            subtitle = "pings your phone to continue",
                            checked = fields.gateAfter,
                            onCheckedChange = { checked -> update { it.copy(gateAfter = checked) } },
                        )
                    }

                    // Advanced
                    ConduitCard {
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable { advancedExpanded = !advancedExpanded },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.Settings, contentDescription = null, tint = neon.accent, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(10.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Advanced", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = neon.text)
                                Text(
                                    "model · reasoning · permissions",
                                    fontFamily = neon.sans, fontSize = 12.sp, color = neon.textDim,
                                )
                            }
                            Icon(
                                if (advancedExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                                contentDescription = null,
                                tint = neon.textDim,
                            )
                        }
                        if (advancedExpanded) {
                            Spacer(Modifier.height(8.dp))
                            val tint = neonAgentColor(fields.agentType, neon)
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    SectionLabel(neon, "Model")
                                    ModelPickerRow(
                                        assistant = fields.agentType,
                                        model = fields.model,
                                        catalog = catalog.ifEmpty { null },
                                        onSelect = { update { s -> s.copy(model = it) } },
                                    )
                                }
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    SectionLabel(neon, "Reasoning")
                                    OptionPickerRow(
                                        title = "Reasoning",
                                        options = listOf(OptionPickerItem("", "Default")) +
                                            (catalogEntryFor(fields.model, catalog)?.efforts ?: forkEffortOptions(fields.agentType))
                                                .map { OptionPickerItem(it, effortLabel(it)) },
                                        selected = fields.reasoningEffort,
                                        tint = tint,
                                        onSelect = { update { s -> s.copy(reasoningEffort = it) } },
                                    )
                                }
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    SectionLabel(neon, "Permissions")
                                    // No separate injected "Default" row: Auto's
                                    // value is already "" (the same sentinel a
                                    // "Default" row would use), so prepending one
                                    // would duplicate the "" row under two labels
                                    // (the R2 dedupe rule).
                                    OptionPickerRow(
                                        title = "Permissions",
                                        options = listOf(OptionPickerItem("", "Auto"), OptionPickerItem("plan", "Plan")),
                                        selected = fields.permissionMode,
                                        tint = tint,
                                        onSelect = { update { s -> s.copy(permissionMode = it) } },
                                    )
                                }
                            }
                        }
                    }

                    // Delete (sub-step mode only) -- design_handoff_review_fixes
                    // R1: the branch row's minus badge is gone, delete now lives
                    // inside the editor. Top-level steps have no delete
                    // affordance here (none existed before this change; the Flow
                    // wizard's step rail doesn't support removing a step yet,
                    // and this PR doesn't add one to avoid a second delete UI).
                    if (target is FlowStepEditorTarget.SubStep) {
                        ConduitCard {
                            Row(
                                modifier = Modifier.fillMaxWidth().clickable {
                                    val t = target.target
                                    Telemetry.breadcrumb("flow_wizard", "sub_step_delete", mapOf("arm" to t.arm.name))
                                    viewModel.removeSubStep(t.stepId, t.arm, t.subStepId)
                                    onDismiss()
                                },
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Default.Delete, contentDescription = null, tint = neon.red, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(10.dp))
                                Text("Delete step", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = neon.text)
                            }
                        }
                    }
                }
                Box(modifier = Modifier.fillMaxWidth().background(neon.bg).padding(horizontal = 16.dp, vertical = 12.dp)) {
                    sh.nikhil.conduit.ui.components.ConduitButton(
                        title = "Done",
                        onClick = onDismiss,
                        variant = sh.nikhil.conduit.ui.components.ButtonVariant.Primary,
                        tint = neon.accent,
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionLabel(neon: NeonTheme, text: String) {
    Text(text.uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textFaint)
}

@Composable
private fun AgentTile(neon: NeonTheme, label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    // Design C1 (design_handoff_flow README screen 5 / flow-proto-editors.jsx):
    // selected = per-agent tint at a soft fill + a ~40%-tint border + label
    // in the agent's own tint -- NOT a solid `neon.accent` pill (device
    // feedback: iOS's mirror rendered a flat cyan pill with black text,
    // unrelated to the agent picked; Android had the same bug). Unselected
    // stays a neutral surface with a hairline border.
    val tint = neonAgentColor(label, neon)
    Row(
        modifier = modifier
            .background(
                if (selected) tint.copy(alpha = 0.11f) else neon.surface,
                RoundedCornerShape(12.dp),
            )
            .border(
                1.dp,
                if (selected) tint.copy(alpha = 0.4f) else neon.lineSoft,
                RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentGlyph(assistant = label, size = 16.dp)
        Spacer(Modifier.width(6.dp))
        Text(
            label,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
            color = if (selected) tint else neon.textDim,
        )
    }
}
