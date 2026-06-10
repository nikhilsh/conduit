import Foundation
import UserNotifications
import UIKit

// MARK: - Push permission state

/// The three observable states for push notifications — shown honestly
/// in Settings. Never fabricated: each maps to a real system+broker answer.
enum PushAuthState: Equatable {
    /// UNAuthorizationStatus has not been determined yet (first launch,
    /// or we haven't asked).
    case notDetermined
    /// User has authorized notifications in system Settings.
    case authorized
    /// User has denied notifications; system Settings is the only fix.
    case denied
    /// Authorization was granted but the APNs device token hasn't been
    /// received from the system yet (transient — usually resolves in < 1s
    /// after `registerForRemoteNotifications`).
    case pending
}

/// Honest composite state for the Settings push row — wraps the
/// authorization state with the broker-side knowledge.
struct PushSettingsState: Equatable {
    var auth: PushAuthState
    /// True when the broker advertises `features.push = true`.
    var brokerSupported: Bool
    /// True when we have a token AND the broker confirmed the registration.
    var registered: Bool

    init(
        auth: PushAuthState = .notDetermined,
        brokerSupported: Bool = false,
        registered: Bool = false
    ) {
        self.auth = auth
        self.brokerSupported = brokerSupported
        self.registered = registered
    }

    /// Human-readable summary for the Settings row subtitle.
    var statusLabel: String {
        if !brokerSupported { return "box doesn't support push" }
        switch auth {
        case .notDetermined: return "not set up"
        case .denied:        return "disabled in Settings"
        case .pending:       return "waiting for system token…"
        case .authorized:    return registered ? "authorized · registered with box" : "authorized · not registered"
        }
    }
}

// MARK: - PushNotificationManager

/// Manages the full APNs registration lifecycle for Conduit:
///
///   1. Request UNUserNotificationCenter authorization at the right
///      moment (after the user's first session exists — NOT during
///      onboarding, which is accounts-free by design per PLAN-PUSH.md).
///   2. Call `UIApplication.shared.registerForRemoteNotifications()`.
///   3. Receive the APNs device token from the system and POST it to
///      the active broker endpoint via `POST /api/push/register`.
///   4. Re-register when the active endpoint changes (box switch) or
///      when APNs rotates the token.
///   5. Expose `PushSettingsState` for the honest-state Settings row.
///
/// V1 scope: registers with the active box only. Multi-box registration
/// is a follow-up (limitation noted in PR body).
@Observable
@MainActor
final class PushNotificationManager {

    // MARK: - Observable state

    var settingsState = PushSettingsState()

    // MARK: - Internal state

    /// The raw APNs device token last received from the system. Stored
    /// as hex-encoded string (Apple's canonical format for the broker).
    private(set) var deviceTokenHex: String?

    /// The endpoint we last successfully registered with. Used to
    /// detect when the active box has changed so we re-register.
    private var lastRegisteredEndpoint: StoredEndpoint?

    // MARK: - Singleton

    static let shared = PushNotificationManager()

    private init() {}

    // MARK: - Public API

    /// Request notification authorization and, if granted, register for
    /// remote notifications. Call this AFTER the user's first session
    /// exists — never during onboarding.
    ///
    /// Safe to call multiple times: the system prompt only fires once;
    /// subsequent calls re-check status and register if already authorized.
    func requestAuthorizationIfNeeded() {
        Telemetry.breadcrumb("push", "requestAuthorization start")
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            switch status {
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    Telemetry.breadcrumb("push", "authorization result", data: ["granted": "\(granted)"])
                    settingsState.auth = granted ? .authorized : .denied
                    if granted {
                        UIApplication.shared.registerForRemoteNotifications()
                        settingsState.auth = .pending
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "iOS push authorization request failed",
                        tags: ["surface": "ios", "phase": "push_auth"],
                        extras: ["detail": error.localizedDescription]
                    )
                    Telemetry.breadcrumb("push", "authorization error", data: ["error": error.localizedDescription])
                }
            case .authorized, .provisional, .ephemeral:
                settingsState.auth = .authorized
                UIApplication.shared.registerForRemoteNotifications()
            case .denied:
                settingsState.auth = .denied
                Telemetry.breadcrumb("push", "authorization denied — user must enable in Settings")
            @unknown default:
                Telemetry.breadcrumb("push", "unknown authorization status")
            }
        }
    }

    /// Called by the AppDelegate bridge when APNs delivers a device token.
    /// Stores it and registers with the active endpoint.
    func didRegisterDeviceToken(_ tokenData: Data, endpoint: StoredEndpoint) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        Telemetry.breadcrumb("push", "APNs token received", data: ["hexLen": "\(hex.count)"])
        deviceTokenHex = hex
        settingsState.auth = .authorized
        registerWithBroker(hex: hex, endpoint: endpoint)
    }

    /// Called by the AppDelegate bridge when APNs registration fails.
    func didFailToRegisterDeviceToken(error: Error) {
        Telemetry.capture(
            error: error,
            message: "iOS APNs device token registration failed",
            tags: ["surface": "ios", "phase": "push_token"],
            extras: ["detail": error.localizedDescription]
        )
        Telemetry.breadcrumb("push", "APNs registration failed", data: ["error": error.localizedDescription])
        settingsState.auth = .denied
    }

    /// Called when the active endpoint changes (box switch). Re-registers
    /// the existing token with the new endpoint if we have one.
    func endpointChanged(to newEndpoint: StoredEndpoint) {
        guard newEndpoint.isComplete, let hex = deviceTokenHex else { return }
        if newEndpoint != lastRegisteredEndpoint {
            Telemetry.breadcrumb("push", "endpoint changed — re-registering token", data: ["host": newEndpoint.displayHost])
            registerWithBroker(hex: hex, endpoint: newEndpoint)
        }
    }

    /// Probe the active endpoint's capabilities to update `brokerSupported`.
    func probeCapabilities(endpoint: StoredEndpoint) async {
        struct CapsEnvelope: Decodable {
            struct Features: Decodable {
                let push: Bool?
                enum CodingKeys: String, CodingKey { case push }
            }
            let features: Features?
        }
        guard let base = endpoint.httpBaseURL else { return }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/capabilities"
        guard let url = components?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let caps = try? JSONDecoder().decode(CapsEnvelope.self, from: data)
        else {
            Telemetry.breadcrumb("push", "capabilities probe failed", data: ["host": endpoint.displayHost])
            settingsState.brokerSupported = false
            return
        }
        let supported = caps.features?.push ?? false
        settingsState.brokerSupported = supported
        Telemetry.breadcrumb("push", "capabilities probed", data: [
            "host": endpoint.displayHost,
            "push": "\(supported)",
        ])
    }

    /// Re-check and refresh the current auth status from the system.
    func refreshAuthStatus() {
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                settingsState.auth = .authorized
            case .denied:
                settingsState.auth = .denied
            case .notDetermined:
                settingsState.auth = .notDetermined
            @unknown default:
                break
            }
        }
    }

    /// Send a test push via `POST /api/push/test`. Used by the Settings
    /// "Send test notification" button. Returns an error string on failure.
    @discardableResult
    func sendTestPush(endpoint: StoredEndpoint, title: String = "", body: String = "") async -> String? {
        Telemetry.breadcrumb("push", "test push start", data: ["host": endpoint.displayHost])
        guard let base = endpoint.httpBaseURL else {
            return "Invalid endpoint"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/push/test"
        guard let url = components?.url else { return "Invalid URL" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "title": title.isEmpty ? "Conduit test" : title,
            "body": body.isEmpty ? "Push notifications are working" : body,
        ]
        guard let body = try? JSONEncoder().encode(payload) else { return "Encoding error" }
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else {
            Telemetry.breadcrumb("push", "test push network error")
            return "Network error"
        }
        if (200..<300).contains(http.statusCode) {
            Telemetry.breadcrumb("push", "test push sent", data: ["status": "\(http.statusCode)"])
            return nil
        }
        // Parse the broker error message for a more useful string.
        struct ErrBody: Decodable { let error: String? }
        let errMsg = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error
            ?? "HTTP \(http.statusCode)"
        Telemetry.breadcrumb("push", "test push failed", data: ["status": "\(http.statusCode)", "error": errMsg])
        return errMsg
    }

    // MARK: - Private

    /// POST the device token to the broker's push registry.
    private func registerWithBroker(hex: String, endpoint: StoredEndpoint) {
        guard endpoint.isComplete else { return }
        Task { @MainActor in
            Telemetry.breadcrumb("push", "register POST start", data: ["host": endpoint.displayHost])
            guard let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/push/register"
            guard let url = components?.url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = ["platform": "apns", "token": hex]
            guard let body = try? JSONEncoder().encode(payload) else { return }
            req.httpBody = body
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse
            else {
                Telemetry.breadcrumb("push", "register POST network error", data: ["host": endpoint.displayHost])
                return
            }
            if (200..<300).contains(http.statusCode) {
                lastRegisteredEndpoint = endpoint
                settingsState.registered = true
                Telemetry.breadcrumb("push", "register POST success", data: [
                    "host": endpoint.displayHost,
                    "status": "\(http.statusCode)",
                ])
            } else {
                Telemetry.breadcrumb("push", "register POST failed", data: [
                    "host": endpoint.displayHost,
                    "status": "\(http.statusCode)",
                ])
                // 503 = push registry not configured on broker (no relay URL set)
                // Don't mark as error — the broker just doesn't have the relay wired.
                settingsState.registered = false
            }
        }
    }
}

// MARK: - Hex encoding (pure, testable)

extension Data {
    /// Canonical APNs device-token hex string (lowercase, no separators).
    var apnsTokenHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
