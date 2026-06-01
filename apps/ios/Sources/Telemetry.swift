import Foundation
#if canImport(Sentry)
import Sentry
#endif

enum Telemetry {
    static func configure() {
#if canImport(Sentry)
        let dsn = sentryDSN
        guard !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "ios"
            options.enableMetricKit = true
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
