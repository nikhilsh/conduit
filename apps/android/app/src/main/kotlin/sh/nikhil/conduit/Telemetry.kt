package sh.nikhil.conduit

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
            // versionName is pinned to "0.0.1" (device bug #7), so Sentry's
            // default release would mislabel EVERY android event
            // "sh.nikhil.conduit@0.0.1+12" — we couldn't tell which build a
            // crash came from. Use the real release tag the CI build injects.
            if (BuildConfig.RELEASE_TAG != "dev") {
                options.release = "sh.nikhil.conduit@${BuildConfig.RELEASE_TAG}"
            }
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
     * (org `swe-kitty`, project `conduit-android`): an INFO-level event tagged
     * `diag=<category>` with `data` as searchable extras. Use it for runtime
     * state that can't be reproduced on the dev box — layout / render /
     * timing — so the on-device numbers can be read remotely instead of asked
     * for and transcribed.
     *
     * Standing practice: instrument new features with `Telemetry.debug` so
     * they're always debuggable from Sentry. It is meant to be LOW VOLUME —
     * every call is a full Sentry event, so a high-frequency caller would
     * otherwise flood the project and burn quota. Consecutive-identical events
     * for a category are dropped here, so only a *distinct state* gets through
     * regardless of the caller.
     */
    fun debug(category: String, message: String, data: Map<String, String> = emptyMap()) {
        if (BuildConfig.SENTRY_DSN.trim().isEmpty()) return
        // Collapse repeats: skip when this category's payload matches the last
        // one we sent for it. Mirrors the iOS `Telemetry.debug` dedupe.
        val payload = buildString {
            append(message)
            data.entries.sortedBy { it.key }.forEach {
                append("::").append(it.key).append('=').append(it.value)
            }
        }
        synchronized(lastDebugPayload) {
            if (lastDebugPayload[category] == payload) return
            lastDebugPayload[category] = payload
        }
        Sentry.withScope { scope ->
            scope.level = SentryLevel.INFO
            scope.setTag("diag", category)
            // Collapse all events of a diag category into a SINGLE Sentry issue
            // (otherwise each distinct message files its own issue and floods
            // the project). One issue per category, many events.
            scope.fingerprint = listOf("diag", category)
            data.forEach { (key, value) -> scope.setExtra(key, value) }
            Sentry.captureMessage("[$category] $message", SentryLevel.INFO)
        }
    }

    /** Last payload emitted per `diag` category, used to drop consecutive duplicates. */
    private val lastDebugPayload = mutableMapOf<String, String>()

    /**
     * Leave a lightweight breadcrumb in the trail attached to the NEXT
     * event (crash/error). Unlike [debug], a breadcrumb is NOT a full
     * Sentry event — it's ring-buffered by the SDK and costs nothing until
     * something fails, so scatter these liberally across any flow or
     * screen that can fail (see CLAUDE.md "Standing order"). [category]
     * groups crumbs (e.g. "agent_login", "session", "connect", "browser").
     */
    fun breadcrumb(category: String, message: String, data: Map<String, String> = emptyMap()) {
        if (BuildConfig.SENTRY_DSN.trim().isEmpty()) return
        val crumb = Breadcrumb(message)
        crumb.category = category
        crumb.level = SentryLevel.INFO
        data.forEach { (key, value) -> crumb.setData(key, value) }
        Sentry.addBreadcrumb(crumb)
    }
}
