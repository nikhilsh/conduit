package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.AgentGlyph
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.NeonGlowBox
import sh.nikhil.conduit.ui.NeonShadowLayer
import sh.nikhil.conduit.ui.NeonTheme
import sh.nikhil.conduit.ui.agentAccent
import sh.nikhil.conduit.ui.neonGlowBox

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Components/ConduitFlowAtoms.swift`.
 * New shared atoms for the "Flow" (pipeline v2) redesign home surface --
 * design_handoff_flow/README.md "Components" + px-shared.jsx (AgentDot /
 * GateGlyph / GatePill / TopoMini). Composed purely from existing tokens
 * ([LocalNeonTheme]) + the existing per-agent tint/glyph mapping
 * ([agentAccent] / [AgentGlyph]) -- no new agent enum, no hex literals.
 */

/** Mirror of iOS `AgentDot.Status`. */
enum class FlowAgentStatus { RUNNING, DONE, IDLE, ERROR, LIVE }

/**
 * One step in a [TopoMini] strip. Deliberately minimal -- callers that only
 * have step-count/current-step data (no per-step agent identity) pass
 * `agent = null` and `gateAfter = false` to degrade gracefully (see
 * `FlowCard`).
 */
data class FlowTopoStep(
    val agent: String? = null,
    val status: FlowAgentStatus? = null,
    val gateAfter: Boolean = false,
)

/** Re-tint both glow layers to [color], preserving radius + alpha (mirrors
 *  iOS `NeonGlowBox.tinted(_:)`; Android has no shared helper for this). */
private fun retintGlow(box: NeonGlowBox, color: Color): NeonGlowBox = NeonGlowBox(
    inner = NeonShadowLayer(box.inner.radiusDp, color.copy(alpha = box.inner.color.alpha)),
    outer = NeonShadowLayer(box.outer.radiusDp, color.copy(alpha = box.outer.color.alpha)),
)

/**
 * Small circular agent avatar with an optional status ring. `agent == null`
 * renders a neutral (non-agent-tinted) placeholder dot -- used by `FlowCard`
 * when only step-count data is available, not a per-step agent identity
 * (`PipelineSummary` carries no per-step array).
 */
@Composable
fun AgentDot(
    agent: String?,
    modifier: Modifier = Modifier,
    size: Dp = 30.dp,
    status: FlowAgentStatus? = null,
) {
    val neon = LocalNeonTheme.current
    val tint = agent?.let { agentAccent(it) } ?: neon.textFaint
    val ring = ringColor(status, tint, neon)
    val glows = status == FlowAgentStatus.RUNNING || status == FlowAgentStatus.LIVE
    val shape = CircleShape
    Box(
        modifier = modifier
            .size(size)
            .then(
                if (glows) {
                    Modifier.neonGlowBox(neon.glowBox?.let { retintGlow(it, ring) }, shape)
                } else {
                    Modifier
                },
            )
            .background(tint.copy(alpha = 0.18f), shape)
            .border(1.5.dp, ring, shape),
        contentAlignment = Alignment.Center,
    ) {
        if (agent != null) {
            // Bumped 0.55 -> 0.6 (device feedback: glyphs read too small
            // relative to their tinted-circle container).
            AgentGlyph(assistant = agent, size = size * 0.6f)
        }
    }
}

/** No status -> the agent's own tint at ~33%. With a status, the ring
 *  follows the shared status map (README "Status map"). */
private fun ringColor(status: FlowAgentStatus?, tint: Color, neon: NeonTheme): Color = when (status) {
    null                     -> tint.copy(alpha = 0.33f)
    FlowAgentStatus.RUNNING  -> neon.yellow
    FlowAgentStatus.DONE     -> neon.accent
    FlowAgentStatus.IDLE     -> neon.textFaint
    FlowAgentStatus.ERROR    -> neon.red
    FlowAgentStatus.LIVE     -> neon.green
}

/**
 * Two vertical rounded bars (a "pause" glyph) -- the human-approval
 * checkpoint marker used inline ([TopoMini]) and standalone ([GatePill],
 * gate review cards). Default color is the gate token (`yellow`).
 */
@Composable
fun GateGlyph(
    modifier: Modifier = Modifier,
    color: Color? = null,
    size: Dp = 12.dp,
) {
    val neon = LocalNeonTheme.current
    val c = color ?: neon.yellow
    Row(
        modifier = modifier.size(size),
        horizontalArrangement = Arrangement.spacedBy(size * 0.16f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(2) {
            Box(
                modifier = Modifier
                    .width(size * 0.24f)
                    .height(size * 0.85f)
                    .clip(RoundedCornerShape(size * 0.13f))
                    .background(c),
            )
        }
    }
}

/**
 * Mono uppercase capsule marking a gate boundary (e.g. "GATE — YOU
 * APPROVE" / "APPROVED"). [active] = amber fill/border/glow + amber text;
 * inactive = a faint neutral wash + hairline border + textFaint.
 */
@Composable
fun GatePill(
    label: String,
    modifier: Modifier = Modifier,
    active: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    val fg = if (active) neon.yellow else neon.textFaint
    // Design token: a faint neutral wash for the inactive capsule
    // (rgba(255,255,255,0.05) in the handoff) -- not a brand hex, so it's
    // kept as a plain Color.White opacity rather than a new token (mirrors
    // AgentAvatar's white disc).
    val fill = if (active) neon.yellow.copy(alpha = 0.13f) else Color.White.copy(alpha = 0.05f)
    val border = if (active) neon.yellow.copy(alpha = 0.4f) else neon.lineSoft
    val shape = RoundedCornerShape(percent = 50)
    val glowBox = if (active) neon.glowBox?.let { retintGlow(it, neon.yellow) } else null
    Row(
        modifier = modifier
            .then(if (glowBox != null) Modifier.neonGlowBox(glowBox, shape) else Modifier)
            .clip(shape)
            .background(fill)
            .border(1.dp, border, shape)
            .padding(horizontal = 9.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        GateGlyph(color = if (active) neon.yellow else neon.textFaint, size = 10.dp)
        Text(
            label.uppercase(),
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 10.sp,
            letterSpacing = 0.8.sp,
            color = fg,
            maxLines = 1,
        )
    }
}

/**
 * Horizontal mini topology strip: [AgentDot]s joined by thin connectors
 * (green when the step before is done, else `lineSoft`); a [GateGlyph]
 * splices into the connector where `gateAfter` is set, turning amber only
 * when that gate is the active boundary (the step before is done and the
 * next step is still idle). Sizes 20-26dp.
 */
@Composable
fun TopoMini(
    steps: List<FlowTopoStep>,
    modifier: Modifier = Modifier,
    size: Dp = 24.dp,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        steps.forEachIndexed { i, step ->
            AgentDot(agent = step.agent, size = size, status = step.status)
            if (i < steps.size - 1) {
                val next = steps[i + 1]
                val isDone = step.status == FlowAgentStatus.DONE
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .width(if (step.gateAfter) 6.dp else 14.dp)
                            .height(1.5.dp)
                            .background(if (isDone) neon.green.copy(alpha = 0.55f) else neon.lineSoft),
                    )
                    if (step.gateAfter) {
                        val gateActive = isDone && next.status == FlowAgentStatus.IDLE
                        GateGlyph(color = if (gateActive) neon.yellow else neon.textFaint, size = 11.dp)
                        Box(
                            modifier = Modifier
                                .width(6.dp)
                                .height(1.5.dp)
                                .background(neon.lineSoft),
                        )
                    }
                }
            }
        }
    }
}
