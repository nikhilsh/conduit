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

            // --- Privacy: never attach PII. isSendDefaultPii = false (the SDK
            // default) keeps Sentry from collecting the device IP address or
            // other personally-identifying data. Set explicitly so a future
            // default-flip can't silently start capturing it.
            options.isSendDefaultPii = false

            // --- Session Replay, buffer mode (privacy-masked) — parity with
            // iOS (Telemetry.swift). Short visual replay of the seconds BEFORE
            // a crash/error to diagnose on-device UI bugs we can't reproduce on
            // the dev box; never an always-on recording, never readable content.
            //
            //   sessionSampleRate = 0 -> no always-on full-session recording.
            //   onErrorSampleRate = 1 -> keep a rolling buffer, attach it only
            //                           when an event is captured. Nothing is
            //                           uploaded on a normal, error-free run.
            options.sessionReplay.sessionSampleRate = 0.0
            options.sessionReplay.onErrorSampleRate = 1.0
            // Mask EVERYTHING. Both default to true; pinned so a default change
            // can never un-mask. maskAllText redacts every text node (chat,
            // terminal output, prompts, tokens); maskAllImages redacts every
            // image. The replay that reaches Sentry is redacted rectangles +
            // layout only — no readable user content. Hard requirement: the
            // operator must never see chat logs, terminal commands, or secrets.
            // Setter-only in sentry-android 8.x (no getter -> no synthesized
            // Kotlin property), and already the SDK default — pinned explicitly
            // so a default change can never un-mask.
            options.sessionReplay.setMaskAllText(true)
            options.sessionReplay.setMaskAllImages(true)
            // Replay network-body capture is opt-in (empty networkDetailAllowUrls
            // by default = nothing captured) and relies on the Sentry OkHttp
            // interceptor, which we don't install. Bodies — which carry code,
            // terminal commands and tokens — are never recorded. Left off.

            // --- Performance tracing + CPU profiling (parity with iOS) ------
            // Diagnose the on-device problems invisible from the dev box:
            // long-chat CPU burn / overheat / battery, slow & frozen frames,
            // slow app starts, ANRs. Auto activity/app-start/frames
            // instrumentation is on by default; we opt into sampling.
            // Reduced from 0.2 -> 0.1 to trim quota; still representative.
            options.tracesSampleRate = 0.1
            // Continuous "UI Profiling" tied to the trace lifecycle (GA in
            // 8.7): while a sampled trace is active the profiler samples call
            // stacks, giving flame graphs of what pins the CPU during a heavy
            // chat. profileSessionSampleRate is relative to tracesSampleRate;
            // the legacy profilesSampleRate must NOT be set alongside it.
            // Profiles are stack samples (symbols + timing), never user content.
            // Reduced from 1.0 -> 0.1 to trim profile-upload quota.
            options.profileSessionSampleRate = 0.1
            options.profileLifecycle = io.sentry.ProfileLifecycle.TRACE
            // ANR / watchdog detection (AnrV2) is on by default; pin it. A
            // frozen main thread (the long-chat "spinner stuck" reports)
            // surfaces as an ANR event.
            options.isAnrEnabled = true

            // --- Privacy: no network URL capture ----------------------------
            // Our OAuth token exchange + WS connect carry sensitive material in
            // URLs (the WS connect URL has a `token=` secret). Drop network
            // breadcrumbs so no request URL reaches Sentry. We don't install the
            // OkHttp span interceptor, and maxRequestBodySize stays NONE
            // (default), so no body or URL is ever attached.
            options.isEnableNetworkEventBreadcrumbs = false

            // --- Quota denylist: beforeSend backstop -------------------------
            // Drop useless high-frequency events BEFORE they are uploaded.
            // This is the durable quota guard: even if a caller forgets to use
            // breadcrumb instead of debug/diagnostic, denylisted events never
            // reach Sentry.
            //
            // Rules (return null = drop):
            //   1. Any INFO-level "diag" event whose category is in the
            //      HIGH_FREQUENCY_DIAG_CATEGORIES set (keyboard, layout, scroll,
            //      terminal-resize). These are pure UI churn — no value as
            //      standalone events.
            //   2. Any event whose message matches a known routine-noise pattern
            //      (connection churn, routine disconnects). These are expected
            //      lifecycle, not errors.
            // ERROR/FATAL-level events bypass the denylist entirely.
            options.beforeSend = { event, _ ->
                // Never drop real errors.
                val level = event.level
                if (level == SentryLevel.ERROR || level == SentryLevel.FATAL) return@beforeSend event

                // Drop high-frequency UI diag categories (INFO-level).
                val diagCategory = event.tags?.get("diag")
                if (diagCategory != null && diagCategory in HIGH_FREQUENCY_DIAG_CATEGORIES) {
                    return@beforeSend null
                }

                // Drop routine connection-churn messages.
                val msg = event.message?.formatted ?: event.message?.message ?: ""
                if (isRoutineNoiseMessage(msg)) return@beforeSend null

                event
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
     * otherwise flood the project and burn quota. THREE guards below keep that
     * safe regardless of the caller:
     *   1. consecutive-identical events for a category are dropped (only a
     *      *distinct state* gets through),
     *   2. per-category time throttle: at most 1 event per 60s per category
     *      (token-bucket style, thread-safe via ConcurrentHashMap + atomic
     *      compare), and
     *   3. the beforeSend denylist drops high-frequency categories even if
     *      these guards are bypassed.
     *
     * Callers that fire per-interaction (keyboard, layout, scroll,
     * terminal-resize) MUST use [breadcrumb] instead — those categories are
     * also in the beforeSend denylist as a backstop.
     */
    fun debug(category: String, message: String, data: Map<String, String> = emptyMap()) {
        if (BuildConfig.SENTRY_DSN.trim().isEmpty()) return

        val payload = buildString {
            append(message)
            data.entries.sortedBy { it.key }.forEach {
                append("::").append(it.key).append('=').append(it.value)
            }
        }

        val nowMs = System.currentTimeMillis()
        synchronized(debugLock) {
            val isRepeat = lastDebugPayload[category] == payload
            val lastMs = lastDebugTimestampMs[category] ?: 0L
            val tooSoon = (nowMs - lastMs) < DEBUG_THROTTLE_MS
            if (isRepeat || tooSoon) return
            lastDebugPayload[category] = payload
            lastDebugTimestampMs[category] = nowMs
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

    // -------------------------------------------------------------------------
    // beforeSend denylist constants (Android parity with iOS Telemetry.swift)
    // -------------------------------------------------------------------------

    /**
     * High-frequency UI diag categories that MUST NOT produce standalone Sentry
     * events. Callers in these categories should use [breadcrumb] instead;
     * [beforeSend] drops any that slip through.
     *
     * Extend this list whenever a new per-frame / per-interaction category is
     * added. Mirror of iOS [Telemetry.highFrequencyDiagCategories].
     */
    val HIGH_FREQUENCY_DIAG_CATEGORIES: Set<String> = setOf(
        "keyboard",        // per-show/hide/focus events
        "layout",          // per-layout-pass debug
        "scroll",          // scroll-position diag
        "terminal_resize", // terminal window resize
        "terminal-resize", // alternate spelling guard
        "frame",           // per-frame render diag
    )

    /**
     * Substrings whose presence in an event message indicates routine
     * operational churn — expected lifecycle, not an actionable failure.
     * Matched case-insensitively. Mirror of iOS [Telemetry.routineNoisePatterns].
     */
    val ROUTINE_NOISE_PATTERNS: List<String> = listOf(
        "disconnected from harness",  // routine WS lifecycle
        "sessionstore: code 0",       // NSError domain=SessionStore code=0
        "code 0",
        "still disconnected",
        "keyboard will hide",
        "keyboard will show",
        "composer focused",
        "composer blurred",
    )

    /** Returns true when the message matches a routine-noise pattern. */
    fun isRoutineNoiseMessage(message: String): Boolean {
        val lower = message.lowercase()
        return ROUTINE_NOISE_PATTERNS.any { lower.contains(it) }
    }

    /** Max one debug event per category per this interval (milliseconds). */
    const val DEBUG_THROTTLE_MS: Long = 60_000L

    /** Last payload emitted per `diag` category, used to drop consecutive duplicates. */
    private val lastDebugPayload = mutableMapOf<String, String>()
    /** Timestamp (ms) of the last event actually sent per category. */
    private val lastDebugTimestampMs = mutableMapOf<String, Long>()
    /** Guards both lastDebugPayload and lastDebugTimestampMs. */
    private val debugLock = Any()
}
