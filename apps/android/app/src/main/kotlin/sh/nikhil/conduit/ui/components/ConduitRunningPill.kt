package sh.nikhil.conduit.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.NeonPalette
import sh.nikhil.conduit.ui.NeonTheme

// ---------------------------------------------------------------------------
// ConduitRunningPill
// ---------------------------------------------------------------------------

/**
 * Persistent capsule above the chat composer showing the live count of
 * background tasks -- Android mirror of iOS `ConduitUI.RunningPill` (design
 * handoff session_tasks Sec 2). Normal: green fill/border, 13dp spinner,
 * mono bold green text, chevron-up. Gated (any task waiting on the user):
 * amber tint + soft glow, text swaps to "N running - M needs you".
 *
 * Visible only while [runningCount] or [gatedCount] is >= 1; appears and
 * disappears with a fade + vertical expand/collapse (no layout jump --
 * reserves no space while hidden). Reduced motion (system animator scale 0)
 * disables the transition entirely, same pattern as [ConduitTaskSpinner].
 */
@Composable
fun ConduitRunningPill(
    runningCount: Int,
    modifier: Modifier = Modifier,
    gatedCount: Int = 0,
    onTap: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val isGated = gatedCount >= 1
    val isVisible = runningCount >= 1 || gatedCount >= 1
    val tint = if (isGated) neon.yellow else neon.green
    val label = runningPillLabel(runningCount, gatedCount)

    val context = LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }
    val animSpec = if (reduceMotion) snap<androidx.compose.ui.unit.IntSize>() else tween(200)
    val fadeSpec = if (reduceMotion) snap<Float>() else tween(200)

    AnimatedVisibility(
        visible = isVisible,
        modifier = modifier,
        enter = fadeIn(fadeSpec) + expandVertically(animSpec),
        exit = fadeOut(fadeSpec) + shrinkVertically(animSpec),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedPillShape)
                .background(tint.copy(alpha = 0.08f), RoundedPillShape)
                .border(1.dp, tint.copy(alpha = 0.27f), RoundedPillShape)
                .then(
                    if (isGated && neon.glow) {
                        Modifier.shadow(
                            elevation = 4.dp,
                            shape = RoundedPillShape,
                            ambientColor = tint.copy(alpha = 0.35f),
                            spotColor = tint.copy(alpha = 0.35f),
                        )
                    } else {
                        Modifier
                    },
                )
                .clickable(onClick = onTap)
                .heightIn(min = 44.dp)
                .padding(vertical = 7.dp, horizontal = 13.dp),
        ) {
            ConduitTaskSpinner(size = 13.dp, tint = tint)
            Text(
                label,
                fontFamily = neon.mono,
                fontSize = 11.5.sp,
                fontWeight = FontWeight.Bold,
                color = tint,
                modifier = Modifier.padding(start = 8.dp, end = 8.dp),
            )
            Icon(
                Icons.Filled.KeyboardArrowUp,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/** Pill radius token (99 per the design handoff -- effectively a capsule). */
private val RoundedPillShape = androidx.compose.foundation.shape.RoundedCornerShape(99.dp)

// ---------------------------------------------------------------------------
// Pure logic helpers (unit-testable without Compose runtime)
// ---------------------------------------------------------------------------

/**
 * Resolve the pill's label text: gated shows "N running - M needs you",
 * otherwise "N running task(s)".
 */
fun runningPillLabel(runningCount: Int, gatedCount: Int): String =
    if (gatedCount >= 1) {
        "$runningCount running · $gatedCount needs you"
    } else {
        "$runningCount running task${if (runningCount == 1) "" else "s"}"
    }

/**
 * Count roster statuses that count as "running" for the pill (currently
 * just "working" -- the broker roster has no "gate" status yet, so
 * gated-count stays a caller-supplied 0 until that lands). Takes the raw
 * `SubagentEntry.status` strings rather than the entry type itself so this
 * stays dependency-free / directly unit-testable.
 */
fun runningTaskCount(statuses: List<String>): Int = statuses.count { it == "working" }

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun ConduitRunningPillNormalOnePreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        androidx.compose.foundation.layout.Box(Modifier.padding(16.dp)) {
            ConduitRunningPill(runningCount = 1)
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun ConduitRunningPillNormalThreePreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        androidx.compose.foundation.layout.Box(Modifier.padding(16.dp)) {
            ConduitRunningPill(runningCount = 3)
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun ConduitRunningPillGatedPreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        androidx.compose.foundation.layout.Box(Modifier.padding(16.dp)) {
            ConduitRunningPill(runningCount = 2, gatedCount = 1)
        }
    }
}
