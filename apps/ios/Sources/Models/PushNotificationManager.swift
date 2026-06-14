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
    /// True when we have a token AND the broker confirmed the registration
    /// for the ACTIVE endpoint.
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
///      ALL paired broker endpoints via `POST /api/push/register`.
///   4. Re-register with ALL known servers when the active endpoint
///      changes (box switch) or when APNs rotates the token.
///   5. Unregister from a server when it is removed from savedServers.
///   6. Expose `PushSettingsState` for the honest-state Settings row
///      (reflects the ACTIVE endpoint's registration state only).
@Observable
@MainActor
final class PushNotificationManager {

    // MARK: - Observable state

    var settingsState = PushSettingsState()

    // MARK: - Internal state

    /// The raw APNs device token last received from the system. Stored
    /// as hex-encoded string (Apple's canonical format for the broker).
    private(set) var deviceTokenHex: String?

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
    /// Registers with ALL paired endpoints; `settingsState.registered`
    /// reflects the active endpoint's result.
    func didRegisterDeviceToken(
        _ tokenData: Data,
        endpoint: StoredEndpoint,
        allEndpoints: [StoredEndpoint]
    ) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        Telemetry.breadcrumb("push", "APNs token received", data: ["hexLen": "\(hex.count)"])
        deviceTokenHex = hex
        settingsState.auth = .authorized
        registerWithAllServers(hex: hex, activeEndpoint: endpoint, allEndpoints: allEndpoints)
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
    /// the existing token with ALL known endpoints so every paired box
    /// stays current (token may have rotated, or a box may have lost its
    /// registration). Also re-registers the push-to-start token so every
    /// box can start a Live Activity while the app is backgrounded.
    func endpointChanged(to newEndpoint: StoredEndpoint, allEndpoints: [StoredEndpoint]) {
        if newEndpoint.isComplete, let hex = deviceTokenHex {
            Telemetry.breadcrumb("push", "endpoint changed — re-registering with all servers",
                data: ["host": newEndpoint.displayHost, "count": "\(allEndpoints.count)"])
            registerWithAllServers(hex: hex, activeEndpoint: newEndpoint, allEndpoints: allEndpoints)
        }
        // Re-register the push-to-start token so the new endpoint set can
        // start a Live Activity from push (§1.3, PLAN-push-to-start-la.md).
        if let startHex = TurnLiveActivityController.shared.lastPushToStartTokenHex {
            Telemetry.breadcrumb("push_la",
                "endpoint changed — re-registering push-to-start token",
                data: ["host": newEndpoint.displayHost])
            registerPushToStartToken(hex: startHex, allEndpoints: allEndpoints)
        }
    }

    /// Best-effort unregister POST to a single endpoint. Called when a
    /// server is removed from savedServers.
    func unregisterFromServer(endpoint: StoredEndpoint) {
        guard endpoint.isComplete else { return }
        Telemetry.breadcrumb("push", "fan-out unregister: box removed",
            data: ["host": endpoint.displayHost])
        Task { @MainActor in
            guard let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/push/unregister"
            guard let url = components?.url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = "{}".data(using: .utf8)
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse
            else {
                Telemetry.breadcrumb("push", "unregister POST network error",
                    data: ["host": endpoint.displayHost])
                return
            }
            Telemetry.breadcrumb("push", "unregister POST result",
                data: ["host": endpoint.displayHost, "status": "\(http.statusCode)"])
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

    // MARK: - Live Activity push token

    /// Register a Live Activity push token with one broker endpoint.
    /// Called once per token update from `Activity.pushTokenUpdates`.
    /// Body: `{"platform":"apns-liveactivity","token":"<hex>","session_id":"<id>"}`.
    /// Best-effort: failures are breadcrumbed but not surfaced to the UI.
    func registerLAToken(hex: String, sessionID: String, endpoint: StoredEndpoint) {
        guard endpoint.isComplete else {
            Telemetry.breadcrumb("push_la", "registerLAToken skipped: endpoint incomplete",
                data: ["session": sessionID])
            return
        }
        Task { @MainActor in
            guard let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/push/register"
            guard let url = components?.url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct LARegisterPayload: Encodable {
                let platform: String
                let token: String
                let session_id: String
            }
            let payload = LARegisterPayload(
                platform: "apns-liveactivity",
                token: hex,
                session_id: sessionID
            )
            guard let body = try? JSONEncoder().encode(payload) else { return }
            req.httpBody = body
            Telemetry.breadcrumb("push_la", "LA token register POST start",
                data: ["session": sessionID, "host": endpoint.displayHost])
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse
            else {
                Telemetry.breadcrumb("push_la", "LA token register POST network error",
                    data: ["session": sessionID, "host": endpoint.displayHost])
                return
            }
            Telemetry.breadcrumb("push_la", "LA token register POST result",
                data: ["session": sessionID, "host": endpoint.displayHost,
                       "status": "\(http.statusCode)"])
        }
    }

    // MARK: - Push-to-start token registration (§1.3, PLAN-push-to-start-la.md)

    /// Register the ActivityKit push-to-start token with ALL broker endpoints.
    ///
    /// The push-to-start token is device-scoped (one per `Activity` type),
    /// NOT session-scoped. It must be registered with EVERY paired box so
    /// whichever box owns an incoming turn can start the Live Activity while
    /// the app is backgrounded or closed.
    ///
    /// Endpoint: `POST /api/push/register-start`
    /// Body: `{"platform":"apns-liveactivity-start","token":"<hex>"}`
    ///
    /// Re-registration triggers (all handled via call sites):
    ///   - token rotation: the `pushToStartTokenUpdates` async sequence
    ///     re-fires → controller calls this again,
    ///   - endpoint/box change: `endpointChanged` calls this with allEndpoints,
    ///   - box add: endpointChanged is called when the user selects the new box.
    ///
    /// On initial token receipt (no `allEndpoints` supplied) we fan out to
    /// the controller's current registration endpoint. `endpointChanged` covers
    /// the full set on any subsequent box change.
    func registerPushToStartToken(hex: String) {
        if let ep = TurnLiveActivityController.shared.registrationEndpoint, ep.isComplete {
            Telemetry.breadcrumb("push_la", "push-to-start token register",
                data: ["host": ep.displayHost])
            postRegisterStart(hex: hex, endpoint: ep)
        } else {
            Telemetry.breadcrumb("push_la",
                "registerPushToStartToken: no complete endpoint, deferring")
        }
    }

    /// Fan-out variant called from `endpointChanged` with the explicit
    /// full endpoint list so every paired box stays current.
    func registerPushToStartToken(hex: String, allEndpoints: [StoredEndpoint]) {
        let endpoints = allEndpoints.filter { $0.isComplete }
        Telemetry.breadcrumb("push_la", "push-to-start token fan-out register",
            data: ["count": "\(endpoints.count)"])
        for ep in endpoints {
            postRegisterStart(hex: hex, endpoint: ep)
        }
    }

    /// POST the push-to-start token to one broker endpoint.
    /// Body: `{"platform":"apns-liveactivity-start","token":"<hex>"}`.
    /// Best-effort: failures are breadcrumbed.
    private func postRegisterStart(hex: String, endpoint: StoredEndpoint) {
        guard endpoint.isComplete else { return }
        Task { @MainActor in
            guard let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/push/register-start"
            guard let url = components?.url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct StartRegisterPayload: Encodable {
                let platform: String
                let token: String
            }
            let payload = StartRegisterPayload(
                platform: "apns-liveactivity-start",
                token: hex
            )
            guard let body = try? JSONEncoder().encode(payload) else { return }
            req.httpBody = body
            Telemetry.breadcrumb("push_la", "push-to-start register POST start",
                data: ["host": endpoint.displayHost])
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse
            else {
                Telemetry.breadcrumb("push_la", "push-to-start register POST network error",
                    data: ["host": endpoint.displayHost])
                return
            }
            Telemetry.breadcrumb("push_la", "push-to-start register POST result",
                data: ["host": endpoint.displayHost, "status": "\(http.statusCode)"])
        }
    }

    // MARK: - Private

    /// Fan out registration to ALL endpoints concurrently. Each box is an
    /// independent Task so one failure does not cancel others (best-effort
    /// per box). `settingsState.registered` reflects the ACTIVE endpoint's
    /// result only; other boxes are breadcrumbed.
    private func registerWithAllServers(
        hex: String,
        activeEndpoint: StoredEndpoint,
        allEndpoints: [StoredEndpoint]
    ) {
        // Deduplicate: always include active endpoint; merge with all others.
        let endpoints: [StoredEndpoint] = {
            var seen = Set<StoredEndpoint>()
            var result: [StoredEndpoint] = []
            let candidates = activeEndpoint.isComplete
                ? [activeEndpoint] + allEndpoints
                : allEndpoints
            for ep in candidates {
                guard ep.isComplete, seen.insert(ep).inserted else { continue }
                result.append(ep)
            }
            return result
        }()

        Telemetry.breadcrumb("push", "fan-out register: N boxes",
            data: ["count": "\(endpoints.count)"])

        for ep in endpoints {
            let isActive = (ep == activeEndpoint)
            Task { @MainActor in
                let success = await postRegister(hex: hex, endpoint: ep)
                Telemetry.breadcrumb("push", "fan-out register result",
                    data: ["host": ep.displayHost, "success": "\(success)"])
                if isActive {
                    settingsState.registered = success
                }
            }
        }
    }

    /// POST the device token to one broker's push registry.
    /// Returns `true` on HTTP 2xx, `false` on any failure.
    private func postRegister(hex: String, endpoint: StoredEndpoint) async -> Bool {
        guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return false }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/push/register"
        guard let url = components?.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["platform": "apns", "token": hex]
        guard let body = try? JSONEncoder().encode(payload) else { return false }
        req.httpBody = body
        Telemetry.breadcrumb("push", "register POST start", data: ["host": endpoint.displayHost])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else {
            Telemetry.breadcrumb("push", "register POST network error",
                data: ["host": endpoint.displayHost])
            return false
        }
        let ok = (200..<300).contains(http.statusCode)
        if ok {
            Telemetry.breadcrumb("push", "register POST success",
                data: ["host": endpoint.displayHost, "status": "\(http.statusCode)"])
        } else {
            Telemetry.breadcrumb("push", "register POST failed",
                data: ["host": endpoint.displayHost, "status": "\(http.statusCode)"])
        }
        return ok
    }
}

// MARK: - StoredEndpoint: Hashable (needed for dedup set)

extension StoredEndpoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(token)
    }
}

// MARK: - Hex encoding (pure, testable)

extension Data {
    /// Canonical APNs device-token hex string (lowercase, no separators).
    var apnsTokenHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
