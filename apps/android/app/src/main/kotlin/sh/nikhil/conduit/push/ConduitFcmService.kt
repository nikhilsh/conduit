package sh.nikhil.conduit.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import sh.nikhil.conduit.MainActivity
import sh.nikhil.conduit.R
import sh.nikhil.conduit.Telemetry
import kotlin.random.Random

/**
 * FCM message receiver — handles foreground message delivery and token rotation.
 *
 * ## Message structure
 * The relay (relay/src/fcm.ts) sends FCM messages with BOTH a `notification`
 * block AND `data` extras:
 *   notification: { title, body }   — auto-shown by FCM when app is in background
 *   data:         { session_id?, box?, category? }  — string key-value map
 *
 * Background behaviour (app not in foreground): FCM auto-displays the
 * notification from the `notification` block. When the user taps it, Android
 * delivers the data extras as intent extras into MainActivity, so
 * [MainActivity.handlePushIntent] can read `session_id` and route to the
 * correct session. No [onMessageReceived] call in this case.
 *
 * Foreground behaviour (app in foreground): [onMessageReceived] is called and
 * we build + post the notification ourselves, mirroring the logic in
 * [ConduitUnifiedPushReceiver.showNotification]. Notification channel reuse:
 * "conduit-agent" defined in [ConduitUnifiedPushReceiver.CHANNEL_ID].
 *
 * ## Token rotation
 * [onNewToken] fires when FCM rotates the device token. We re-register with
 * the broker automatically so the relay always has a live token.
 *
 * Registered in AndroidManifest.xml (android:exported="false" — FCM dispatches
 * via the system, not arbitrary callers).
 */
class ConduitFcmService : FirebaseMessagingService() {

    /**
     * Called when a new FCM message arrives AND the app is in the foreground.
     * (When the app is backgrounded, the system auto-displays the
     * notification from the `notification` block and delivers data extras
     * to the launch intent on tap — no call here.)
     */
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val notification = message.notification

        val sessionId = data["session_id"]?.takeIf { it.isNotBlank() }

        val title = notification?.title
            ?.takeIf { it.isNotBlank() }
            ?: data["title"]?.takeIf { it.isNotBlank() }
            ?: "Conduit"
        val body = notification?.body
            ?.takeIf { it.isNotBlank() }
            ?: data["body"]?.takeIf { it.isNotBlank() }
            ?: "A session needs your attention"

        Telemetry.breadcrumb(
            "push", "FCM onMessageReceived",
            mapOf(
                "hasSessionId" to (sessionId != null).toString(),
                "hasNotification" to (notification != null).toString(),
            ),
        )

        ensureNotificationChannel()
        showNotification(title, body, sessionId)
    }

    /**
     * Called by FCM when the registration token is refreshed (first launch,
     * token rotation, or app data cleared). We re-register with the broker so
     * the relay's token stays valid.
     */
    override fun onNewToken(token: String) {
        Telemetry.breadcrumb("push", "FCM onNewToken: re-registering with broker")
        val store = PushStore.applicationStore(applicationContext)
        val brokerEndpoint = store.readBrokerEndpoint(applicationContext)
        // onNewFcmToken is a no-op when brokerEndpoint is null (deferred until
        // first session pairs a broker); it persists the token and POSTs when
        // an endpoint is available.
        store.onNewFcmToken(token, brokerEndpoint)
    }

    // ── Notification helpers ──────────────────────────────────────────────

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ConduitUnifiedPushReceiver.CHANNEL_ID,
                "Agent activity",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Notifications for Conduit agent turns and pending input"
            }
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun showNotification(title: String, body: String, sessionId: String?) {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            if (sessionId != null) {
                putExtra(ConduitUnifiedPushReceiver.EXTRA_SESSION_ID, sessionId)
            }
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(
            this,
            sessionId?.hashCode() ?: Random.nextInt(),
            intent,
            pendingFlags,
        )

        val notification = NotificationCompat.Builder(this, ConduitUnifiedPushReceiver.CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pendingIntent)
            .build()

        try {
            NotificationManagerCompat.from(this)
                .notify(sessionId?.hashCode() ?: Random.nextInt(), notification)
            Telemetry.breadcrumb(
                "push", "FCM notification shown",
                mapOf("sessionId" to (sessionId ?: "none")),
            )
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS permission not yet granted.
            Telemetry.breadcrumb("push", "FCM notification blocked: missing POST_NOTIFICATIONS permission")
        }
    }
}
