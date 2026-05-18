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
            scope.level = .error
        }
        SentrySDK.capture(message: message)
        SentrySDK.capture(error: error)
#else
        _ = (error, message, tags, extras)
#endif
    }

    private static var sentryDSN: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "$(SENTRY_DSN)" ? "" : trimmed
    }
}
