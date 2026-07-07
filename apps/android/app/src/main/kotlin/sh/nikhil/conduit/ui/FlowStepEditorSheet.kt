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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.ConduitToggleRow

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
) {
    val neon = LocalNeonTheme.current
    val agentDescriptors by store.agentDescriptors.collectAsState()
    val modelCatalogMap by store.modelCatalog.collectAsState()
    var advancedExpanded by remember { mutableStateOf(false) }

    val step = viewModel.steps.getOrNull(index) ?: return
    fun update(transform: (PipelineStepDraft) -> PipelineStepDraft) {
        viewModel.updateStep(stepId, transform(step))
    }

    val agentOptions = remember(agentDescriptors) { liveAgentOptions(agentDescriptors) }
    val roleOptions = listOf("researcher" to "Research", "architect" to "Design", "engineer" to "Build", "custom" to "Custom")
    val roleLabel = roleOptions.firstOrNull { it.first == step.role }?.second ?: "Custom"
    val catalog = modelCatalogMap[step.agentType] ?: emptyList()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Step ${index + 1} · $roleLabel",
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
                    // Agent
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SectionLabel(neon, "Agent")
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(2),
                            modifier = Modifier.heightIn(max = 200.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            items(agentOptions) { opt ->
                                AgentTile(neon = neon, label = opt, selected = step.agentType == opt) {
                                    update { it.copy(agentType = opt) }
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
                                    selected = step.role == value,
                                    modifier = Modifier.clickable {
                                        update {
                                            it.copy(
                                                role = value,
                                                promptTemplate = if (value != "custom") rolePromptTemplate(value) else it.promptTemplate,
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
                            value = step.promptTemplate,
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
                        ConduitToggleRow(
                            icon = Icons.Default.Notifications,
                            title = "Pause for my approval",
                            subtitle = "pings your phone to continue",
                            checked = step.gateAfter,
                            onCheckedChange = { checked -> update { it.copy(gateAfter = checked) } },
                            iconTint = neon.yellow,
                        )
                    }

                    // Advanced
                    ConduitCard {
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable { advancedExpanded = !advancedExpanded },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.Tune, contentDescription = null, tint = neon.accent, modifier = Modifier.size(18.dp))
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
                            DropdownRow(
                                neon = neon,
                                label = "Model",
                                current = step.model.ifEmpty { "Default" },
                                options = listOf("Default" to "") + catalog.map { (it.displayName.ifEmpty { it.id }) to it.id },
                                onSelect = { update { s -> s.copy(model = it) } },
                            )
                            DropdownRow(
                                neon = neon,
                                label = "Reasoning",
                                current = if (step.reasoningEffort.isEmpty()) "Default" else effortLabel(step.reasoningEffort),
                                options = listOf("Default" to "") +
                                    (catalogEntryFor(step.model, catalog)?.efforts ?: forkEffortOptions(step.agentType))
                                        .map { effortLabel(it) to it },
                                onSelect = { update { s -> s.copy(reasoningEffort = it) } },
                            )
                            DropdownRow(
                                neon = neon,
                                label = "Permissions",
                                current = if (step.permissionMode == "plan") "Plan" else "Auto",
                                options = listOf("Auto" to "", "Plan" to "plan"),
                                onSelect = { update { s -> s.copy(permissionMode = it) } },
                            )
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

/** Role -> default prompt template (design_handoff_flow README). */
private fun rolePromptTemplate(role: String): String = when (role) {
    "researcher" -> "Investigate the codebase and summarize findings."
    "architect" -> "Design the implementation. Prior work: {{prev}}"
    "engineer" -> "Implement the approved design. Prior work: {{prev}}"
    else -> ""
}

@Composable
private fun SectionLabel(neon: NeonTheme, text: String) {
    Text(text.uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textFaint)
}

@Composable
private fun AgentTile(neon: NeonTheme, label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (selected) neon.accent else androidx.compose.ui.graphics.Color.Transparent,
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
            color = if (selected) neon.accentText else neon.textDim,
        )
    }
}

@Composable
private fun DropdownRow(
    neon: NeonTheme,
    label: String,
    current: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim, modifier = Modifier.weight(1f))
        Box {
            Row(
                modifier = Modifier.clickable { expanded = true },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(current, fontFamily = neon.mono, fontSize = 12.sp, color = neon.text)
                Icon(Icons.Default.ArrowDropDown, contentDescription = null, tint = neon.textDim, modifier = Modifier.size(16.dp))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (optLabel, optValue) ->
                    DropdownMenuItem(text = { Text(optLabel) }, onClick = { onSelect(optValue); expanded = false })
                }
            }
        }
    }
}
