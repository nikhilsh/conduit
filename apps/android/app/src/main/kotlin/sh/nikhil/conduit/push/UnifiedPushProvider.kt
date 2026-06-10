package sh.nikhil.conduit.push

import android.content.Context
import org.unifiedpush.android.connector.UnifiedPush
import sh.nikhil.conduit.Telemetry

/**
 * UnifiedPush provider (vendor-free primary path).
 *
 * The "token" for UnifiedPush IS the distributor-supplied endpoint URL.
 * When a distributor (e.g. the ntfy app) is installed, [requestToken]
 * calls [UnifiedPush.register] and the endpoint is delivered
 * asynchronously via [ConduitUnifiedPushReceiver.onNewEndpoint] →
 * [PushStore.updateEndpoint].
 *
 * [isAvailable] is true when at least one UnifiedPush distributor is
 * installed. If none is installed the Settings row shows an "install ntfy"
 * hint rather than an error.
 */
class UnifiedPushProvider(private val ctx: Context) : PushProvider {

    companion object {
        /** UnifiedPush instance name — identifies this app's registration. */
        private const val UP_INSTANCE = "conduit"
    }

    override val name: String = "UnifiedPush"
    override val isAvailable: Boolean
        get() = UnifiedPush.getDistributors(ctx).isNotEmpty()
    override val platform: String = "unifiedpush"

    override fun requestToken(onResult: (String?) -> Unit) {
        if (!isAvailable) {
            Telemetry.breadcrumb("push", "UP distributor not installed")
            onResult(null)
            return
        }
        Telemetry.breadcrumb("push", "UP register")
        // Registration is asynchronous: the endpoint arrives via
        // ConduitUnifiedPushReceiver.onNewEndpoint. PushStore stores it
        // and POSTs to the broker. We return null here; callers
        // should observe PushStore.registeredEndpointUrl for the real value.
        UnifiedPush.register(ctx, UP_INSTANCE)
        // Return null to indicate "pending — watch for the endpoint callback".
        onResult(null)
    }

    override fun unregisterToken() {
        Telemetry.breadcrumb("push", "UP unregister")
        UnifiedPush.unregister(ctx, UP_INSTANCE)
    }
}
