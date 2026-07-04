package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConnectionHealth

/**
 * Tests the "assume connected" grace-window derivation (Change 4).
 *
 * When the app foregrounds and the Rust core fires a reconnect cycle within ~5s,
 * [SessionStore.visibleHarness] must stay at the last-known-good state for ~4s so
 * the "Reconnecting..." banner never flickers on a fast reconnect.
 *
 * Timer-tick tests are deliberately avoided: we only test the DERIVATION (suppressed
 * = last good state; unsuppressed = real state) so CI does not flake on sleep timing.
 * Tests that would trigger viewModelScope.launch (the 4s grace expiry timer) use
 * [SessionStore.setSuppressGraceReconnectingForTesting] to activate suppression
 * without launching a coroutine -- keeping these as plain JUnit4 (no Robolectric).
 *
 * Mirror of iOS GraceWindowTests in SessionStoreTests.swift.
 */
class GraceWindowTest {

    /**
     * Default: visibleHarness mirrors harness when no grace window is active.
     * Without a recorded foreground timestamp the grace window cannot activate,
     * so no viewModelScope.launch is triggered.
     */
    @Test
    fun visibleHarnessMirrorsHarnessWithoutGrace() {
        val store = SessionStore()
        val sessionId = "gw-mirror-${java.util.UUID.randomUUID()}"
        // No foregroundedAt set -- grace window cannot activate; no coroutine launched.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 3u))
        // Underlying harness is Reconnecting.
        assertTrue(
            "harness must be Reconnecting after Connecting health event",
            store.harness.value is HarnessState.Reconnecting,
        )
        // suppressGraceReconnecting must be false.
        assertFalse(
            "suppressGraceReconnecting must be false when foreground was not recorded",
            store.suppressGraceReconnecting.value,
        )
        // visibleHarness must equal harness (Reconnecting).
        assertTrue(
            "visibleHarness must be Reconnecting when grace window is inactive",
            store.visibleHarness.value is HarnessState.Reconnecting,
        )
    }

    /**
     * When suppression is active and harness is Reconnecting, visibleHarness returns
     * the last-good state instead.
     *
     * Uses [setSuppressGraceReconnectingForTesting] to activate suppression without
     * triggering viewModelScope.launch (the 4s expiry timer) -- safe in plain JUnit4.
     */
    @Test
    fun graceWindowSuppressesReconnectingWithinWindow() {
        val store = SessionStore()
        val sessionId = "gw-suppress-${java.util.UUID.randomUUID()}"

        // Establish known-good Connected state (sets lastReachableHarness = Linked).
        store.onConnectionHealth(sessionId, ConnectionHealth.Connected)

        // Put harness into Reconnecting WITHOUT foregroundedAt set -- no timer launched.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 3u))
        assertTrue(
            "harness must be Reconnecting after Connecting",
            store.harness.value is HarnessState.Reconnecting,
        )

        // Activate grace window suppression via test seam (avoids viewModelScope.launch).
        store.setSuppressGraceReconnectingForTesting(true)

        // suppression must be active.
        assertTrue(
            "grace window must be suppressing",
            store.suppressGraceReconnecting.value,
        )
        // visibleHarness must NOT be Reconnecting during grace window.
        assertFalse(
            "visibleHarness must NOT be Reconnecting during grace window",
            store.visibleHarness.value is HarnessState.Reconnecting,
        )
    }

    /**
     * Outside the 5s window: no suppression even when foregroundedAt is set.
     * foregroundedAt is 10s in the past so the 5s gate rejects it -- no coroutine.
     */
    @Test
    fun graceWindowDoesNotActivateAfterWindowExpires() {
        val store = SessionStore()
        val sessionId = "gw-expired-${java.util.UUID.randomUUID()}"

        store.onConnectionHealth(sessionId, ConnectionHealth.Connected)
        // Foreground was 10s ago -- outside the 5s gate; viewModelScope.launch skipped.
        store.foregroundedAt = System.currentTimeMillis() - 10_000L

        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 3u))

        assertFalse(
            "grace window must NOT activate when foreground was >5s ago",
            store.suppressGraceReconnecting.value,
        )
        assertTrue(
            "visibleHarness must be Reconnecting when grace window did not activate",
            store.visibleHarness.value is HarnessState.Reconnecting,
        )
    }

    /**
     * Connected clears suppression immediately (reconnect succeeded before grace expiry).
     *
     * Uses [setSuppressGraceReconnectingForTesting] to activate suppression, then
     * calls onConnectionHealth(Connecting) -- the guard !_suppressGraceReconnecting skips
     * the viewModelScope.launch since suppression is already true.
     */
    @Test
    fun graceWindowClearedOnConnected() {
        val store = SessionStore()
        val sessionId = "gw-clear-${java.util.UUID.randomUUID()}"

        // Establish known-good state; then activate suppression via test seam.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connected)
        store.setSuppressGraceReconnectingForTesting(true)
        // Now set harness to Reconnecting -- suppress is already true so the
        // !_suppressGraceReconnecting guard skips viewModelScope.launch.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connecting(1u, 3u))
        assertTrue("precondition: suppression must be active", store.suppressGraceReconnecting.value)

        // Reconnect succeeds -- must clear suppression immediately.
        store.onConnectionHealth(sessionId, ConnectionHealth.Connected)

        assertFalse(
            "Connected must clear grace window suppression immediately",
            store.suppressGraceReconnecting.value,
        )
        assertFalse(
            "visibleHarness must not be Reconnecting after Connected",
            store.visibleHarness.value is HarnessState.Reconnecting,
        )
    }
}
