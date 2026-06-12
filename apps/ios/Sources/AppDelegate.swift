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
//   4. Register the CONDUIT_APPROVAL push category with Approve/Deny
//      actions so users can answer a pending agent prompt from the lock
//      screen without opening the app.
//
// NOTE: keep this class thin. Business logic lives in
// `PushNotificationManager`; navigation lives in `SessionStore`.

/// Push notification category and action identifiers for agent approval
/// prompts. The broker sends category:"CONDUIT_APPROVAL" with session_id
/// in the payload; the user sees Approve/Deny on the lock screen.
enum ConduitPushCategory {
    static let approval = "CONDUIT_APPROVAL"
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

    /// Register the CONDUIT_APPROVAL category so Approve/Deny appear as
    /// action buttons on lock-screen and banner notifications. Safe to
    /// call multiple times (idempotent: UNUserNotificationCenter merges
    /// the new set with the existing registration).
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
        Telemetry.breadcrumb("push", "approval category registered")
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
    /// `applySessionURL` use. For CONDUIT_APPROVAL actions (Approve / Deny)
    /// we answer the pending input via `answerPendingInput` so the agent
    /// unblocks without the user opening the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo["session_id"] as? String, !sessionID.isEmpty else {
            Telemetry.breadcrumb("push", "tap: no session_id in payload")
            return
        }

        let actionID = response.actionIdentifier
        switch actionID {
        case ConduitPushCategory.approveAction:
            // Answer "y" to the pending input -- standard codex approval token.
            Telemetry.breadcrumb("push", "approval action: approve",
                data: ["session": sessionID])
            Task { @MainActor in
                self.sessionStore?.answerPendingInput(sessionID: sessionID, message: "y")
            }
        case ConduitPushCategory.denyAction:
            // Answer "n" to the pending input.
            Telemetry.breadcrumb("push", "approval action: deny",
                data: ["session": sessionID])
            Task { @MainActor in
                self.sessionStore?.answerPendingInput(sessionID: sessionID, message: "n")
            }
        default:
            // Plain tap -- route to the session chat.
            Telemetry.breadcrumb("push", "tap: routing to session", data: ["session": sessionID])
            Task { @MainActor in
                self.sessionStore?.selectedSessionID = sessionID
            }
        }
    }
}
