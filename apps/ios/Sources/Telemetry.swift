import Foundation
#if canImport(Sentry)
import Sentry
#endif

enum Telemetry {
    static func configure() {
#if canImport(Sentry)
        // Never report from a test run. The unit tests host the real app
        // and deliberately exercise failure paths (e.g. the login sheet's
        // "CLI not installed on broker host" fixture) — with a live DSN
        // those shipped to production Sentry as ERRORs on every CI run
        // (314 events of pure noise under release 0.0.1+13). CI no
        // longer passes a DSN to the test step; this guard is the
        // defense in depth.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }
        let dsn = sentryDSN
        guard !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "ios"
            options.enableMetricKit = true

            // --- Privacy: never attach PII. sendDefaultPII = false (the SDK
            // default) means Sentry does NOT collect the device IP address or
            // other personally-identifying server-side data. Set explicitly so
            // a future SDK default-flip can't silently start capturing it.
            options.sendDefaultPii = false

            // --- Session Replay, buffer mode (privacy-masked) ---------------
            // We want a short visual replay of the seconds BEFORE a crash/error
            // to diagnose on-device UI/layout bugs we can't reproduce on the
            // dev box — but NEVER an always-on screen recording, and never any
            // readable content.
            //
            //   sessionSampleRate = 0  → no always-on full-session recording.
            //   onErrorSampleRate = 1  → keep a rolling in-memory buffer and
            //                            attach it only when an event is
            //                            captured (crash/error). Nothing is
            //                            uploaded on a normal, error-free run.
            options.sessionReplay.sessionSampleRate = 0.0
            options.sessionReplay.onErrorSampleRate = 1.0
            // Mask EVERYTHING. Both default to true in 9.16.x; we pin them so a
            // default change can never un-mask. maskAllText redacts every text
            // node (chat messages, terminal output, prompts, tokens) to a solid
            // block; maskAllImages redacts every image. The replay that reaches
            // Sentry is redacted rectangles + layout only — no readable chat,
            // terminal commands, file contents, or secrets. This is the hard
            // requirement: the operator must never see user content.
            options.sessionReplay.maskAllText = true
            options.sessionReplay.maskAllImages = true
            // Replay network-body capture is opt-in only (it requires
            // options.experimental.enableReplayNetworkDetailsCapturing = true
            // PLUS a non-empty allow list). We set NEITHER, so request/response
            // bodies — which on our WebSocket carry code, terminal commands and
            // auth tokens — are never recorded. Left off deliberately.

            // --- Performance tracing + CPU profiling ------------------------
            // The point is to diagnose the on-device problems we CAN'T see from
            // the dev box: long-chat CPU burn / overheat / battery drain, slow
            // & frozen frames, slow app starts, and main-thread hangs. Auto
            // performance instrumentation (app start, slow/frozen frames,
            // UIViewController time) is on by default; we just opt into
            // sampling. 0.2 keeps overhead and quota modest while still giving a
            // representative picture.
            options.tracesSampleRate = 0.2
            // Continuous "UI Profiling" tied to the trace lifecycle: while a
            // sampled trace is active the profiler samples the call stacks, so
            // we get flame graphs of what's actually pinning the CPU during a
            // heavy chat. sessionSampleRate is RELATIVE to tracesSampleRate
            // (the legacy profilesSampleRate was removed in 9.0). Profiles are
            // stack samples (symbol names + timing) — never variable values or
            // buffer contents, so no user content leaks.
            options.configureProfiling = {
                $0.lifecycle = .trace
                $0.sessionSampleRate = 1.0
            }
            // App Hang Tracking V2 is the default (and only) implementation in
            // 9.x — the enableAppHangTrackingV2 toggle was removed in 9.0. Pin
            // the confirm-on flag + a 2s threshold so a frozen main thread
            // (the long-chat "spinner stuck" reports) surfaces as an event.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2.0

            // --- Privacy: no network span/URL capture -----------------------
            // Tracing would otherwise swizzle URLSession and attach each
            // request's URL to a span. Our OAuth token exchange + API calls put
            // sensitive material in URLs/endpoints, and the WS connect URL
            // carries a `token=` secret — none of that must reach Sentry. Turn
            // the network span instrumentation OFF; we keep the perf signal we
            // actually want (CPU/frames/hangs) without any URL capture.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
        }
#endif
    }

    static func capture(error: Error, message: String, tags: [String: String] = [:], extras: [String: String] = [:]) {
#if canImport(Sentry)
        guard !sentryDSN.isEmpty else { return }
        SentrySDK.configureScope { scope in
            tags.forEach { scope.setTag(value: $0.value, key: $0.key) }
            extras.forEach { scope.setExtra(value: $0.value, key: $0.key) }
            scope.setLevel(.error)
        }
        SentrySDK.capture(message: message)
        SentrySDK.capture(error: error)
#else
        _ = (error, message, tags, extras)
#endif
    }

    /// Leave a lightweight breadcrumb in the trail attached to the NEXT
    /// event (crash/error). Unlike `debug`, a breadcrumb is NOT a full
    /// Sentry event — it's ring-buffered by the SDK and costs nothing
    /// until something fails, so scatter these liberally across any flow
    /// or screen that can fail (see CLAUDE.md "Standing order").
    /// `category` groups crumbs (e.g. "agent_login", "session",
    /// "connect", "browser", "upload"); `data` is searchable key/values.
    static func breadcrumb(_ category: String, _ message: String, data: [String: String] = [:]) {
#if canImport(Sentry)
        guard !sentryDSN.isEmpty else { return }
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        if !data.isEmpty { crumb.data = data }
        SentrySDK.addBreadcrumb(crumb)
#else
        _ = (category, message, data)
#endif
    }

    /// Structured diagnostic telemetry meant to be READ BACK from Sentry
    /// (org `swe-kitty`, project `conduit-ios`): an INFO-level event tagged
    /// `diag=<category>` with `data` as searchable extras. Use it for runtime
    /// state that can't be reproduced on the dev box — layout / render /
    /// timing / keyboard — so the actual on-device numbers can be read
    /// remotely instead of asked for and transcribed.
    ///
    /// Standing practice: instrument new features with `Telemetry.debug` so
    /// they're always debuggable from Sentry. It is meant to be LOW VOLUME —
    /// every call is a full Sentry event, so a high-frequency caller (keyboard
    /// show/hide, terminal resize) would otherwise flood the project, burn
    /// quota, and pile main-thread work behind the SDK. Two guards below keep
    /// that safe regardless of the caller:
    ///   1. consecutive-identical events for a category are dropped (only a
    ///      *distinct state* gets through), and
    ///   2. the event is built + submitted off the main thread.
    static func debug(_ category: String, _ message: String, data: [String: String] = [:]) {
#if canImport(Sentry)
        guard !sentryDSN.isEmpty else { return }

        // Collapse repeats: skip when this category's payload is identical to
        // the last one we sent for it. `data` is captured by value here, so
        // the comparison + dispatch are safe to run off the calling thread.
        let payload = message + "\u{1}" + data.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1}")
        debugDedupeLock.lock()
        let isRepeat = lastDebugPayload[category] == payload
        if !isRepeat { lastDebugPayload[category] = payload }
        debugDedupeLock.unlock()
        guard !isRepeat else { return }

        debugQueue.async {
            SentrySDK.capture(message: "[\(category)] \(message)") { scope in
                scope.setLevel(.info)
                scope.setTag(value: category, key: "diag")
                // Collapse ALL events of a diag category into a SINGLE Sentry
                // issue (otherwise each distinct message — "keyboard will show",
                // "...will hide", "composer focused" — files its own issue and
                // floods the project). One issue per category, many events.
                scope.setFingerprint(["diag", category])
                data.forEach { scope.setExtra(value: $0.value, key: $0.key) }
            }
        }
#else
        _ = (category, message, data)
#endif
    }

#if canImport(Sentry)
    /// Serial queue so diagnostic events never cost the main thread time, even
    /// for the scope-building closure. The Sentry SDK is itself thread-safe.
    private static let debugQueue = DispatchQueue(label: "sh.nikhil.conduit.telemetry.debug", qos: .utility)
    /// Last payload emitted per `diag` category, used to drop consecutive
    /// duplicates. Guarded by `debugDedupeLock` since `debug` is called from
    /// arbitrary threads (keyboard notifications, layout passes).
    private static var lastDebugPayload: [String: String] = [:]
    private static let debugDedupeLock = NSLock()
#endif

    private static var sentryDSN: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ONLY a real DSN URL enables Sentry. Anything else must disable it
        // cleanly: the unsubstituted build placeholder `$(SENTRY_DSN)`, an
        // empty secret, or a stray value like "-" (a bad/empty SENTRY_DSN_IOS
        // secret literally shipped `SentryDSN = "-"` in v0.0.76–78, which
        // passed the old `!= "$(SENTRY_DSN)"` check, reached SentrySDK.start as
        // an invalid DSN, failed SDK init, and silently dropped EVERY event —
        // iOS telemetry went dark for three releases). Validating the URL shape
        // here turns a bad secret into "Sentry off" instead of "Sentry broken".
        guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") else { return "" }
        return trimmed
    }
}
