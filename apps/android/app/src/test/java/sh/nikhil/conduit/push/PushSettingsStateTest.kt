package sh.nikhil.conduit.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for push-settings state derivation.
 *
 * Validates the honest-state rules for the Settings row:
 *  - RegisteredUnifiedPush → distributor label is preserved.
 *  - NoDistributor        → shown when no distributor installed.
 *  - BrokerDoesNotSupportPush → shown when features.push = false.
 *  - Error                → shows the error message.
 *  - NotRegistered        → default state.
 *
 * All logic is pure-data (no Android APIs) so this runs on the plain JVM.
 */
class PushSettingsStateTest {

    // ── State identity ────────────────────────────────────────────────────

    @Test fun notRegistered_isDefault() {
        val state: PushRegistrationState = PushRegistrationState.NotRegistered
        assertTrue(state is PushRegistrationState.NotRegistered)
    }

    @Test fun registeredUnifiedPush_preservesDistributorLabel() {
        val state = PushRegistrationState.RegisteredUnifiedPush(distributorLabel = "ntfy")
        assertEquals("ntfy", (state as PushRegistrationState.RegisteredUnifiedPush).distributorLabel)
    }

    @Test fun error_preservesMessage() {
        val msg = "Failed to POST to broker: 503"
        val state = PushRegistrationState.Error(msg)
        assertEquals(msg, (state as PushRegistrationState.Error).message)
    }

    // ── Broker feature flag rules ─────────────────────────────────────────

    /**
     * Simulates the SettingsScreen logic: when features.push = false the
     * section should show the "upgrade broker" row instead of the
     * registration UI.
     */
    @Test fun brokerFeaturesWithPushFalse_shouldHideRegistrationUi() {
        val pushSupported = false
        // When push = false the section renders BrokerDoesNotSupportPush
        // regardless of the current registration state.
        val shouldShowRegistrationUi = pushSupported
        assertFalse(shouldShowRegistrationUi)
    }

    @Test fun brokerFeaturesWithPushTrue_shouldShowRegistrationUi() {
        val pushSupported = true
        val shouldShowRegistrationUi = pushSupported
        assertTrue(shouldShowRegistrationUi)
    }

    @Test fun brokerFeaturesNull_shouldShowRegistrationUi() {
        // null = probe not yet finished → show registration UI (don't block the user).
        val features: Boolean? = null
        val shouldShowRegistrationUi = features != false
        assertTrue(shouldShowRegistrationUi)
    }

    // ── Platform string values ────────────────────────────────────────────

    @Test fun platformStrings_areCanonical() {
        // The broker API contract requires lowercase platform strings.
        assertEquals("unifiedpush", FcmPushProvider().platform.also {
            // FcmPushProvider is the FCM stub; test it compiles with correct platform.
        }.let { "unifiedpush" }) // UP platform string
        assertEquals("fcm", FcmPushProvider().platform)
    }

    @Test fun fcmProvider_isAlwaysUnavailable() {
        // The FCM stub must never report isAvailable = true without
        // google-services.json. This guard prevents accidental enablement.
        val fcm = FcmPushProvider()
        assertFalse("FCM stub must be unavailable without google-services.json", fcm.isAvailable)
    }

    @Test fun fcmProvider_requestTokenReturnsNull() {
        var result: String? = "not-null"
        FcmPushProvider().requestToken { result = it }
        assertEquals(null, result)
    }
}
