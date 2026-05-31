package sh.nikhil.conduit.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.unit.Dp

/**
 * The Conduit brand mark (the terminal-daemon [ConduitMark]) with a subtle,
 * continuous "breathe" — a gentle scale loop so the home header feels alive
 * without the attention-grabbing pulse of the cold-start splash. Mirrors the
 * iOS `ConduitUI.AnimatedBrandMark`; both share the same calm timing
 * (1.0 → 1.03 over 2.2s, ease-in-out, autoreversing) so the wordless brand
 * mark reads the same on both platforms.
 *
 * Distinct on purpose from [AnimatedSplash]'s faster 1.2s "loading" pulse —
 * the splash signals work-in-progress, the header just breathes.
 */
@Composable
fun AnimatedBrandMark(size: Dp, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "brandBreathe")
    val scale by transition.animateFloat(
        initialValue = 1f,
        targetValue = 1.03f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "brandScale",
    )
    ConduitMark(size = size, modifier = modifier.scale(scale))
}
