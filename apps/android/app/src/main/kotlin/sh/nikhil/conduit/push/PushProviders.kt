package sh.nikhil.conduit.push

import android.content.Context
import org.unifiedpush.android.connector.UnifiedPush

/**
 * Factory for the active [PushProvider].
 *
 * Priority:
 *   1. UnifiedPush — if a distributor is installed (vendor-free).
 *   2. FCM          — stub, always unavailable until google-services.json lands.
 *   3. null          — no push available (box shows honest "unsupported" state).
 *
 * This is the only place that knows which provider wins. Both the
 * registration flow and the Settings row use this to decide what to show.
 */
object PushProviders {

    /**
     * Return the best available provider for this device, or null when
     * nothing is configured. Callers should check [PushProvider.isAvailable]
     * before attempting registration.
     */
    fun forContext(ctx: Context): PushProvider? {
        val up = UnifiedPushProvider(ctx)
        if (up.isAvailable) return up

        val fcm = FcmPushProvider()
        if (fcm.isAvailable) return fcm

        return null
    }

    /**
     * True when at least one UnifiedPush distributor is installed.
     * Used by the Settings row to show the "install ntfy" hint path.
     */
    fun hasUnifiedPushDistributor(ctx: Context): Boolean =
        UnifiedPush.getDistributors(ctx).isNotEmpty()
}
