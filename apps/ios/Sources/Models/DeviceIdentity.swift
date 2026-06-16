import Foundation

// MARK: - DeviceIdentity

/// Stable per-install device identifier used to route push notifications
/// back to the originating device. Generated once on first access, then
/// persisted in UserDefaults. Survives app relaunches; does not survive
/// a clean reinstall (which is intentional — a reinstall is a fresh install).
///
/// Sent as `device_id` in three broker requests:
///   - POST /api/push/register  (so the broker maps this device's APNs token)
///   - POST /api/push/test      (so the test push targets THIS device)
///   - WS create_session        (so the broker records the session-owner device)
enum DeviceIdentity {

    private static let userDefaultsKey = "conduit.device_id"

    /// The stable per-install UUID string. Created on first call; returned
    /// from UserDefaults on all subsequent calls. Never nil in practice.
    static var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: userDefaultsKey) {
            return stored
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: userDefaultsKey)
        Telemetry.breadcrumb("push", "device_id minted", data: ["id": fresh])
        return fresh
    }
}
