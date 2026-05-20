import Foundation

/// Persisted SSH credential the user has typed once and wants to reuse.
/// Stored in the keychain keyed by `host@user` so a re-pair from the same
/// device can skip the form. We never persist a host fingerprint here —
/// that lives in `SshHostKeyTrustStore` so it can be invalidated separately.
struct SavedSshCredential: Codable, Equatable, Identifiable {
    enum AuthKind: String, Codable {
        case password
        case privateKey
    }

    var id: String { "\(username)@\(host):\(port)" }
    var host: String
    var port: UInt16
    var username: String
    var kind: AuthKind
    /// Plaintext password OR PEM-encoded private key — both are secret material;
    /// only persisted into the keychain blob, never UserDefaults.
    var secret: String
    /// Optional passphrase, only used for `.privateKey`.
    var passphrase: String?
}

/// Keychain-backed persistence for the SSH login form. v1: at most one
/// entry per `host@user:port` tuple. Reuses the same `Keychain` helper as
/// the bearer token + endpoint URL.
enum SshCredentialStore {
    private static let indexKey = "swekitty.ssh.creds.index"

    static func load() -> [SavedSshCredential] {
        guard let raw = Keychain.get(indexKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedSshCredential].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ cred: SavedSshCredential) {
        var current = load().filter { $0.id != cred.id }
        current.append(cred)
        persist(current)
    }

    static func remove(id: String) {
        persist(load().filter { $0.id != id })
    }

    static func find(host: String, port: UInt16, username: String) -> SavedSshCredential? {
        load().first { $0.host == host && $0.port == port && $0.username == username }
    }

    private static func persist(_ entries: [SavedSshCredential]) {
        if entries.isEmpty {
            Keychain.set(nil, for: indexKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries),
              let raw = String(data: data, encoding: .utf8) else { return }
        Keychain.set(raw, for: indexKey)
    }
}

/// TOFU fingerprint trust store. Persists `{host:port: fingerprint}`
/// in UserDefaults — re-prompting is a deliberate UX signal that the host
/// key changed, not a "default deny" wall.
enum SshHostKeyTrustStore {
    private static let key = "swekitty.ssh.knownHosts"

    static func known(host: String, port: UInt16) -> String? {
        let map = load()
        return map["\(host):\(port)"]
    }

    static func trust(host: String, port: UInt16, fingerprint: String) {
        var map = load()
        map["\(host):\(port)"] = fingerprint
        persist(map)
    }

    static func forget(host: String, port: UInt16) {
        var map = load()
        map.removeValue(forKey: "\(host):\(port)")
        persist(map)
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
