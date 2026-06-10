package sh.nikhil.conduit.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONException
import org.json.JSONObject
import org.unifiedpush.android.connector.MessagingReceiver
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import sh.nikhil.conduit.MainActivity
import sh.nikhil.conduit.R
import sh.nikhil.conduit.Telemetry
import kotlin.random.Random

/**
 * Receives UnifiedPush events (new endpoint, message, unregistered).
 *
 * Registered in AndroidManifest.xml. The distributor app (e.g. ntfy) calls
 * these methods when the endpoint URL changes or when a push payload arrives.
 *
 * Uses the UnifiedPush android-connector v3.x API:
 *   - onNewEndpoint(Context, PushEndpoint, instance): PushEndpoint.url is the
 *     distributor-assigned URL.
 *   - onMessage(Context, PushMessage, instance): PushMessage.content is the
 *     decrypted message bytes.
 *   - onUnregistered(Context, instance)
 *
 * Notification channel: "conduit-agent" (shown in system Settings as
 * "Agent activity").
 *
 * Deep-link on tap: MainActivity receives an ACTION_VIEW intent carrying
 * `session_id` as an extra; [MainActivity.handlePushIntent] routes to the
 * correct session via [sh.nikhil.conduit.SessionStore.select].
 */
class ConduitUnifiedPushReceiver : MessagingReceiver() {

    companion object {
        const val CHANNEL_ID = "conduit-agent"
        const val EXTRA_SESSION_ID = "session_id"
    }

    // ── UnifiedPush callbacks ─────────────────────────────────────────────

    /**
     * Called when the distributor assigns or rotates the endpoint URL.
     * [PushEndpoint.url] is the full distributor-assigned HTTP POST target.
     */
    override fun onNewEndpoint(context: Context, endpoint: PushEndpoint, instance: String) {
        Telemetry.breadcrumb(
            "push", "UP onNewEndpoint arrived",
            mapOf("instance" to instance),
        )
        ensureNotificationChannel(context)
        val store = PushStore.applicationStore(context.applicationContext)
        val brokerEndpoint = store.readBrokerEndpoint(context.applicationContext)
        store.updateEndpoint(endpoint.url, brokerEndpoint)
    }

    /**
     * Called when the distributor removes this app's endpoint (e.g.
     * distributor uninstalled or the app is removed from the distributor).
     */
    override fun onUnregistered(context: Context, instance: String) {
        Telemetry.breadcrumb("push", "UP onUnregistered", mapOf("instance" to instance))
        val store = PushStore.applicationStore(context.applicationContext)
        val brokerEndpoint = store.readBrokerEndpoint(context.applicationContext)
        store.onDistributorUnregistered(brokerEndpoint)
    }

    /**
     * Called when a push message arrives from the distributor.
     * [PushMessage.content] contains the decrypted payload bytes.
     *
     * Expected JSON: `{"title":"…","body":"…","session_id":"…"}`.
     * Privacy-mode default: broker sends just `{"session_id":"…"}`.
     */
    override fun onMessage(context: Context, message: PushMessage, instance: String) {
        val content = message.content
        Telemetry.breadcrumb(
            "push", "UP onMessage",
            mapOf("bytes" to content.size.toString()),
        )
        ensureNotificationChannel(context)

        val raw = content.toString(Charsets.UTF_8)
        val title: String
        val body: String
        val sessionId: String?
        try {
            val json = JSONObject(raw)
            title = json.optString("title", "Conduit")
                .takeIf { it.isNotBlank() } ?: "Conduit"
            body = json.optString("body", "A session needs your attention")
                .takeIf { it.isNotBlank() } ?: "A session needs your attention"
            sessionId = json.optString("session_id", "").takeIf { it.isNotBlank() }
        } catch (e: JSONException) {
            Telemetry.capture(
                error = e,
                message = "Android push: failed to parse message payload",
                tags = mapOf("surface" to "android", "phase" to "push_message"),
                extras = mapOf("raw_length" to content.size.toString()),
            )
            return
        }

        Telemetry.breadcrumb(
            "push", "UP message parsed",
            mapOf("hasSessionId" to (sessionId != null).toString()),
        )
        showNotification(context, title, body, sessionId)
    }

    // ── Notification helpers ──────────────────────────────────────────────

    private fun ensureNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Agent activity",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Notifications for Conduit agent turns and pending input"
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun showNotification(
        context: Context,
        title: String,
        body: String,
        sessionId: String?,
    ) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            if (sessionId != null) {
                putExtra(EXTRA_SESSION_ID, sessionId)
            }
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(
            context,
            sessionId?.hashCode() ?: Random.nextInt(),
            intent,
            pendingFlags,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .build()

        try {
            val nm = NotificationManagerCompat.from(context)
            nm.notify(sessionId?.hashCode() ?: Random.nextInt(), notification)
            Telemetry.breadcrumb(
                "push", "notification shown",
                mapOf("sessionId" to (sessionId ?: "none")),
            )
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS permission not yet granted.
            Telemetry.breadcrumb("push", "notification blocked: missing POST_NOTIFICATIONS permission")
        }
    }
}
