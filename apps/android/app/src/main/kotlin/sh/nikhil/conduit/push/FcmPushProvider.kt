package sh.nikhil.conduit.push

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import sh.nikhil.conduit.Telemetry

/**
 * FCM push provider — fallback when no UnifiedPush distributor is installed.
 *
 * Uses FirebaseMessaging.getInstance().token (Task-based, callbacks on the
 * caller's thread via addOnCompleteListener). FirebaseApp is auto-initialised
 * by the google-services plugin's generated res/values/google-services.xml at
 * app startup; we check for a non-null FirebaseApp before assuming availability.
 *
 * [isAvailable] is true whenever FirebaseApp has been initialised (i.e.
 * google-services.json is present and the plugin ran). This covers both the
 * first cold-start (FirebaseApp.initializeApp was called in Application.onCreate
 * by the auto-init content-provider the SDK injects) and subsequent launches.
 *
 * Priority: [PushProviders.forContext] prefers UnifiedPush when a distributor
 * is installed; FCM is only selected when UP is unavailable.
 */
class FcmPushProvider(private val ctx: Context) : PushProvider {

    override val name: String = "FCM (Google)"
    override val platform: String = "fcm"

    /**
     * True when FirebaseApp has been successfully initialised on this device.
     * google-services.json → plugin-generated res → FirebaseApp auto-init on
     * first app launch. A non-null default app means the JSON was present and
     * processed correctly.
     */
    override val isAvailable: Boolean
        get() = try {
            FirebaseApp.getInstance() != null
        } catch (_: IllegalStateException) {
            // FirebaseApp.getInstance() throws if no default app has been
            // initialised (e.g. google-services.json is missing or the plugin
            // didn't run). Treat as unavailable — same as the old stub.
            false
        }

    /**
     * Fetch the current FCM registration token and deliver it via [onResult].
     * Null means the token is not yet available (first launch, play-services
     * unavailable) — callers should treat null as "pending; retry later".
     *
     * [onNewToken] in [ConduitFcmService] handles automatic re-registration
     * when the token rotates; [requestToken] is only the explicit first fetch.
     */
    override fun requestToken(onResult: (String?) -> Unit) {
        if (!isAvailable) {
            Telemetry.breadcrumb("push", "FCM: FirebaseApp not initialised — unavailable")
            onResult(null)
            return
        }
        Telemetry.breadcrumb("push", "FCM: fetching token")
        FirebaseMessaging.getInstance().token
            .addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    Telemetry.capture(
                        error = task.exception ?: IllegalStateException("FCM token fetch failed"),
                        message = "Android FCM: token fetch failed",
                        tags = mapOf("surface" to "android", "phase" to "fcm_token"),
                    )
                    onResult(null)
                    return@addOnCompleteListener
                }
                val token = task.result
                Telemetry.breadcrumb(
                    "push", "FCM: token fetched",
                    mapOf("hasToken" to (token != null).toString()),
                )
                onResult(token)
            }
    }

    override fun unregisterToken() {
        if (!isAvailable) return
        Telemetry.breadcrumb("push", "FCM: deleting token")
        FirebaseMessaging.getInstance().deleteToken()
            .addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    Telemetry.breadcrumb("push", "FCM: deleteToken failed (best-effort)")
                } else {
                    Telemetry.breadcrumb("push", "FCM: token deleted")
                }
            }
    }
}
