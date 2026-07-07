package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.PipelineSummary
import sh.nikhil.conduit.ui.neonCardSurface
import kotlin.math.max
import kotlin.math.min

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Components/ConduitFlowCard.swift`.
 * Home-screen presence card for the "Flow" (pipeline v2) redesign --
 * design_handoff_flow/README.md "Screens > 1. Home" + "Components > FlowCard"
 * (flow-proto-screens.jsx). Built on [ConduitChip] + [ConduitButton] + the
 * new [TopoMini] / [GateGlyph] atoms.
 *
 * Input is the EXISTING [PipelineSummary] model (`id, title, state,
 * currentStep, stepCount, created` -- see PipelineListScreen.kt). It
 * carries no per-step agent/gate array, so [TopoMini] here is a graceful
 * DEGRADATION from stepCount/currentStep alone: generic (agent == null)
 * dots, no gate pips. A future PR that threads richer per-step data through
 * `GET /api/pipelines` can upgrade this without changing the call sites.
 */
@Composable
fun FlowCard(
    summary: PipelineSummary,
    modifier: Modifier = Modifier,
    isContinuing: Boolean = false,
    onOpen: () -> Unit = {},
    onContinue: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val state = summary.state
    val isGated = state == "awaiting_gate"
    val isAwaitingPick = state == "awaiting_pick"
    val needsYou = isGated || isAwaitingPick
    val isFailed = state == "failed"
    val isComplete = state == "complete"
    val isCancelled = state == "cancelled"

    val chipTint = when {
        needsYou -> neon.yellow
        isFailed -> neon.red
        isComplete -> neon.accent
        isCancelled -> neon.textFaint
        else -> neon.green
    }
    val chipLabel = when {
        needsYou -> "needs you"
        isFailed -> "failed · step ${summary.currentStep + 1}"
        isComplete -> "done"
        isCancelled -> "cancelled"
        else -> "step ${min(summary.currentStep + 1, max(summary.stepCount, 1))}/${max(summary.stepCount, 1)}"
    }
    val caption = when {
        isGated -> "Step ${summary.currentStep + 1} done · review"
        isAwaitingPick -> "Pick a result to continue"
        isFailed -> "halted — open to inspect"
        isComplete -> "all steps finished"
        isCancelled -> "cancelled"
        state == "step_done" -> "step done"
        state == "pending" -> "queued"
        else -> "running"
    }
    val cardBorder = when {
        needsYou -> neon.yellow.copy(alpha = 0.44f)
        isFailed -> neon.red.copy(alpha = 0.44f)
        else -> neon.lineSoft
    }
    val cardGlowTint: Color? = if (neon.glow && needsYou) neon.yellow else null

    val topoSteps = remember(summary.state, summary.currentStep, summary.stepCount) {
        buildFlowCardTopoSteps(summary, isComplete, needsYou, isFailed, state)
    }

    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, borderColor = cardBorder, glowTint = cardGlowTint)
            .padding(14.dp),
    ) {
        // "Open" tap target is scoped to just the title/topo rows -- NOT a
        // card-wide `clickable` wrapping the whole card, which would
        // swallow the sibling "Review output"/"Continue" button taps
        // (mirrors the iOS #914/#918 nested-tap-target fix).
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    summary.title.ifEmpty { "Flow" },
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.5.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(10.dp))
                ConduitChip(label = chipLabel, tint = chipTint)
            }
            Spacer(Modifier.height(10.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                TopoMini(steps = topoSteps, size = 24.dp)
                Text(
                    caption,
                    fontFamily = neon.mono,
                    fontSize = 11.5.sp,
                    color = neon.textDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        if (needsYou) {
            Spacer(Modifier.height(12.dp))
            if (isGated) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ConduitButton(
                        title = "Review output",
                        onClick = onOpen,
                        modifier = Modifier.weight(1f),
                        variant = ButtonVariant.Secondary,
                    )
                    ConduitButton(
                        title = if (isContinuing) "Continuing..." else "Continue",
                        onClick = onContinue,
                        modifier = Modifier.weight(1f),
                        variant = ButtonVariant.Primary,
                        tint = neon.yellow,
                        enabled = !isContinuing,
                        leadingContent = {
                            if (isContinuing) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    color = neon.accentText,
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                GateGlyph(color = neon.accentText, size = 11.dp)
                            }
                        },
                    )
                }
            } else {
                // awaiting_pick: review-style single button, no inline
                // approve (the pick happens in the monitor).
                ConduitButton(
                    title = "Review",
                    onClick = onOpen,
                    variant = ButtonVariant.Secondary,
                )
            }
        }
    }
}

/**
 * Degrade [TopoMini] from `stepCount`/`currentStep` alone (no per-step
 * agent/gate data in [PipelineSummary]): generic dots, no gate pips.
 * `currentStep` is the step that's DONE/current per the broker's gate
 * semantics (mirrors PipelineMonitorScreen's "paused at a gate step" copy).
 */
private fun buildFlowCardTopoSteps(
    summary: PipelineSummary,
    isComplete: Boolean,
    needsYou: Boolean,
    isFailed: Boolean,
    state: String,
): List<FlowTopoStep> {
    val n = max(summary.stepCount, 1)
    val doneThrough = when {
        isComplete -> n
        needsYou -> summary.currentStep + 1
        else -> summary.currentStep
    }
    return (0 until n).map { i ->
        val status = when {
            isFailed && i == summary.currentStep -> FlowAgentStatus.ERROR
            i < doneThrough -> FlowAgentStatus.DONE
            i == summary.currentStep && (state == "running" || state == "step_done" || state == "pending") ->
                FlowAgentStatus.RUNNING
            else -> FlowAgentStatus.IDLE
        }
        FlowTopoStep(agent = null, status = status, gateAfter = false)
    }
}
