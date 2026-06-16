package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic tests for the chat-shell-v2 experiment + accounts-free
 * onboarding routing (Android mirror of iOS `FeatureFlagsTests`). Runs under
 * plain JUnit — [FeatureFlags] is framework-free.
 */
class FeatureFlagsTest {

    // ── Bucketing ───────────────────────────────────────────────────────

    @Test fun bucketIsDeterministic() {
        assertEquals(FeatureFlags.bucket("device-ABC"), FeatureFlags.bucket("device-ABC"))
    }

    @Test fun bucketSplitsAcrossIds() {
        var sawA = false
        var sawB = false
        for (n in 0 until 200) {
            when (FeatureFlags.bucket("id-$n")) {
                FeatureFlags.ChatArm.A -> sawA = true
                FeatureFlags.ChatArm.B -> sawB = true
            }
        }
        assertTrue(sawA && sawB)
    }

    @Test fun fnv1aMatchesAcrossCalls() {
        assertEquals(FeatureFlags.fnv1a("hello"), FeatureFlags.fnv1a("hello"))
    }

    // ── Resolution ──────────────────────────────────────────────────────
    // Experiment concluded: resolvedChatArm always returns B regardless of
    // preference, kill-switch, or assigned bucket.

    @Test fun resolvedChatArmAlwaysB_auto() {
        assertEquals(
            FeatureFlags.ChatArm.B,
            FeatureFlags.resolvedChatArm(FeatureFlags.ChatStylePreference.Auto, killed = false, assigned = FeatureFlags.ChatArm.B),
        )
    }

    @Test fun resolvedChatArmAlwaysB_preferenceA() {
        assertEquals(
            FeatureFlags.ChatArm.B,
            FeatureFlags.resolvedChatArm(FeatureFlags.ChatStylePreference.A, killed = false, assigned = FeatureFlags.ChatArm.A),
        )
    }

    @Test fun resolvedChatArmAlwaysB_killed() {
        assertEquals(
            FeatureFlags.ChatArm.B,
            FeatureFlags.resolvedChatArm(FeatureFlags.ChatStylePreference.B, killed = true, assigned = FeatureFlags.ChatArm.A),
        )
    }

    // ── Onboarding routing (accounts-free) ──────────────────────────────

    @Test fun routeFullWhenNoBrokerPaired() {
        assertEquals(FeatureFlags.OnboardingRoute.Full, FeatureFlags.onboardingRoute(0, brokerReachable = false))
        assertEquals(FeatureFlags.OnboardingRoute.Full, FeatureFlags.onboardingRoute(0, brokerReachable = true))
    }

    @Test fun routeNoneWhenAnyBrokerPaired() {
        assertEquals(FeatureFlags.OnboardingRoute.None, FeatureFlags.onboardingRoute(1, brokerReachable = false))
        assertEquals(FeatureFlags.OnboardingRoute.None, FeatureFlags.onboardingRoute(2, brokerReachable = true))
    }

    @Test fun fullRouteSkipsWelcomeOnceSeen() {
        assertEquals(FeatureFlags.Step.WELCOME, FeatureFlags.onboardingInitialStep(FeatureFlags.OnboardingRoute.Full, seenWelcome = false, furthestStep = 0))
        assertEquals(FeatureFlags.Step.INSTALL, FeatureFlags.onboardingInitialStep(FeatureFlags.OnboardingRoute.Full, seenWelcome = true, furthestStep = 0))
    }

    @Test fun fullRouteResumesAtFurthest() {
        assertEquals(FeatureFlags.Step.PAIR, FeatureFlags.onboardingInitialStep(FeatureFlags.OnboardingRoute.Full, seenWelcome = true, furthestStep = 2))
    }

    @Test fun noneRouteIsDone() {
        assertEquals(FeatureFlags.Step.DONE, FeatureFlags.onboardingInitialStep(FeatureFlags.OnboardingRoute.None, seenWelcome = true, furthestStep = 0))
    }
}
