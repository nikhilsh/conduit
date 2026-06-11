import UIKit
import UserNotifications

// MARK: - AppDelegate
//
// SwiftUI App lifecycle delegates APNs callbacks here via
// `@UIApplicationDelegateAdaptor` in `ConduitApp`. Three roles:
//
//   1. Forward APNs device-token events to `PushNotificationManager`.
//   2. Handle foreground `UNUserNotificationCenterDelegate` — show banner
//      even when the app is in the foreground so the user can tap through.
//   3. Handle notification tap → deep-link into the session via
//      `SessionStore.selectedSessionID` (the same mechanism `applySessionURL`
//      uses for `conduit://session/<id>` links).
//
// NOTE: keep this class thin. Business logic lives in
// `PushNotificationManager`; navigation lives in `SessionStore`.

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
        Telemetry.breadcrumb("push", "AppDelegate launched")
        return true
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

    /// User tapped a Conduit push notification — route to the session.
    ///
    /// The broker's push payload carries `session_id` in the userInfo dict
    /// (top-level JSON key, not nested under `aps`). On tap we just set
    /// `selectedSessionID` — the same path the Live Activity deep-link
    /// (`conduit://session/<id>`) and the `applySessionURL` handler use.
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
        Telemetry.breadcrumb("push", "tap: routing to session", data: ["session": sessionID])
        // Route on the main actor — `selectedSessionID` is MainActor-isolated.
        Task { @MainActor in
            sessionStore?.selectedSessionID = sessionID
        }
    }
}
