package sh.nikhil.conduit.push

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import sh.nikhil.conduit.MainActivity
import sh.nikhil.conduit.R
import sh.nikhil.conduit.Telemetry

/**
 * Handles the Approve / Deny action buttons on an `category=="approval"` push
 * (Fix 9). The notification's action PendingIntents target this receiver; it
 * resolves the approval over HTTP off the main thread via [goAsync], then
 * rewrites the same notification with the outcome (or falls back to a
 * tap-through to the session when nothing is pending / the resolve fails).
 *
 * Registered in AndroidManifest.xml (android:exported="false" — only our own
 * PendingIntents address it).
 */
class ApprovalActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_RESOLVE = "sh.nikhil.conduit.APPROVAL_RESOLVE"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_DECISION = "decision"
        const val EXTRA_NOTIFICATION_ID = "notification_id"

        const val DECISION_APPROVE = "approve"
        const val DECISION_DENY = "deny"
    }

    // Process-lived scope so the resolve survives the receiver returning while
    // goAsync() holds the pending result open.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_RESOLVE) return
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)?.takeIf { it.isNotBlank() }
        val decision = intent.getStringExtra(EXTRA_DECISION)?.takeIf { it.isNotBlank() } ?: DECISION_APPROVE
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, sessionId?.hashCode() ?: 0)
        if (sessionId == null) return

        Telemetry.breadcrumb(
            "push", "approval action tapped",
            mapOf("decision" to decision, "session" to sessionId),
        )

        val appCtx = context.applicationContext
        val store = PushStore.applicationStore(appCtx)
        val endpoint = store.readBrokerEndpoint(appCtx)

        // Show an interim "resolving…" notification so the row doesn't appear dead.
        postOutcome(appCtx, notificationId, sessionId, "Resolving…", showProgress = true)

        val pending = goAsync()
        scope.launch {
            try {
                if (endpoint == null || !endpoint.isComplete) {
                    Telemetry.breadcrumb("push", "approval resolve: no broker endpoint")
                    postTapThrough(appCtx, notificationId, sessionId, "Open to respond")
                    return@launch
                }
                Telemetry.breadcrumb(
                    "push", "approval resolve start",
                    mapOf("decision" to decision, "host" to endpoint.displayHost),
                )
                val result = store.resolveApproval(endpoint, sessionId, decision)
                Telemetry.breadcrumb(
                    "push", "approval resolve result",
                    mapOf("decision" to decision, "result" to result.name),
                )
                when (result) {
                    ApprovalResolveResult.Resolved -> {
                        val text = if (decision == DECISION_APPROVE) "Approved — agent continuing" else "Denied"
                        postOutcome(appCtx, notificationId, sessionId, text, showProgress = false)
                    }
                    ApprovalResolveResult.Stale -> {
                        // Nothing pending — just let the user tap through.
                        postTapThrough(appCtx, notificationId, sessionId, "Already resolved — open session")
                    }
                    ApprovalResolveResult.Failed -> {
                        Telemetry.capture(
                            error = IllegalStateException("approval resolve failed"),
                            message = "Android approval resolve failed",
                            tags = mapOf("surface" to "android", "phase" to "approval_resolve"),
                            extras = mapOf("decision" to decision),
                        )
                        postTapThrough(appCtx, notificationId, sessionId, "Couldn't reach the box — open to respond")
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }

    /** Rewrite the notification with a terminal outcome line (no actions). */
    private fun postOutcome(
        ctx: Context,
        notificationId: Int,
        sessionId: String,
        text: String,
        showProgress: Boolean,
    ) {
        val builder = NotificationCompat.Builder(ctx, ConduitUnifiedPushReceiver.CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Approval")
            .setContentText(text)
            .setOngoing(showProgress)
            .setAutoCancel(!showProgress)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(sessionTapIntent(ctx, sessionId))
        if (showProgress) builder.setProgress(0, 0, true)
        notifySafely(ctx, notificationId, builder.build())
    }

    /** Outcome line that just deep-links into the session on tap. */
    private fun postTapThrough(ctx: Context, notificationId: Int, sessionId: String, text: String) {
        val notification = NotificationCompat.Builder(ctx, ConduitUnifiedPushReceiver.CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Approval")
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(sessionTapIntent(ctx, sessionId))
            .build()
        notifySafely(ctx, notificationId, notification)
    }

    private fun sessionTapIntent(ctx: Context, sessionId: String): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(ConduitUnifiedPushReceiver.EXTRA_SESSION_ID, sessionId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(ctx, sessionId.hashCode(), intent, flags)
    }

    private fun notifySafely(ctx: Context, id: Int, notification: android.app.Notification) {
        try {
            NotificationManagerCompat.from(ctx).notify(id, notification)
        } catch (e: SecurityException) {
            Telemetry.breadcrumb("push", "approval notification blocked: missing POST_NOTIFICATIONS")
        }
    }
}
