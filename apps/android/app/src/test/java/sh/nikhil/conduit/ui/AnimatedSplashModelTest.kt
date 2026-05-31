package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.HarnessState

/**
 * Android mirror of the iOS `AnimatedSplashModelTests` from PR #45.
 *
 * Pure JUnit — the model has zero Android / Compose dependencies, so we
 * don't pay for Robolectric here. We defend two things:
 *
 *   1. Timing constants stay in sync with the iOS reference
 *      (`pulsePeriod = 0.6s`, `crossFadeDuration = 0.3s`,
 *      `hardTimeout = 1.5s`). Drift here means the two clients animate
 *      differently on cold-start, which the audit explicitly called
 *      out as a no-go.
 *
 *   2. The dismiss-trigger table matches iOS: only `Disconnected` /
 *      `Connecting` hold the splash; everything else (including
 *      `Failed`) lets it cross-fade so the offline empty-state under
 *      the splash gets a chance to show.
 */
class AnimatedSplashModelTest {

    // ---------- timing constants ----------

    @Test
    fun pulsePeriodMatchesIosReference() {
        // iOS: `AnimatedSplashModel.pulsePeriod = 0.6` (seconds).
        // Half-cycle: 1.0 → 1.05. Auto-reversing, so the full beat is
        // 2 × this = 1.2s, which is also what the audit prescribes.
        assertEquals(600L, AnimatedSplashModel.pulsePeriodMillis)
    }

    @Test
    fun crossFadeDurationMatchesIosReference() {
        // iOS: `AnimatedSplashModel.crossFadeDuration = 0.3` (seconds).
        assertEquals(300L, AnimatedSplashModel.crossFadeDurationMillis)
    }

    @Test
    fun hardTimeoutMatchesIosReference() {
        // iOS: `AnimatedSplashModel.defaultDuration = 1.5` (seconds).
        // The splash must never linger longer than this regardless of
        // broker state.
        assertEquals(1500L, AnimatedSplashModel.hardTimeoutMillis)
    }

    @Test
    fun pulseScaleMatchesIosReference() {
        // iOS: `AnimatedSplashModel.pulseScale = 1.05`.
        assertEquals(1.05f, AnimatedSplashModel.pulseScale, 0.0001f)
    }

    @Test
    fun wordmarkAndCaptionMatchIosCopy() {
        // Two clients, same brand surface — the wordmark is the lower-
        // case kebab repo name, the caption is the single soft string
        // (no spinner) chosen in the audit.
        assertEquals(">conduit", AnimatedSplashModel.wordmark)
        assertEquals("Loading…", AnimatedSplashModel.loadingCaption)
    }

    // ---------- dismiss trigger table ----------

    @Test
    fun disconnectedHoldsTheSplash() {
        // No signal yet — hold. The splash is also the cold-start
        // affordance, so dismissing on Disconnected would defeat the
        // point.
        assertFalse(AnimatedSplashModel.shouldDismiss(HarnessState.Disconnected))
    }

    @Test
    fun connectingHoldsTheSplash() {
        // Handshake in flight — still hold. We want to dismiss on the
        // *outcome*, not on the in-flight attempt.
        assertFalse(AnimatedSplashModel.shouldDismiss(HarnessState.Connecting))
    }

    @Test
    fun linkedDismisses() {
        // Handshake done — drop the splash so the real UI is visible.
        assertTrue(AnimatedSplashModel.shouldDismiss(HarnessState.Linked))
    }

    @Test
    fun liveDismisses() {
        // At least one round-trip succeeded — definitely dismiss.
        assertTrue(AnimatedSplashModel.shouldDismiss(HarnessState.Live))
    }

    @Test
    fun reconnectingDismisses() {
        // Transient drop with the Rust core auto-retrying — the user
        // already saw the real UI on a prior connect, so dismissing on
        // re-launch + Reconnecting is the right call.
        assertTrue(
            AnimatedSplashModel.shouldDismiss(
                HarnessState.Reconnecting(attempt = 1u, maxAttempts = 5u),
            ),
        )
    }

    @Test
    fun failedDismisses() {
        // Broker is unreachable — drop the splash onto RootView, which
        // owns its own offline empty-state. Holding the splash for the
        // full 1.5s here would just delay the inevitable.
        assertTrue(
            AnimatedSplashModel.shouldDismiss(HarnessState.Failed(reason = "boom")),
        )
    }
}
