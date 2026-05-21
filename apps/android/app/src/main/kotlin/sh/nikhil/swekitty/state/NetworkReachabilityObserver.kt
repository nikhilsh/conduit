package sh.nikhil.swekitty.state

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Coarse-grained reachability state surfaced by [NetworkReachabilityObserver].
 * SessionStore only ever needs to know "did the network just come back or
 * change interface", so the rich `NetworkCapabilities` is collapsed into
 * four buckets and a single satisfied-with-interface enum. Mirrors the
 * iOS [`ReachabilityStatus`] for cross-platform parity.
 */
sealed class ReachabilityStatus {
    data object Unknown : ReachabilityStatus()
    data object Unsatisfied : ReachabilityStatus()
    data class Satisfied(val iface: Interface) : ReachabilityStatus()

    /**
     * The subset of transport types we care about for the immediate-reconnect
     * heuristic. Anything we don't recognise (VPN-only, loopback, etc.) maps
     * to [Other].
     */
    enum class Interface { Wifi, Cellular, Wired, Other }

    val isSatisfied: Boolean get() = this is Satisfied
    val activeInterface: Interface? get() = (this as? Satisfied)?.iface
}

/**
 * Pure state-machine signal types — emitted as side-effects of
 * [NetworkReachabilityObserver.classifyTransition]. SessionStore turns
 * either edge into a `notifyNetworkChange()` call on the Rust core, which
 * drops the active socket and re-enters the reconnect loop.
 */
enum class ReachabilityEvent {
    /** `Unsatisfied → Satisfied`. Came back online from a dropped state. */
    BecameReachable,

    /**
     * `Satisfied(a) → Satisfied(b)` where `a != b`. Wi-Fi↔LTE roam,
     * hotspot toggle, VPN flap. Existing socket is bound to the old
     * interface and will silently time out without a nudge.
     */
    InterfaceChanged,
}

/**
 * Wraps [ConnectivityManager.NetworkCallback] behind a [StateFlow]<[ReachabilityStatus]>.
 * Owners (the [MainActivity]) keep one instance for the process lifetime; consumers
 * (SessionStore) collect the flow and react to either reconnect-worthy edge with an
 * immediate drop+redial.
 *
 * Why a separate observer instead of inlining the callback inside [SessionStore]?
 * Two reasons:
 *  1. Testability — the pure state machine ([classifyTransition]) has its own
 *     test suite without dragging the Rust core in.
 *  2. Symmetry with iOS — the cross-platform [ReachabilityStatus] vocabulary
 *     stays in lockstep, so a future "tighten the reconnect policy" change
 *     ships in one PR with matching tests on both surfaces.
 */
class NetworkReachabilityObserver(
    private val connectivity: ConnectivityManager,
) {
    private val _status = MutableStateFlow<ReachabilityStatus>(ReachabilityStatus.Unknown)
    val status: StateFlow<ReachabilityStatus> = _status.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        // The lifecycle of a network: onAvailable → (onCapabilitiesChanged)* → onLost.
        // We always re-classify against the *currently* active network rather than
        // trusting the incoming network arg — Android can have multiple networks
        // simultaneously (Wi-Fi + cellular) and we want the OS's preferred one.
        override fun onAvailable(network: Network) {
            recompute()
        }

        override fun onLost(network: Network) {
            recompute()
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            recompute()
        }
    }

    /** Starts observing. Idempotent — safe to call once per instance. */
    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { connectivity.registerNetworkCallback(request, callback) }
        // Seed `status` from the currently-active network so the first user-visible
        // value isn't `Unknown` for the lifetime of the app on platforms where
        // `onAvailable` isn't fired for already-connected networks.
        recompute()
    }

    /** Stops observing. Safe to call from [androidx.lifecycle.ViewModel.onCleared]. */
    fun stop() {
        runCatching { connectivity.unregisterNetworkCallback(callback) }
    }

    private fun recompute() {
        _status.value = classifyActive(connectivity)
    }

    companion object {
        /**
         * Classify the currently-active network into our coarse status. Used
         * internally by the callback and exposed for tests + ad-hoc reads.
         */
        fun classifyActive(cm: ConnectivityManager): ReachabilityStatus {
            val active = cm.activeNetwork ?: return ReachabilityStatus.Unsatisfied
            val caps = cm.getNetworkCapabilities(active) ?: return ReachabilityStatus.Unsatisfied
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                return ReachabilityStatus.Unsatisfied
            }
            return ReachabilityStatus.Satisfied(classifyCapabilities(caps))
        }

        /**
         * Map a [NetworkCapabilities] bag to a single [ReachabilityStatus.Interface].
         * Wi-Fi wins ties (the OS-preferred network when both Wi-Fi + cellular
         * are active is almost always Wi-Fi). Extracted so the state-machine
         * tests can exercise the policy without a live ConnectivityManager.
         */
        fun classifyCapabilities(caps: NetworkCapabilities): ReachabilityStatus.Interface = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> ReachabilityStatus.Interface.Wifi
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> ReachabilityStatus.Interface.Cellular
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> ReachabilityStatus.Interface.Wired
            else -> ReachabilityStatus.Interface.Other
        }

        /**
         * Pure state machine: which (zero or one) [ReachabilityEvent] should
         * fire on a `prev → next` transition. Public so the test suite can
         * pin the policy, and so `SessionStore` can drive the same logic off
         * `status` collection without re-implementing it.
         */
        fun classifyTransition(
            prev: ReachabilityStatus,
            next: ReachabilityStatus,
        ): ReachabilityEvent? = when {
            // First-ever satisfied state after launch isn't a transition
            // worth a reconnect — there's nothing to reconnect yet.
            prev is ReachabilityStatus.Unknown -> null
            // Came back online.
            prev is ReachabilityStatus.Unsatisfied && next is ReachabilityStatus.Satisfied ->
                ReachabilityEvent.BecameReachable
            // Roamed between interfaces.
            prev is ReachabilityStatus.Satisfied
                && next is ReachabilityStatus.Satisfied
                && prev.iface != next.iface ->
                ReachabilityEvent.InterfaceChanged
            // Same satisfied state, went offline, etc. — no reconnect.
            else -> null
        }
    }
}
