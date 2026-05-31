package sh.nikhil.swekitty

import android.content.Context
import io.sentry.Breadcrumb
import io.sentry.Sentry
import io.sentry.SentryLevel
import io.sentry.android.core.SentryAndroid

object Telemetry {
    fun configure(context: Context) {
        val dsn = BuildConfig.SENTRY_DSN.trim()
        if (dsn.isEmpty()) return
        SentryAndroid.init(context) { options ->
            options.dsn = dsn
            options.environment = "android"
            options.isEnableAutoSessionTracking = true
        }
    }

    fun capture(error: Throwable, message: String, tags: Map<String, String> = emptyMap(), extras: Map<String, String> = emptyMap()) {
        val dsn = BuildConfig.SENTRY_DSN.trim()
        if (dsn.isEmpty()) return
        Sentry.withScope { scope ->
            scope.level = SentryLevel.ERROR
            tags.forEach { (key, value) -> scope.setTag(key, value) }
            extras.forEach { (key, value) -> scope.setExtra(key, value) }
            Sentry.captureMessage(message, SentryLevel.ERROR)
            Sentry.captureException(error)
        }
    }

    /**
     * Capture a non-error diagnostic (no exception attached) — for paths
     * that fail by returning null rather than throwing (e.g. a QR image
     * that simply doesn't decode). Lands as a WARNING-level Sentry message
     * with the supplied extras so we can see *why* it failed on a device.
     */
    fun diagnostic(message: String, tags: Map<String, String> = emptyMap(), extras: Map<String, String> = emptyMap()) {
        val dsn = BuildConfig.SENTRY_DSN.trim()
        if (dsn.isEmpty()) return
        Sentry.withScope { scope ->
            scope.level = SentryLevel.WARNING
            tags.forEach { (key, value) -> scope.setTag(key, value) }
            extras.forEach { (key, value) -> scope.setExtra(key, value) }
            Sentry.captureMessage(message, SentryLevel.WARNING)
        }
    }

    /**
     * Structured diagnostic telemetry meant to be READ BACK from Sentry
     * (org `swe-kitty`, project `android`): an INFO-level event tagged
     * `diag=<category>` with `data` as searchable extras. Use it for runtime
     * state that can't be reproduced on the dev box — layout / render /
     * timing — so the on-device numbers can be read remotely instead of asked
     * for and transcribed.
     *
     * Standing practice: instrument new features with `Telemetry.debug` so
     * they're always debuggable from Sentry. Keep it LOW VOLUME — dedupe to
     * once per distinct state — because every call is a Sentry event.
     */
    fun debug(category: String, message: String, data: Map<String, String> = emptyMap()) {
        if (BuildConfig.SENTRY_DSN.trim().isEmpty()) return
        Sentry.withScope { scope ->
            scope.level = SentryLevel.INFO
            scope.setTag("diag", category)
            data.forEach { (key, value) -> scope.setExtra(key, value) }
            Sentry.captureMessage("[$category] $message", SentryLevel.INFO)
        }
    }

    /** Leave a breadcrumb so it shows up in the trail of the next event. */
    fun breadcrumb(message: String, data: Map<String, String> = emptyMap()) {
        if (BuildConfig.SENTRY_DSN.trim().isEmpty()) return
        val crumb = Breadcrumb(message)
        crumb.category = "qr"
        data.forEach { (key, value) -> crumb.setData(key, value) }
        Sentry.addBreadcrumb(crumb)
    }
}
