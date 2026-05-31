package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.R

/**
 * Pure-data description of the cold-start splash — Compose mirror of
 * `apps/ios/Sources/Views/AnimatedSplashModel`. Lifted out of the
 * composable so timing + dismiss-trigger logic can be unit-tested
 * without booting Robolectric / Compose UI.
 *
 * Same shape as [ProjectHeaderModel] / [InSessionBottomBarModel]:
 * the view is dumb, the model is the contract.
 */
object AnimatedSplashModel {
    /** Pulse half-cycle (1.0 → 1.05). Auto-reverses, so full beat = 2× this. */
    const val pulsePeriodMillis: Long = 600L

    /** Cross-fade duration applied when the splash dismisses. */
    const val crossFadeDurationMillis: Long = 300L

    /**
     * Hard timeout — dismiss the splash this long after appearance even
     * if the broker never answers. Keeps the splash from lingering
     * forever when the harness is unreachable.
     */
    const val hardTimeoutMillis: Long = 1500L

    /** Peak scale during the pulse cycle. */
    const val pulseScale: Float = 1.05f

    /** Soft caption shown beneath the wordmark (no spinner). */
    const val loadingCaption: String = "Loading…"

    /** Brand wordmark — matches the iOS copy + the GitHub repo name. */
    const val wordmark: String = ">conduit"

    /**
     * Mirror of `AnimatedSplashModel.shouldDismiss(on:)` on iOS — any
     * terminal-ish [HarnessState] qualifies, including [HarnessState.Failed],
     * so an unreachable harness still drops the user onto the real UI
     * (which has its own offline empty-state) rather than holding the
     * splash for the full timeout.
     */
    fun shouldDismiss(state: HarnessState): Boolean = when (state) {
        is HarnessState.Disconnected, is HarnessState.Connecting -> false
        is HarnessState.Linked,
        is HarnessState.Live,
        is HarnessState.Reconnecting,
        is HarnessState.Failed,
        -> true
    }
}

/**
 * Brief launch splash. Logo scale-pulse via `rememberInfiniteTransition`,
 * subtle copper-tinted "Loading…" caption, cross-fade dismiss via
 * [AnimatedVisibility] with `fadeOut(tween(300))`.
 *
 * Dismisses on whichever fires first:
 *   - the first decisive harness signal ([AnimatedSplashModel.shouldDismiss]
 *     returns true), i.e. we've heard from the broker; OR
 *   - the [AnimatedSplashModel.hardTimeoutMillis] timeout, so the splash
 *     never lingers when the network is gone.
 *
 * [onFinish] is invoked exactly once — the call-site flips a boolean on
 * first event OR timeout, so this is idempotent.
 *
 * Compose mirror of `apps/ios/Sources/Views/AnimatedSplashView.swift`.
 */
@Composable
fun AnimatedSplash(
    harnessState: HarnessState = HarnessState.Disconnected,
    onFinish: () -> Unit,
) {
    var visible by remember { mutableStateOf(true) }
    var finished by remember { mutableStateOf(false) }

    val finish: () -> Unit = {
        if (!finished) {
            finished = true
            visible = false
        }
    }

    // Cross-fade end → notify call site after AnimatedVisibility has
    // run its `fadeOut(tween(300))` envelope.
    LaunchedEffect(visible) {
        if (!visible) {
            delay(AnimatedSplashModel.crossFadeDurationMillis)
            onFinish()
        }
    }

    // Hard timeout — fires regardless of broker state.
    LaunchedEffect(Unit) {
        delay(AnimatedSplashModel.hardTimeoutMillis)
        finish()
    }

    // Broker signal — first decisive HarnessState dismisses the splash.
    LaunchedEffect(harnessState) {
        if (AnimatedSplashModel.shouldDismiss(harnessState)) {
            finish()
        }
    }

    // Center logo scale-pulse 1.0 → 1.05 → 1.0, looping forever.
    val pulseTransition = rememberInfiniteTransition(label = "splash-pulse")
    val pulseScale by pulseTransition.animateFloat(
        initialValue = 1f,
        targetValue = AnimatedSplashModel.pulseScale,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = AnimatedSplashModel.pulsePeriodMillis.toInt(),
                easing = LinearOutSlowInEasing,
            ),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "splash-pulse-scale",
    )

    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(animationSpec = tween(durationMillis = 200)),
        exit = fadeOut(
            animationSpec = tween(
                durationMillis = AnimatedSplashModel.crossFadeDurationMillis.toInt(),
            ),
        ),
    ) {
        // Opaque base UNDER the glass/neon background so the home screen
        // (rendered behind this AnimatedVisibility overlay) can't bleed
        // through and collide with the wordmark / "Loading…" caption.
        Box(modifier = Modifier.fillMaxSize().background(ConduitTheme.background())) {
            GlassAppBackground()
            Column(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                ConduitMark(
                    size = 84.dp,
                    modifier = Modifier.scale(pulseScale),
                )
                Text(
                    AnimatedSplashModel.wordmark,
                    color = ConduitTheme.textPrimary(),
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 36.sp,
                )
                Text(
                    AnimatedSplashModel.loadingCaption,
                    color = LocalNeonTheme.current.accent.copy(alpha = 0.80f),
                    fontWeight = FontWeight.Medium,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}
