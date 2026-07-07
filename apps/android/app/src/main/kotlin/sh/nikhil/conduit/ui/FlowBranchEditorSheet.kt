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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.AgentDot
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.ConduitButton
import sh.nikhil.conduit.ui.components.ConduitCard

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Views/ConduitFlowBranchEditorSheet.swift`.
 * Edits an If/Else control-flow block: maps onto the EXISTING
 * `PipelineStepDraft.kind == "branch"` fields via [PipelineBuilderViewModel]'s
 * sub-stack editing -- same semantics/wire shape as the old builder's
 * control-flow editor, just a fresh layout (no Loop surfaced here).
 */
@Composable
fun FlowBranchEditorSheet(
    viewModel: PipelineBuilderViewModel,
    stepId: String,
    index: Int,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val step = viewModel.steps.getOrNull(index) ?: return
    fun update(transform: (PipelineStepDraft) -> PipelineStepDraft) {
        viewModel.updateStep(stepId, transform(step))
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(neon.bg)) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "New step · If / Else",
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
                    ConditionCard(neon, step) { transform -> update(transform) }
                    ThenSection(neon, viewModel, stepId, step)
                    ElseSection(neon, viewModel, stepId, step)
                }
                // design_handoff_flow audit §D.12: Discard reads as a
                // secondary (red) button at 1:2 width against the primary
                // "Add to flow" -- RowScope.weight expresses the ratio
                // directly (no GeometryReader needed on this platform).
                Row(
                    modifier = Modifier.fillMaxWidth().background(neon.bg).padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(modifier = Modifier.weight(1f)) {
                        ConduitButton(
                            title = "Discard",
                            onClick = {
                                Telemetry.breadcrumb("flow_wizard", "branch_discard", emptyMap())
                                viewModel.removeStep(stepId)
                                onDismiss()
                            },
                            variant = ButtonVariant.Secondary,
                            tint = neon.red,
                        )
                    }
                    Box(modifier = Modifier.weight(2f)) {
                        ConduitButton(title = "Add to flow", onClick = onDismiss, variant = ButtonVariant.Primary, tint = neon.accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun ConditionCard(neon: NeonTheme, step: PipelineStepDraft, update: ((PipelineStepDraft) -> PipelineStepDraft) -> Unit) {
    val isExitStatus = step.branchConditionSource == "exit_status"
    ConduitCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("If", fontFamily = neon.sans, fontSize = 14.sp, color = neon.textDim)
            ConditionMenu(
                neon = neon,
                current = if (isExitStatus) "exit status" else "prev output",
                options = listOf("prev output" to "prev_output", "exit status" to "exit_status"),
                onSelect = { source ->
                    update { s ->
                        val validPredicate = if (source == "exit_status") {
                            if (s.branchConditionPredicate in listOf("succeeded", "failed")) s.branchConditionPredicate else "succeeded"
                        } else {
                            if (s.branchConditionPredicate in listOf("contains", "not_contains", "matches")) s.branchConditionPredicate else "contains"
                        }
                        s.copy(branchConditionSource = source, branchConditionPredicate = validPredicate)
                    }
                },
            )
            if (isExitStatus) {
                ConditionMenu(
                    neon = neon,
                    current = step.branchConditionPredicate,
                    options = listOf("succeeded" to "succeeded", "failed" to "failed"),
                    onSelect = { p -> update { it.copy(branchConditionPredicate = p) } },
                )
            } else {
                ConditionMenu(
                    neon = neon,
                    current = step.branchConditionPredicate.replace("_", " "),
                    options = listOf("contains" to "contains", "not contains" to "not_contains", "matches" to "matches"),
                    onSelect = { p -> update { it.copy(branchConditionPredicate = p) } },
                )
            }
        }
        if (!isExitStatus) {
            Spacer(Modifier.height(8.dp))
            // design_handoff_flow BranchSheet line 77 / iOS
            // `ConduitFlowBranchEditorSheet.conditionCard`: dashed `lineSoft`
            // outline + mono text, not a solid Material outline.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .drawBehind {
                        drawRoundRect(
                            color = neon.lineSoft,
                            cornerRadius = CornerRadius(9.dp.toPx(), 9.dp.toPx()),
                            style = Stroke(
                                width = 1.dp.toPx(),
                                pathEffect = PathEffect.dashPathEffect(
                                    floatArrayOf(4.dp.toPx(), 3.dp.toPx()),
                                    0f,
                                ),
                            ),
                        )
                    }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                if (step.branchConditionValue.isEmpty()) {
                    Text("value to match", fontFamily = neon.mono, fontSize = 13.sp, color = neon.textFaint)
                }
                BasicTextField(
                    value = step.branchConditionValue,
                    onValueChange = { v -> update { it.copy(branchConditionValue = v) } },
                    singleLine = true,
                    textStyle = TextStyle(color = neon.text, fontFamily = neon.mono, fontSize = 13.sp),
                    cursorBrush = SolidColor(neon.accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun ConditionMenu(neon: NeonTheme, current: String, options: List<Pair<String, String>>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clickable { expanded = true }
                .background(Color.Transparent)
                .padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(current, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.5.sp, color = neon.accent)
            Icon(Icons.Default.ArrowDropDown, contentDescription = null, tint = neon.accent, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (label, value) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onSelect(value); expanded = false })
            }
        }
    }
}

/** Vertical indent rail behind THEN/ELSE contents -- design_handoff_flow
 *  BranchSheet: a 2dp left rule (green ~27% alpha for THEN, `lineSoft` for
 *  ELSE) ahead of a 12dp indent. Mirrors iOS's
 *  `.overlay(Rectangle()..., alignment: .leading)` treatment. */
private fun Modifier.branchRail(color: Color): Modifier = this
    .drawBehind {
        drawLine(
            color = color,
            start = Offset(1.dp.toPx(), 0f),
            end = Offset(1.dp.toPx(), size.height),
            strokeWidth = 2.dp.toPx(),
        )
    }
    .padding(start = 12.dp)

@Composable
private fun ThenSection(neon: NeonTheme, viewModel: PipelineBuilderViewModel, stepId: String, step: PipelineStepDraft) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(modifier = Modifier.size(7.dp).background(neon.green, CircleShape))
            Text("THEN", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.green)
        }
        Column(
            modifier = Modifier.branchRail(neon.green.copy(alpha = 0.27f)),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            step.branchThen.forEach { sub ->
                SubStepRow(neon, sub) { viewModel.removeSubStep(stepId, PipelineSubStepArm.THEN, sub.id) }
            }
            AddStepGhostButton(neon = neon, tint = neon.green) {
                viewModel.addSubStep(stepId, PipelineSubStepArm.THEN)
                Telemetry.breadcrumb("flow_wizard", "branch_then_add", emptyMap())
            }
        }
    }
}

@Composable
private fun ElseSection(neon: NeonTheme, viewModel: PipelineBuilderViewModel, stepId: String, step: PipelineStepDraft) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(modifier = Modifier.size(7.dp).background(neon.textFaint, CircleShape))
            Text("ELSE — CONTINUE DOWN", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textFaint)
        }
        Column(
            modifier = Modifier.branchRail(neon.lineSoft),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (step.branchElse.isEmpty()) {
                Text(
                    "No else steps — the flow just moves on.",
                    fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint,
                )
            } else {
                step.branchElse.forEach { sub ->
                    SubStepRow(neon, sub) { viewModel.removeSubStep(stepId, PipelineSubStepArm.ELSE_ARM, sub.id) }
                }
            }
            AddStepGhostButton(neon = neon, tint = neon.textDim) {
                viewModel.addSubStep(stepId, PipelineSubStepArm.ELSE_ARM)
                Telemetry.breadcrumb("flow_wizard", "branch_else_add", emptyMap())
            }
        }
    }
}

/** design_handoff_flow audit §D.13: shared ghost-button styling (plus glyph
 *  + label, no fill) for the THEN/ELSE "+ Add step" rows -- THEN reads in
 *  green, ELSE stays faint. */
@Composable
private fun AddStepGhostButton(neon: NeonTheme, tint: Color, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.clickable(onClick = onClick),
    ) {
        Icon(Icons.Default.Add, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
        Text("Add step", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 12.5.sp, color = tint)
    }
}

@Composable
private fun SubStepRow(neon: NeonTheme, sub: PipelineSubStepDraft, onRemove: () -> Unit) {
    ConduitCard(pad = 10.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AgentDot(agent = sub.agentType, size = 28.dp)
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    sub.role.replaceFirstChar { it.uppercase() },
                    fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp, color = neon.text,
                )
                Text(
                    "${sub.agentType} · sees prev output",
                    fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint,
                )
            }
            Icon(
                Icons.Default.RemoveCircle,
                contentDescription = "Remove",
                tint = neon.red.copy(alpha = 0.8f),
                modifier = Modifier.clickable(onClick = onRemove).size(20.dp),
            )
        }
    }
}
