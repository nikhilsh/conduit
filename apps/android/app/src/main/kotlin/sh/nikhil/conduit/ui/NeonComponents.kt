package sh.nikhil.conduit.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Shared "Neon Terminal" rendering helpers (PHASE 1). These consume the
 * resolved [NeonTheme] from [LocalNeonTheme] and apply the glow / surface
 * rules encoded there (README §3.5). Compose's shadow APIs are limited
 * (a single blurred drop shadow with ambient/spot tint), so the two-layer
 * CSS box-glow is *approximated*: we project the outer layer as a blurred
 * [Modifier.shadow] and paint the inner layer as a soft [drawBehind] halo.
 * Fidelity gaps vs. the web reference are expected — see the README.
 *
 * Pure (non-composable) decision helpers live at the bottom so the unit
 * tests can pin them without a Compose runtime (NeonComponentsLogicTest).
 */

// region Glow / surface modifiers

/**
 * Approximate the two-layer neon box glow described by [NeonGlowBox]. No-op
 * when [box] is null (glow OFF). The outer layer rides a real elevation
 * shadow tinted to the glow colour; the inner layer is a tighter painted
 * halo behind the content. Radii are already mode-scaled by the resolver
 * (×0.5 in light mode).
 */
fun Modifier.neonGlowBox(box: NeonGlowBox?, shape: Shape): Modifier {
    if (box == null) return this
    return this
        .shadow(
            elevation = box.outer.radiusDp.dp,
            shape = shape,
            ambientColor = box.outer.color,
            spotColor = box.outer.color,
        )
        .drawBehind {
            // Inner halo: a soft fill bleed just outside the content box.
            drawRoundRect(
                color = box.inner.color,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(
                    box.inner.radiusDp.dp.toPx(),
                ),
            )
        }
}

/**
 * The canonical neon card surface: a [fill] background (typically
 * `neon.codeBg` for command/code surfaces or `neon.surface` for chrome),
 * a rounded shape, a 1dp border (red when [failed]), and — depending on
 * the resolved theme — either a glow box (glow ON) or a borderStrong
 * hairline plus the soft light-mode card elevation (glow OFF).
 *
 * Pass [glowTint] non-null to recolor the glow (e.g. state-tinted command
 * cards) instead of the theme's accent glow.
 */
@Composable
fun Modifier.neonCardSurface(
    neon: NeonTheme,
    shape: Shape,
    fill: Color = neon.codeBg,
    borderWidth: Dp = 1.dp,
    borderColor: Color = neon.borderStrong,
    failed: Boolean = false,
    glowTint: Color? = null,
): Modifier {
    val resolvedBorder = if (failed) neon.red.copy(alpha = 0.66f) else borderColor
    // Glow ON → box glow (optionally recolored). Glow OFF → light card
    // elevation only (dark glow-off uses the hairline border, no shadow).
    val box = neon.glowBox?.let { gb ->
        if (glowTint == null) gb else NeonGlowBox(
            inner = NeonShadowLayer(gb.inner.radiusDp, glowTint.copy(alpha = gb.inner.color.alpha)),
            outer = NeonShadowLayer(gb.outer.radiusDp, glowTint.copy(alpha = gb.outer.color.alpha)),
        )
    }
    var m = this
    if (box != null) {
        m = m.neonGlowBox(box, shape)
    } else {
        neon.cardElevation?.let { elev ->
            m = m.shadow(
                elevation = elev.radiusDp.dp,
                shape = shape,
                ambientColor = elev.color,
                spotColor = elev.color,
            )
        }
    }
    return m
        .background(color = fill, shape = shape)
        .border(width = borderWidth, color = resolvedBorder, shape = shape)
}

/**
 * Faint neon grid overlay (thin [NeonTheme.grid] lines). Fills its parent;
 * place beneath content. Lines are ~28dp apart.
 */
@Composable
fun NeonGrid(modifier: Modifier = Modifier, color: Color, cellDp: Float = 28f) {
    Canvas(modifier = modifier.fillMaxSize()) {
        val step = cellDp.dp.toPx()
        if (step <= 0f) return@Canvas
        var x = step
        while (x < size.width) {
            drawLine(
                color = color,
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = 1f,
            )
            x += step
        }
        var y = step
        while (y < size.height) {
            drawLine(
                color = color,
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 1f,
            )
            y += step
        }
    }
}

/**
 * Per-agent neon brand colour, resolved against the active [NeonTheme].
 * Mirrors the chat renderer's agent tinting (claude=claude, codex=codex,
 * hermes=purple, pi=blue, others=accent2) so chrome rows and chat cards
 * agree. Shared so the home list + sheets can tint agent rows without
 * duplicating the map.
 */
fun neonAgentColor(agent: String?, neon: NeonTheme): androidx.compose.ui.graphics.Color =
    when (agent?.lowercase()) {
        "claude" -> neon.claude
        "codex" -> neon.codex
        "hermes" -> neon.purple
        "pi" -> neon.blue
        else -> neon.accent2
    }

// endregion

// region Pure logic (unit-tested)

/** Tool families that drive the §4.5 icon-tile tint + the §4.1 command look. */
enum class NeonToolKind { SEARCH, READ, EDIT, BASH, GENERIC }

/**
 * Map a raw tool name to a [NeonToolKind]. Mirrors the handoff spec's
 * tile tints: search=purple, read=blue, edit=claude, bash=green.
 * Case-insensitive substring match; unknown → [NeonToolKind.GENERIC].
 */
fun neonToolKind(toolName: String?): NeonToolKind {
    val n = toolName?.lowercase()?.trim().orEmpty()
    if (n.isEmpty()) return NeonToolKind.GENERIC
    return when {
        listOf("search", "grep", "glob", "find", "ripgrep", "rg").any { it in n } -> NeonToolKind.SEARCH
        listOf("bash", "sh", "shell", "exec", "run", "command", "terminal", "zsh").any { it in n } -> NeonToolKind.BASH
        listOf("edit", "write", "patch", "apply", "replace", "create").any { it in n } -> NeonToolKind.EDIT
        listOf("read", "cat", "view", "open", "fetch", "ls", "list").any { it in n } -> NeonToolKind.READ
        else -> NeonToolKind.GENERIC
    }
}

/**
 * A tool call should render as the §4.1 COMMAND headline card when its
 * tool name resolves to [NeonToolKind.BASH] *or* it carries a non-blank
 * shell command string. Pure so the renderer + tests agree.
 */
fun isNeonCommandCard(toolName: String?, command: String?): Boolean {
    if (!command.isNullOrBlank()) return true
    return neonToolKind(toolName) == NeonToolKind.BASH
}

/** Parsed `+N / −M` line counts for the §4.4 diff header. */
data class NeonDiffStat(val added: Int, val removed: Int)

/**
 * Extract added/removed line counts for the diff header. Prefers an
 * explicit `diffSummary` string (e.g. "+12 -3", "+12/-3", "12 insertions,
 * 3 deletions"); falls back to counting `+`/`-` body lines (ignoring the
 * `+++`/`---` file markers). Returns null when nothing diff-shaped is
 * present.
 */
fun parseNeonDiffStat(diffSummary: String?, body: String?): NeonDiffStat? {
    diffSummary?.takeIf { it.isNotBlank() }?.let { s ->
        // Match "+12", "-3", "12 insertions", "3 deletions".
        val plus = Regex("""\+\s*(\d+)""").find(s)?.groupValues?.get(1)?.toIntOrNull()
            ?: Regex("""(\d+)\s*(insertion|addition|added)""").find(s.lowercase())
                ?.groupValues?.get(1)?.toIntOrNull()
        val minus = Regex("""[-−]\s*(\d+)""").find(s)?.groupValues?.get(1)?.toIntOrNull()
            ?: Regex("""(\d+)\s*(deletion|removal|removed)""").find(s.lowercase())
                ?.groupValues?.get(1)?.toIntOrNull()
        if (plus != null || minus != null) {
            return NeonDiffStat(plus ?: 0, minus ?: 0)
        }
    }
    if (body.isNullOrBlank()) return null
    var added = 0
    var removed = 0
    body.lineSequence().forEach { raw ->
        when {
            raw.startsWith("+++") || raw.startsWith("---") -> Unit
            raw.startsWith("+") -> added++
            raw.startsWith("-") || raw.startsWith("−") -> removed++
        }
    }
    if (added == 0 && removed == 0) return null
    return NeonDiffStat(added, removed)
}

/**
 * Heuristic for the §4.3 PLAN card: a tool call is plan/todo-shaped when
 * its tool name contains "todo"/"plan" OR its content reads as a
 * checkbox list (`- [ ]` / `- [x]` lines). Pure so the (currently
 * unwired) PlanCard can be gated cleanly without fabricating data.
 */
fun isNeonPlanShaped(toolName: String?, content: String?): Boolean {
    val n = toolName?.lowercase().orEmpty()
    if ("todo" in n || "plan" in n) return true
    val c = content.orEmpty()
    return Regex("""(?m)^\s*[-*]\s*\[[ xX]\]""").containsMatchIn(c)
}

// endregion
