package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Pins the SSH-tunnel transport lifecycle state on [SessionStore] (core
 * #451). The live tunnel (russh session + loopback forward) can only be
 * exercised on a device against a real box, so this covers the pure,
 * off-device-observable invariant: a fresh store reports NO tunnel loss.
 *
 * `sshTunnelLost` only flips when a held tunnel's `isAlive()` returns false;
 * with no tunnel held (the unit-test classpath, and every token-paired
 * `conduit://` box) it must stay false so the "connection lost — reconnect"
 * affordance never spuriously appears.
 */
class SessionStoreSshTunnelTest {

    @Test
    fun freshStoreReportsNoTunnelLoss() {
        val store = SessionStore()
        assertFalse(store.sshTunnelLost.value)
    }
}
