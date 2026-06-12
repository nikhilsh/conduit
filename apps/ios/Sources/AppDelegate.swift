import UIKit
import UserNotifications

// MARK: - AppDelegate
//
// SwiftUI App lifecycle delegates APNs callbacks here via
// `@UIApplicationDelegateAdaptor` in `ConduitApp`. Three roles:
//
//   1. Forward APNs device-token events to `PushNotificationManager`.
//   2. Handle foreground `UNUserNotificationCenterDelegate` -- show banner
//      even when the app is in the foreground so the user can tap through.
//   3. Handle notification tap -> deep-link into the session via
//      `SessionStore.selectedSessionID` (the same mechanism `applySessionURL`
//      uses for `conduit://session/<id>` links).
//   4. Register the "approval" push category (lowercase -- the broker sends
//      aps.category == "approval" exactly) with Approve/Deny actions so users
//      can answer a pending agent prompt from the lock screen without opening
//      the app.
//
// NOTE: keep this class thin. Business logic lives in
// `PushNotificationManager`; navigation lives in `SessionStore`.

/// Push notification category and action identifiers for agent approval
/// prompts. The broker sends category:"approval" (lowercase, exact) with
/// session_id in the payload; the user sees Approve/Deny on the lock screen.
enum ConduitPushCategory {
    /// Must match the broker's aps.category value exactly (lowercase).
    static let approval = "approval"
    static let approveAction = "CONDUIT_APPROVAL_APPROVE"
    static let denyAction = "CONDUIT_APPROVAL_DENY"
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // Injected by ConduitApp after init so the delegate can forward taps
    // without a singleton reference to SessionStore.
    var sessionStore: SessionStore?

    // MARK: UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Become the notification center delegate so we can display
        // foreground notifications and handle tap routing.
        UNUserNotificationCenter.current().delegate = self
        registerPushCategories()
        Telemetry.breadcrumb("push", "AppDelegate launched")
        return true
    }

    /// Register the "approval" category so Approve/Deny appear as action
    /// buttons on lock-screen and banner notifications. The category id must
    /// be "approval" (lowercase) -- that is the exact value the broker sets
    /// in aps.category; a mismatch means iOS never renders the action buttons.
    private func registerPushCategories() {
        let approveAction = UNNotificationAction(
            identifier: ConduitPushCategory.approveAction,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: ConduitPushCategory.denyAction,
            title: "Deny",
            options: [.destructive, .authenticationRequired]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: ConduitPushCategory.approval,
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([approvalCategory])
        Telemetry.breadcrumb("push", "approval category registered",
            data: ["category": ConduitPushCategory.approval])
    }

    /// APNs successfully issued a device token.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            let store = sessionStore
            let endpoint = store?.endpoint ?? .empty
            let allEndpoints = store?.savedServers.map { $0.endpoint } ?? []
            PushNotificationManager.shared.didRegisterDeviceToken(
                deviceToken,
                endpoint: endpoint,
                allEndpoints: allEndpoints
            )
        }
    }

    /// APNs failed to issue a device token (no network, sandbox missing
    /// entitlement, etc.).
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterDeviceToken(error: error)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the notification while the app is in the foreground (banner +
    /// sound). Without this iOS silently drops foreground notifications.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Telemetry.breadcrumb("push", "foreground notification received")
        completionHandler([.banner, .sound])
    }

    /// User tapped or acted on a Conduit push notification.
    ///
    /// The broker's push payload carries `session_id` in the userInfo dict
    /// (top-level JSON key, not nested under `aps`). For plain taps we set
    /// `selectedSessionID` -- the same path the Live Activity deep-link and
    /// `applySessionURL` use.
    ///
    /// For "approval" actions (Approve / Deny) we resolve via
    /// `POST /api/session/approval` rather than the session WebSocket: the
    /// WebSocket is NOT connected when the app is woken by a background
    /// notification action, so answerPendingInput would silently no-op. We
    /// keep the process alive (no `defer`) until the URLSession task finishes,
    /// then call completionHandler. Do not open the app/UI from these actions.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo["session_id"] as? String, !sessionID.isEmpty else {
            Telemetry.breadcrumb("push", "tap: no session_id in payload")
            completionHandler()
            return
        }

        let actionID = response.actionIdentifier
        switch actionID {
        case ConduitPushCategory.approveAction:
            Telemetry.breadcrumb("push", "approval action: approve",
                data: ["session": sessionID])
            resolveApproval(sessionID: sessionID, decision: "approve",
                userInfo: userInfo, completionHandler: completionHandler)

        case ConduitPushCategory.denyAction:
            Telemetry.breadcrumb("push", "approval action: deny",
                data: ["session": sessionID])
            resolveApproval(sessionID: sessionID, decision: "deny",
                userInfo: userInfo, completionHandler: completionHandler)

        default:
            // Plain tap -- route to the session chat. Do NOT open the app
            // from approve/deny actions; only plain taps navigate.
            Telemetry.breadcrumb("push", "tap: routing to session", data: ["session": sessionID])
            Task { @MainActor in
                self.sessionStore?.selectedSessionID = sessionID
            }
            completionHandler()
        }
    }

    // MARK: - HTTP approval resolve

    /// POST the approve/deny decision to the broker's HTTP endpoint so the
    /// agent unblocks even when the app is not WS-connected in the background.
    ///
    /// Endpoint: `POST <brokerBaseURL>/api/session/approval`
    /// Body: `{"session_id":"<id>","decision":"approve"|"deny"}`
    /// Auth: `Bearer <token>` -- same derivation PushNotificationManager uses.
    ///
    /// Box selection: if the push userInfo carries a `box` key that matches a
    /// saved server's endpoint host, use that server's endpoint+token;
    /// otherwise fall back to the active endpoint. completionHandler is called
    /// after the task finishes (or fails) so the process stays alive.
    private func resolveApproval(
        sessionID: String,
        decision: String,
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        Task {
            // Capture store state on MainActor before going off-actor.
            let (endpoint, savedServers): (StoredEndpoint, [SavedServer]) = await MainActor.run {
                let store = self.sessionStore
                return (store?.endpoint ?? .empty, store?.savedServers ?? [])
            }

            // If the push carries a `box` key, try to match it to a saved
            // server so the right broker receives the decision.
            let resolvedEndpoint: StoredEndpoint = {
                if let boxHint = userInfo["box"] as? String, !boxHint.isEmpty {
                    if let match = savedServers.first(where: {
                        $0.endpoint.displayHost == boxHint
                    }) {
                        return match.endpoint
                    }
                }
                return endpoint
            }()

            guard resolvedEndpoint.isComplete,
                  let base = resolvedEndpoint.httpBaseURL else {
                Telemetry.breadcrumb("push", "approval resolve: no valid endpoint",
                    data: ["session": sessionID, "decision": decision])
                completionHandler()
                return
            }

            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/approval"
            guard let url = components?.url else {
                Telemetry.breadcrumb("push", "approval resolve: bad URL",
                    data: ["session": sessionID])
                completionHandler()
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("Bearer \(resolvedEndpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct ApprovalBody: Encodable {
                let session_id: String
                let decision: String
            }
            guard let body = try? JSONEncoder().encode(
                ApprovalBody(session_id: sessionID, decision: decision)
            ) else {
                completionHandler()
                return
            }
            req.httpBody = body

            Telemetry.breadcrumb("push", "approval resolve POST start",
                data: ["session": sessionID, "decision": decision,
                       "host": resolvedEndpoint.displayHost])

            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200..<300:
                        Telemetry.breadcrumb("push", "approval resolve: resolved",
                            data: ["session": sessionID, "decision": decision,
                                   "status": "\(http.statusCode)"])
                    case 404:
                        // Nothing pending -- agent may have already moved on.
                        Telemetry.breadcrumb("push", "approval resolve: 404 nothing pending",
                            data: ["session": sessionID])
                    default:
                        Telemetry.capture(
                            error: nil,
                            message: "push approval resolve failed",
                            tags: ["surface": "ios", "phase": "push_approval"],
                            extras: ["session": sessionID, "decision": decision,
                                     "status": "\(http.statusCode)"]
                        )
                    }
                }
            } catch {
                Telemetry.capture(
                    error: error,
                    message: "push approval resolve network error",
                    tags: ["surface": "ios", "phase": "push_approval"],
                    extras: ["session": sessionID, "decision": decision,
                             "detail": error.localizedDescription]
                )
            }

            completionHandler()
        }
    }
}
