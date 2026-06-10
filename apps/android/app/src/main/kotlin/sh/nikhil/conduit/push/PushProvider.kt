package sh.nikhil.conduit.push

/**
 * Abstraction for push-token providers.
 *
 * WS-P.3 primary path: UnifiedPush (vendor-free, user's own distributor).
 * WS-P.3 stub path:    FCM (no-op until google-services.json + plugin land).
 *
 * ## FCM enablement steps (for a future operator)
 *
 * 1. Create a Firebase project and add `google-services.json` to
 *    `apps/android/app/`.
 * 2. In `apps/android/build.gradle.kts` (root) add:
 *      `id("com.google.gms.google-services") version "4.4.2" apply false`
 * 3. In `apps/android/app/build.gradle.kts` apply the plugin:
 *      `id("com.google.gms.google-services")`
 * 4. Add the FCM dependency:
 *      `implementation("com.google.firebase:firebase-messaging:24.0.0")`
 * 5. Replace [FcmPushProvider] with a real implementation that calls
 *    `FirebaseMessaging.getInstance().token` and returns it via the callback.
 * 6. Wire [FcmPushProvider] into [PushProviders.forContext] as the active
 *    provider (the interface contract is already in place).
 *
 * The UnifiedPush path requires NO Firebase; FCM is opt-in.
 */
interface PushProvider {
    /**
     * Human-readable name for diagnostics and the Settings row.
     */
    val name: String

    /**
     * Whether this provider is available on this device.
     * UnifiedPush: true when a distributor app is installed.
     * FCM stub:    always false until google-services.json lands.
     */
    val isAvailable: Boolean

    /**
     * The platform string used in `POST /api/push/register`.
     * "unifiedpush" | "fcm" | "apns"
     */
    val platform: String

    /**
     * Request (or retrieve) the push token / endpoint URL.
     * Delivers the token or null to [onResult]. Null means "unavailable"
     * (no distributor, no FCM credentials, etc.).
     */
    fun requestToken(onResult: (String?) -> Unit)

    /**
     * Unregister/revoke the current token (best-effort). Called when the
     * user removes the box or disables notifications.
     */
    fun unregisterToken()
}
