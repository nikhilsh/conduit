import Foundation
import Security

/// Tiny wrapper around `SecItem*` for persistent storage of pairing data
/// and OAuth credential blobs.
///
/// Two surface areas:
///
/// 1. Legacy "single shared service" string API used by the pairing /
///    SSH credential stores: `set(_:for:)` and `get(_:)` use the
///    package-private `defaultService` ("sh.nikhil.swekitty").
/// 2. Explicit `service:account:` Data-blob API used by the agent OAuth
///    flow (see `OAuthClient.swift` + Stage 0 of
///    `docs/PLAN-AGENT-OAUTH.md`). The OAuth service is
///    `"sh.nikhil.swekitty.oauth"` so existing pairing keys never
///    collide with provider-credential blobs.
///
/// All items use `kSecClassGenericPassword` and
/// `kSecAttrAccessibleAfterFirstUnlock` — see PLAN-AGENT-OAUTH §E.2 for
/// why that's the right tier for refresh-token-bearing blobs (we need
/// background WS reconnects to materialize credentials before the user
/// re-unlocks).
enum Keychain {
    static let defaultService = "sh.nikhil.swekitty"

    // MARK: - String-keyed legacy API (pairing + SSH stores)

    static func set(_ value: String?, for key: String) {
        if let value, let data = value.data(using: .utf8), !data.isEmpty {
            set(data, service: defaultService, account: key)
        } else {
            delete(service: defaultService, account: key)
        }
    }

    static func get(_ key: String) -> String? {
        guard let data = get(service: defaultService, account: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data + service+account API (OAuth credential blobs)

    /// Store `value` under `(service, account)`. Overwrites any existing
    /// item for the same pair. A non-success status is intentionally
    /// dropped on the floor — Keychain isn't a strong-consistency store
    /// and the caller is expected to read-back if it cares.
    @discardableResult
    static func set(_ value: Data, service: String, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Returns the blob stored under `(service, account)`, or `nil` if
    /// the item is missing OR the OS reports any other status (we don't
    /// distinguish — Stage 0 just needs round-trip semantics).
    static func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Removes the item under `(service, account)`. Idempotent — a
    /// missing item is not an error.
    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
