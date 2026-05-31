package sh.nikhil.conduit.state

import android.net.NetworkCapabilities
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A.9 ("reachability-observer") — locks the pure-data state machine that
 * decides when a network transition is reconnect-worthy. Mirror of
 * `apps/ios/Tests/ConduitTests/NetworkReachabilityModelTests.swift`.
 *
 * Two surfaces under test:
 *  1. [NetworkReachabilityObserver.classifyTransition] — the prev→next
 *     reducer SessionStore consults on every status emission. Drift
 *     here means LTE↔Wi-Fi roaming silently regresses.
 *  2. [NetworkReachabilityObserver.classifyCapabilities] — collapses a
 *     [NetworkCapabilities] bag into our coarse [ReachabilityStatus.Interface].
 *
 * Pure JUnit + MockK; no Robolectric, no ConnectivityManager boot. The
 * live callback is exercised implicitly at app launch by [MainActivity].
 */
class NetworkReachabilityModelTest {

    // ---------- Status helpers ----------

    @Test fun unknownIsNotSatisfied() {
        assertFalse(ReachabilityStatus.Unknown.isSatisfied)
        assertNull(ReachabilityStatus.Unknown.activeInterface)
    }

    @Test fun unsatisfiedIsNotSatisfied() {
        assertFalse(ReachabilityStatus.Unsatisfied.isSatisfied)
        assertNull(ReachabilityStatus.Unsatisfied.activeInterface)
    }

    @Test fun satisfiedExposesInterface() {
        val s = ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi)
        assertTrue(s.isSatisfied)
        assertEquals(ReachabilityStatus.Interface.Wifi, s.activeInterface)
    }

    // ---------- Initial subscription (Unknown → *) ----------

    @Test fun firstSatisfiedAfterUnknownDoesNotFire() {
        // ConnectivityManager delivers a "current state" callback shortly
        // after registration. Treating that as a reconnect would dial the
        // server twice at launch — once from connect(), once from the
        // bogus reachable edge. The state machine must swallow the first
        // transition out of Unknown.
        assertNull(
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Unknown,
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
            )
        )
    }

    @Test fun unknownToUnsatisfiedIsSilent() {
        assertNull(
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Unknown,
                ReachabilityStatus.Unsatisfied,
            )
        )
    }

    // ---------- The reconnect-worthy edges ----------

    @Test fun unsatisfiedToSatisfiedEmitsBecameReachable() {
        assertEquals(
            ReachabilityEvent.BecameReachable,
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Unsatisfied,
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
            )
        )
    }

    @Test fun unsatisfiedToSatisfiedCellularEmitsBecameReachable() {
        // Interface doesn't matter on the "came back online" edge.
        assertEquals(
            ReachabilityEvent.BecameReachable,
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Unsatisfied,
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Cellular),
            )
        )
    }

    @Test fun wifiToCellularEmitsInterfaceChanged() {
        // LTE↔Wi-Fi roaming. Socket is bound to the old interface and
        // will silently time out — must drop+redial.
        assertEquals(
            ReachabilityEvent.InterfaceChanged,
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Cellular),
            )
        )
    }

    @Test fun cellularToWifiEmitsInterfaceChanged() {
        assertEquals(
            ReachabilityEvent.InterfaceChanged,
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Cellular),
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
            )
        )
    }

    @Test fun wiredToWifiEmitsInterfaceChanged() {
        assertEquals(
            ReachabilityEvent.InterfaceChanged,
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wired),
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
            )
        )
    }

    // ---------- Quiet edges (no reconnect) ----------

    @Test fun goingOfflineIsSilent() {
        // We don't fire when the network drops — nothing to reconnect
        // to. Rust core's heartbeat handles offline → failed itself.
        assertNull(
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
                ReachabilityStatus.Unsatisfied,
            )
        )
    }

    @Test fun sameInterfaceIsSilent() {
        // Path snapshots repeat — e.g. Wi-Fi router renegotiates DHCP
        // but interface is still Wi-Fi. No reconnect.
        assertNull(
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
                ReachabilityStatus.Satisfied(ReachabilityStatus.Interface.Wifi),
            )
        )
    }

    @Test fun unsatisfiedToUnsatisfiedIsSilent() {
        assertNull(
            NetworkReachabilityObserver.classifyTransition(
                ReachabilityStatus.Unsatisfied,
                ReachabilityStatus.Unsatisfied,
            )
        )
    }

    // ---------- Capability classification ----------

    @Test fun wifiTransportClassifiesAsWifi() {
        val caps = mockk<NetworkCapabilities>()
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) } returns true
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) } returns false
        assertEquals(
            ReachabilityStatus.Interface.Wifi,
            NetworkReachabilityObserver.classifyCapabilities(caps),
        )
    }

    @Test fun cellularTransportClassifiesAsCellular() {
        val caps = mockk<NetworkCapabilities>()
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) } returns true
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) } returns false
        assertEquals(
            ReachabilityStatus.Interface.Cellular,
            NetworkReachabilityObserver.classifyCapabilities(caps),
        )
    }

    @Test fun ethernetTransportClassifiesAsWired() {
        val caps = mockk<NetworkCapabilities>()
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) } returns true
        assertEquals(
            ReachabilityStatus.Interface.Wired,
            NetworkReachabilityObserver.classifyCapabilities(caps),
        )
    }

    @Test fun unknownTransportClassifiesAsOther() {
        val caps = mockk<NetworkCapabilities>()
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) } returns false
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) } returns false
        assertEquals(
            ReachabilityStatus.Interface.Other,
            NetworkReachabilityObserver.classifyCapabilities(caps),
        )
    }

    @Test fun wifiPlusCellularTieGoesToWifi() {
        // The OS-preferred network when both transports are flagged on
        // a single network is almost always Wi-Fi — and our reducer
        // breaks ties Wi-Fi-first to match user intuition.
        val caps = mockk<NetworkCapabilities>()
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) } returns true
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) } returns true
        every { caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) } returns false
        assertEquals(
            ReachabilityStatus.Interface.Wifi,
            NetworkReachabilityObserver.classifyCapabilities(caps),
        )
    }
}
