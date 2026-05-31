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
    /// (org `swe-kitty`, project `apple-ios`): an INFO-level event tagged
    /// `diag=<category>` with `data` as searchable extras. Use it for runtime
    /// state that can't be reproduced on the dev box — layout / render /
    /// timing / keyboard — so the actual on-device numbers can be read
    /// remotely instead of asked for and transcribed.
    ///
    /// Standing practice: instrument new features with `Telemetry.debug` so
    /// they're always debuggable from Sentry. Keep it LOW VOLUME — dedupe to
    /// once per distinct state — because every call is a Sentry event.
    static func debug(_ category: String, _ message: String, data: [String: String] = [:]) {
#if canImport(Sentry)
        guard !sentryDSN.isEmpty else { return }
        SentrySDK.capture(message: "[\(category)] \(message)") { scope in
            scope.setLevel(.info)
            scope.setTag(value: category, key: "diag")
            data.forEach { scope.setExtra(value: $0.value, key: $0.key) }
        }
#else
        _ = (category, message, data)
#endif
    }

    private static var sentryDSN: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "$(SENTRY_DSN)" ? "" : trimmed
    }
}
