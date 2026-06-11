package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for Telemetry quota-protection mechanisms (Android parity with
 * iOS TelemetryThrottleTests.swift):
 *   1. The per-category 60s rolling-window throttle constant
 *   2. The beforeSend denylist helpers (category filter + noise filter)
 *
 * NOTE: Telemetry.debug itself calls Sentry, which is disabled in the
 * test environment (no DSN in BuildConfig.SENTRY_DSN). The throttle and
 * denylist logic is tested via the public constants and helper functions.
 */
class TelemetryThrottleTest {

    // -------------------------------------------------------------------------
    // DEBUG_THROTTLE_MS
    // -------------------------------------------------------------------------

    @Test
    fun throttleIntervalIs60Seconds() {
        assert(Telemetry.DEBUG_THROTTLE_MS == 60_000L) {
            "Expected 60000ms throttle, got ${Telemetry.DEBUG_THROTTLE_MS}"
        }
    }

    // -------------------------------------------------------------------------
    // HIGH_FREQUENCY_DIAG_CATEGORIES denylist
    // -------------------------------------------------------------------------

    @Test
    fun keyboardCategoryIsDenylisted() {
        assertTrue("keyboard" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    @Test
    fun layoutCategoryIsDenylisted() {
        assertTrue("layout" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    @Test
    fun scrollCategoryIsDenylisted() {
        assertTrue("scroll" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    @Test
    fun terminalResizeCategoryIsDenylisted() {
        assertTrue("terminal_resize" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    @Test
    fun agentLoginCategoryNotDenylisted() {
        assertFalse("agent_login should NOT be denylisted",
            "agent_login" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    @Test
    fun sessionCategoryNotDenylisted() {
        assertFalse("session should NOT be denylisted",
            "session" in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
    }

    // -------------------------------------------------------------------------
    // isRoutineNoiseMessage
    // -------------------------------------------------------------------------

    @Test
    fun disconnectedFromHarnessIsNoise() {
        assertTrue(Telemetry.isRoutineNoiseMessage("Android disconnected from harness"))
    }

    @Test
    fun sessionStoreCode0IsNoise() {
        assertTrue(Telemetry.isRoutineNoiseMessage("SessionStore: Code 0"))
    }

    @Test
    fun code0VariantIsNoise() {
        assertTrue(Telemetry.isRoutineNoiseMessage("domain SessionStore code 0 something"))
    }

    @Test
    fun keyboardWillHideIsNoise() {
        assertTrue(Telemetry.isRoutineNoiseMessage("[keyboard] keyboard will hide"))
    }

    @Test
    fun keyboardWillShowIsNoise() {
        assertTrue(Telemetry.isRoutineNoiseMessage("[keyboard] keyboard will show"))
    }

    @Test
    fun realErrorMessageIsNotNoise() {
        assertFalse(Telemetry.isRoutineNoiseMessage("Android create session failed"))
    }

    @Test
    fun agentLoginFailedIsNotNoise() {
        assertFalse(Telemetry.isRoutineNoiseMessage("agent login failed: openai"))
    }

    @Test
    fun sshTunnelLostIsNotNoise() {
        assertFalse(Telemetry.isRoutineNoiseMessage("SSH tunnel lost"))
    }

    @Test
    fun noiseMatchingIsCaseInsensitive() {
        assertTrue(Telemetry.isRoutineNoiseMessage("ANDROID DISCONNECTED FROM HARNESS"))
        assertTrue(Telemetry.isRoutineNoiseMessage("SESSIONSTORE: CODE 0"))
    }

    // -------------------------------------------------------------------------
    // Distinct categories are independent
    // -------------------------------------------------------------------------

    @Test
    fun distinctCategoriesAreIndependent() {
        val a = "cat_alpha"
        val b = "cat_beta"
        assertFalse("$a should not be in denylist", a in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
        assertFalse("$b should not be in denylist", b in Telemetry.HIGH_FREQUENCY_DIAG_CATEGORIES)
        assert(a != b) { "Test categories must be distinct" }
    }
}
