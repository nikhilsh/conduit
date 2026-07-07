package sh.nikhil.conduit.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.NeonPalette
import sh.nikhil.conduit.ui.NeonTheme

// ---------------------------------------------------------------------------
// ConduitTaskStatus
// ---------------------------------------------------------------------------

/**
 * Status of a dispatched background task (design handoff session_tasks).
 * Shared with [ConduitTaskRow]; a later Tasks-sheet PR reuses it for the
 * grouped sheet rows, so it lives at file scope (not private).
 */
enum class ConduitTaskStatus { Running, Gate, Done, Error }

// ---------------------------------------------------------------------------
// ConduitTaskSpinner
// ---------------------------------------------------------------------------

/**
 * Calm indeterminate ring for background-task rows -- Android mirror of
 * iOS `ConduitUI.TaskSpinner`. Full-circle track at ~20% tint opacity +
 * a quarter-arc head in the full tint, 1s linear rotation. Freezes (no
 * rotation, static ring + head) when the system animator duration scale
 * is 0 (reduce motion), same pattern as [ConduitWorkingIndicator].
 *
 * @param size        ring diameter. 16dp is the TaskRow default; a future
 *                    RunningPill caller needs 13dp.
 * @param strokeWidth ring stroke width (2dp default).
 * @param tint        ring color. Defaults to `neon.yellow`.
 */
@Composable
fun ConduitTaskSpinner(
    modifier: Modifier = Modifier,
    size: Dp = 16.dp,
    strokeWidth: Dp = 2.dp,
    tint: Color? = null,
) {
    val neon = LocalNeonTheme.current
    val resolvedTint = tint ?: neon.yellow

    val context = LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    val angle = if (reduceMotion) {
        0f
    } else {
        val transition = rememberInfiniteTransition(label = "taskSpin")
        val a by transition.animateFloat(
            initialValue = 0f,
            targetValue = 360f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1000, easing = LinearEasing),
            ),
            label = "taskSpinAngle",
        )
        a
    }

    Box(
        modifier
            .size(size)
            .graphicsLayer { rotationZ = angle }
            .drawBehind {
                val stroke = Stroke(width = strokeWidth.toPx(), cap = StrokeCap.Round)
                // Ring track.
                drawArc(
                    color = resolvedTint.copy(alpha = 0.20f),
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    style = stroke,
                )
                // Quarter-arc head.
                drawArc(
                    color = resolvedTint,
                    startAngle = -90f,
                    sweepAngle = 90f,
                    useCenter = false,
                    style = stroke,
                )
            },
    )
}

// ---------------------------------------------------------------------------
// ConduitTaskRow
// ---------------------------------------------------------------------------

/**
 * Inline collapsed background-task row for the chat transcript -- Android
 * mirror of iOS `ConduitUI.TaskRow` (design handoff session_tasks Sec 1).
 * Card surface, 11dp/13dp padding, leading spinner-or-dot, title, trailing
 * status text + chevron, optional rich tail line.
 *
 * `elapsed` is a preformatted string -- there is no ticker in this PR;
 * callers own re-rendering the row as time passes.
 *
 * @param tail live tail line (rich variant, shown only when non-blank).
 *             Compose's `Text` has no head-ellipsize mode, so [headTruncated]
 *             pre-trims the string, keeping the END visible.
 */
@Composable
fun ConduitTaskRow(
    title: String,
    modifier: Modifier = Modifier,
    status: ConduitTaskStatus = ConduitTaskStatus.Running,
    elapsed: String? = null,
    tail: String? = null,
    onOpen: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val tint = resolveTaskTint(status, neon.yellow, neon.green, neon.red)
    val statusText = resolveTaskStatusText(status, elapsed)
    val borderColor = resolveTaskBorderColor(status, neon.yellow, neon.lineSoft)
    val shape = RoundedCornerShape(14.dp)

    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(neon.surface, shape)
            .border(1.dp, borderColor, shape)
            .clickable(onClick = onOpen)
            .heightIn(min = 44.dp)
            .padding(vertical = 11.dp, horizontal = 13.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (status == ConduitTaskStatus.Running) {
                ConduitTaskSpinner(size = 16.dp, tint = neon.yellow)
            } else {
                val glowing = status == ConduitTaskStatus.Gate && neon.glow
                Box(
                    Modifier
                        .size(8.dp)
                        .then(
                            if (glowing) {
                                Modifier.shadow(
                                    elevation = 4.dp,
                                    shape = CircleShape,
                                    ambientColor = tint,
                                    spotColor = tint,
                                )
                            } else {
                                Modifier
                            },
                        )
                        .clip(CircleShape)
                        .background(tint),
                )
            }
            Text(
                title,
                fontFamily = neon.sans,
                fontSize = 14.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                statusText,
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = tint,
            )
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = neon.textFaint,
                modifier = Modifier.size(14.dp),
            )
        }
        if (!tail.isNullOrEmpty()) {
            Text(
                headTruncated(tail),
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textFaint,
                maxLines = 1,
                overflow = TextOverflow.Clip,
                modifier = Modifier.padding(top = 9.dp, start = 26.dp),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Pure logic helpers (unit-testable without Compose runtime)
// ---------------------------------------------------------------------------

/**
 * Resolve the tint for a [ConduitTaskStatus]: running/gate -> yellow,
 * done -> green, error -> red.
 */
fun resolveTaskTint(status: ConduitTaskStatus, yellow: Color, green: Color, red: Color): Color =
    when (status) {
        ConduitTaskStatus.Running, ConduitTaskStatus.Gate -> yellow
        ConduitTaskStatus.Done -> green
        ConduitTaskStatus.Error -> red
    }

/**
 * Resolve the trailing status label: the preformatted [elapsed] string
 * while running/gated, else "done" / "failed".
 */
fun resolveTaskStatusText(status: ConduitTaskStatus, elapsed: String?): String =
    when (status) {
        ConduitTaskStatus.Running, ConduitTaskStatus.Gate -> elapsed ?: ""
        ConduitTaskStatus.Done -> "done"
        ConduitTaskStatus.Error -> "failed"
    }

/**
 * Resolve the card border: running/gate rows get a yellow border at ~20%
 * opacity, done/error rows fall back to the default hairline ([lineSoft]).
 */
fun resolveTaskBorderColor(status: ConduitTaskStatus, yellow: Color, lineSoft: Color): Color =
    when (status) {
        ConduitTaskStatus.Running, ConduitTaskStatus.Gate -> yellow.copy(alpha = 0.20f)
        ConduitTaskStatus.Done, ConduitTaskStatus.Error -> lineSoft
    }

/**
 * Head-truncate helper: Compose's `Text` has no head-ellipsize mode (only
 * `TextOverflow.Ellipsis`, which truncates the tail), so a live tail line
 * ("$ swift build ... 214/280 files") needs the END kept visible instead.
 * Trims to [maxChars], prefixing an ellipsis when trimmed.
 */
fun headTruncated(text: String, maxChars: Int = 46): String {
    if (text.length <= maxChars) return text
    val keep = (maxChars - 3).coerceAtLeast(0)
    return "..." + text.takeLast(keep)
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun ConduitTaskRowPreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ConduitTaskRow(
                title = "PR B - Start sheet + wizard",
                status = ConduitTaskStatus.Running,
                elapsed = "4m 02s",
                tail = "\$ swift build ... 214/280 files",
            )
            ConduitTaskRow(
                title = "PR A - Flow atoms + home",
                status = ConduitTaskStatus.Running,
                elapsed = "2m 13s",
            )
            ConduitTaskRow(
                title = "PR C - Monitor",
                status = ConduitTaskStatus.Gate,
                elapsed = "6m 10s",
                tail = "waiting on your review",
            )
            ConduitTaskRow(
                title = "Inventory existing pipeline UI",
                status = ConduitTaskStatus.Gate,
                elapsed = "0m 40s",
            )
            ConduitTaskRow(
                title = "PR A - Flow atoms + home",
                status = ConduitTaskStatus.Done,
                tail = "CI green - merged 3m ago",
            )
            ConduitTaskRow(
                title = "Docs sweep - rename to Flow",
                status = ConduitTaskStatus.Done,
            )
            ConduitTaskRow(
                title = "PR D - Broker redeploy",
                status = ConduitTaskStatus.Error,
                tail = "go vet failed - see log",
            )
            ConduitTaskRow(
                title = "PR E - Release tag",
                status = ConduitTaskStatus.Error,
            )
        }
    }
}
