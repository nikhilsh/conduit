import Foundation
import Network
import Observation
import UIKit

/// Harness reachability state. The Rust `connect()` just stores a delegate
/// — it doesn't actually prove the server is reachable — so we keep a
/// separate `.linked` (handshake done, not yet verified) and `.live`
/// (at least one round-trip succeeded). Session creation flips us into
/// `.live` on the first success.
///
/// `.reconnecting` is driven by the Rust core's per-session reconnect
/// worker: a transient drop becomes "Reconnecting (2/5)…" rather than
/// "Offline" and recovers automatically.
enum HarnessState: Equatable {
    case disconnected
    case connecting
    case linked
    case live
    case reconnecting(attempt: UInt32, maxAttempts: UInt32)
    case failed(String)

    /// Short label suitable for a status badge.
    var badgeLabel: String {
        switch self {
        case .disconnected:                       return "Disconnected"
        case .connecting:                         return "Connecting…"
        case .linked:                             return "Paired"
        case .live:                               return "Live"
        case .reconnecting(let a, let m):         return "Reconnecting (\(a)/\(m))…"
        case .failed:                             return "Offline"
        }
    }

    /// Long error description for the failed state, if any.
    var failureReason: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }

    /// True once the app has actually proven the harness can answer.
    var isReachable: Bool {
        switch self {
        case .linked, .live: return true
        default: return false
        }
    }

    /// True once the user can issue commands (create sessions, etc).
    /// Keep allowing commands while reconnecting — the outbound channel
    /// queues messages until the new socket is in place, so the user
    /// can keep typing through a blip.
    var canIssueCommands: Bool {
        switch self {
        case .linked, .live, .reconnecting: return true
        default: return false
        }
    }
}

/// Per-session lifecycle, distinct from the overall harness state.
/// Driven by both client API calls and incoming `SessionStatus` deltas.
enum SessionLifecycle: Equatable {
    case creating
    case live
    case exited(Int32)
    case failed(String)
}

struct StoredEndpoint: Equatable {
    var url: String
    var token: String

    static let empty = StoredEndpoint(url: "", token: "")

    var isComplete: Bool { !url.isEmpty && !token.isEmpty }

    /// Sanitized host display (strips ws[s]:// and trailing slash).
    var displayHost: String {
        var s = url
        for prefix in ["wss://", "ws://", "https://", "http://"] {
            if s.lowercased().hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                break
            }
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "(no endpoint)" : s
    }

    /// HTTP(S) base for resolving relative paths the server sends back
    /// (`/preview/<uuid>/`, `/memory/sessions/<uuid>.html`). The ws/wss
    /// URL we store is converted scheme-only; host + port are preserved.
    var httpBaseURL: URL? {
        guard var components = URLComponents(string: url) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws":   components.scheme = "http"
        case "wss":  components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct SavedServer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var endpoint: StoredEndpoint
    var isDefault: Bool
}

extension StoredEndpoint: Codable {}

@Observable
@MainActor
final class SessionStore {
    /// Persisted endpoint in the keychain so pairings survive app reinstalls.
    var endpoint: StoredEndpoint {
        didSet { Self.persist(endpoint) }
    }

    var harness: HarnessState = .disconnected
    var sessions: [ProjectSession] = []
    var selectedSessionID: String?
    var savedServers: [SavedServer] = []

    /// Banner-style error for the most recent session-creation failure.
    /// Cleared automatically the next time the user tries again.
    var sessionCreationError: String?

    /// Per-session lifecycle. Sessions whose entry is `.creating` appear
    /// in the list as placeholders even before the server reports them.
    var sessionLifecycle: [String: SessionLifecycle] = [:]

    /// Latest SessionStatus seen for each session — drives the health badge + agent badge.
    var statusBySession: [String: SessionStatus] = [:]

    /// Append-only terminal scrollback per session. TerminalTab observes this and
    /// re-feeds the SwiftTerm view on appear / after reconnect.
    var terminalBuffer: [String: Data] = [:]

    /// Chat log per session, oldest first.
    var chatLog: [String: [ChatEvent]] = [:]
    /// Typed conversation timeline per session, oldest first.
    var conversationLog: [String: [ConversationItem]] = [:]

    /// Last-known preview info per session (nil until the agent reports one).
    var preview: [String: PreviewInfo] = [:]

    /// Per-session connection health from the Rust reconnect worker.
    /// Exposed for UI affordances that want session-scoped state instead
    /// of the aggregated harness state.
    var connectionHealthBySession: [String: ConnectionHealth] = [:]

    private var client: SweKittyClient?
    private var delegate: StoreDelegate?
    private var pathMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    /// Path identifier we've seen so we don't nudge on first activation.
    private var lastPath: NWPath?

    init() {
        self.endpoint = Self.loadPersisted()
        self.savedServers = Self.loadSavedServers()
        if endpoint.isComplete && !savedServers.contains(where: { $0.endpoint == endpoint }) {
            upsertSavedServer(name: endpoint.displayHost, endpoint: endpoint, makeDefault: true)
        }
        installNetworkAndLifecycleHooks()
    }

    // No deinit cleanup: SessionStore lives for the app's lifetime
    // (owned by SweKittyApp's @State), so the NWPathMonitor and the
    // NotificationCenter observer are released only at process exit —
    // and Swift 6 actor isolation forbids touching MainActor state from
    // a nonisolated deinit anyway.

    /// Tell every per-session worker in the Rust core that the network
    /// path probably changed. The worker drops its current socket and
    /// re-enters the reconnect loop instead of waiting for TCP to
    /// surface the failure.
    private func nudgeNetworkChange() {
        client?.notifyNetworkChange()
    }

    private func installNetworkAndLifecycleHooks() {
        // App returns to foreground after a long suspend — sockets may
        // be silently dead even though our state thinks they're live.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.nudgeNetworkChange()
        }

        // Wi-Fi↔LTE handoff, VPN flap, hotspot toggle. NWPathMonitor
        // fires synchronously on its own queue; bounce to main and
        // compare against the last seen path so we don't nudge on the
        // initial subscription.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPath = path }
                guard let prev = self.lastPath else { return }
                if prev.availableInterfaces.map(\.type) != path.availableInterfaces.map(\.type)
                    || prev.status != path.status
                {
                    self.nudgeNetworkChange()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "swekitty.nwpath"))
        self.pathMonitor = monitor
    }

    // MARK: - Convenience derived state

    /// Sessions plus any in-flight placeholders, sorted with placeholders first.
    var visibleSessions: [VisibleSession] {
        let real = sessions.map { VisibleSession.real($0) }
        let placeholderIDs = sessionLifecycle
            .filter { entry in entry.value == .creating && !sessions.contains(where: { s in s.id == entry.key }) }
            .keys
            .sorted()
        let placeholders = placeholderIDs.map { VisibleSession.creating($0) }
        return placeholders + real
    }

    // MARK: - Connection

    func connect() {
        guard endpoint.isComplete else {
            harness = .failed("Set an endpoint and token in Settings.")
            return
        }
        harness = .connecting
        let newClient = SweKittyClient(endpoint: endpoint.url, bearerToken: endpoint.token)
        let newDelegate = StoreDelegate(store: self)
        self.client = newClient
        self.delegate = newDelegate
        Task {
            do {
                try await newClient.connect(delegate: newDelegate)
                self.harness = .linked
                self.refreshSessions()
            } catch {
                let detail = Self.describe(error)
                self.harness = .failed(detail)
                Telemetry.capture(
                    error: error,
                    message: "iOS harness connect failed",
                    tags: ["surface": "ios", "phase": "connect"],
                    extras: ["endpoint": self.endpoint.displayHost, "detail": detail]
                )
            }
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        delegate = nil
        harness = .disconnected
    }

    /// Re-establish the link using the currently stored endpoint.
    func reconnect() {
        disconnect()
        connect()
    }

    /// Convenience flow: optionally switch endpoint, connect, then create a
    /// new session and move it into `cwd`.
    func connectAndStart(endpoint nextEndpoint: StoredEndpoint? = nil, assistant: String, cwd: String) {
        if let nextEndpoint {
            endpoint = nextEndpoint
            upsertSavedServer(name: nextEndpoint.displayHost, endpoint: nextEndpoint, makeDefault: true)
        }
        disconnect()
        connect()
        Task { @MainActor in
            do {
                try await waitUntilCommandReady()
                createSession(assistant: assistant, startupCwd: cwd)
            } catch {
                harness = .failed("Connect/start failed: \(error.localizedDescription)")
            }
        }
    }

    func upsertSavedServer(name: String, endpoint: StoredEndpoint, makeDefault: Bool) {
        var next = savedServers
        if let idx = next.firstIndex(where: { $0.endpoint == endpoint }) {
            next[idx].name = name
            if makeDefault {
                for i in next.indices { next[i].isDefault = false }
                next[idx].isDefault = true
            }
        } else {
            if makeDefault {
                for i in next.indices { next[i].isDefault = false }
            }
            next.append(
                SavedServer(
                    id: UUID().uuidString,
                    name: name.isEmpty ? endpoint.displayHost : name,
                    endpoint: endpoint,
                    isDefault: makeDefault || next.isEmpty
                )
            )
        }
        savedServers = next
        Self.persistSavedServers(next)
    }

    func selectSavedServer(_ serverID: String, autoConnect: Bool) {
        guard let server = savedServers.first(where: { $0.id == serverID }) else { return }
        for i in savedServers.indices {
            savedServers[i].isDefault = savedServers[i].id == serverID
        }
        Self.persistSavedServers(savedServers)
        endpoint = server.endpoint
        if autoConnect {
            disconnect()
            connect()
        }
    }

    func removeSavedServer(_ serverID: String) {
        let removedWasCurrent = savedServers.first(where: { $0.id == serverID })?.endpoint == endpoint
        savedServers.removeAll { $0.id == serverID }
        if savedServers.isEmpty {
            endpoint = .empty
            disconnect()
        } else if !savedServers.contains(where: { $0.isDefault }) {
            savedServers[0].isDefault = true
            if removedWasCurrent {
                endpoint = savedServers[0].endpoint
            }
        }
        Self.persistSavedServers(savedServers)
    }

    // MARK: - Session lifecycle

    func createSession(assistant: String, branch: String? = nil, startupCwd: String? = nil) {
        guard let client else { return }
        sessionCreationError = nil
        let pendingID = "pending-\(UUID().uuidString)"
        sessionLifecycle[pendingID] = .creating
        Task {
            do {
                let id = try await client.createSession(assistant: assistant, branch: branch)
                if let startupCwd {
                    let trimmed = startupCwd.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let cmd = "cd \(Self.shellQuoted(trimmed)) && pwd\n"
                        try? await client.sendInput(sessionId: id, data: Data(cmd.utf8))
                    }
                }
                self.sessionLifecycle[pendingID] = nil
                self.sessionLifecycle[id] = .live
                self.harness = .live
                self.refreshSessions()
                self.selectedSessionID = id
            } catch {
                let detail = Self.describe(error)
                self.sessionLifecycle[pendingID] = .failed(detail)
                self.sessionCreationError = detail
                if Self.isAuth(error) {
                    self.harness = .failed("Pairing expired. Scan a new QR code from the harness.")
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS create session failed",
                    tags: ["surface": "ios", "phase": "create_session", "assistant": assistant],
                    extras: ["endpoint": self.endpoint.displayHost, "detail": detail]
                )
                // Sweep the placeholder after a short delay so the user can
                // see *why* without having a stuck row forever.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.sessionLifecycle[pendingID] = nil
                }
            }
        }
    }

    func switchAgent(sessionID: String, to assistant: String) {
        guard let client else { return }
        Task {
            do { try await client.switchAgent(sessionId: sessionID, assistant: assistant) }
            catch {
                let detail = Self.describe(error)
                self.sessionLifecycle[sessionID] = .failed("switch_agent: \(detail)")
                if Self.isAuth(error) {
                    self.harness = .failed("Pairing expired. Scan a new QR code from the harness.")
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS switch agent failed",
                    tags: ["surface": "ios", "phase": "switch_agent", "assistant": assistant],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID, "detail": detail]
                )
            }
        }
    }

    func exit(sessionID: String) {
        guard let client else { return }
        Task {
            try? await client.exitSession(sessionId: sessionID)
            self.sessionLifecycle[sessionID] = nil
            self.refreshSessions()
            if self.selectedSessionID == sessionID { self.selectedSessionID = nil }
        }
    }

    // MARK: - Terminal / chat I/O

    func sendInput(sessionID: String, bytes: Data) {
        guard let client else { return }
        Task { try? await client.sendInput(sessionId: sessionID, data: bytes) }
    }

    func sendChat(sessionID: String, message: String) {
        guard let client else { return }
        Task { try? await client.sendChat(sessionId: sessionID, msg: message) }
    }

    func resize(sessionID: String, rows: UInt16, cols: UInt16) {
        guard let client else { return }
        Task { try? await client.resize(sessionId: sessionID, rows: rows, cols: cols) }
    }

    // MARK: - Internal

    fileprivate func refreshSessions() {
        guard let client else { return }
        self.sessions = client.listSessions()
        for s in self.sessions where sessionLifecycle[s.id] == nil {
            sessionLifecycle[s.id] = .live
        }
        for s in self.sessions {
            refreshConversation(sessionID: s.id)
        }
    }

    fileprivate func ingestPtyData(_ sessionID: String, _ bytes: Data) {
        terminalBuffer[sessionID, default: Data()].append(bytes)
    }

    fileprivate func ingestChat(_ sessionID: String, _ event: ChatEvent) {
        chatLog[sessionID, default: []].append(event)
        refreshConversation(sessionID: sessionID)
    }

    fileprivate func refreshConversation(sessionID: String) {
        guard let client else { return }
        if let items = try? client.listConversationItems(sessionId: sessionID) {
            conversationLog[sessionID] = items
        }
    }

    fileprivate func ingestStatus(_ status: SessionStatus) {
        statusBySession[status.session] = status
        if let p = status.preview { preview[status.session] = p }
        if sessionLifecycle[status.session] == nil ||
            sessionLifecycle[status.session] == .creating {
            sessionLifecycle[status.session] = .live
        }
        harness = .live
        refreshSessions()
    }

    fileprivate func ingestPreview(_ sessionID: String, _ p: PreviewInfo) {
        preview[sessionID] = p
    }

    fileprivate func ingestSnapshot(_ sessionID: String, _ gunzipped: Data) {
        // Replace terminal scrollback with the authoritative snapshot from the server.
        terminalBuffer[sessionID] = gunzipped
    }

    fileprivate func ingestExit(_ sessionID: String, _ code: Int32) {
        sessionLifecycle[sessionID] = .exited(code)
        if var status = statusBySession[sessionID] {
            status = SessionStatus(
                session: status.session,
                assistant: status.assistant,
                phase: "exited(\(code))",
                health: "red",
                rows: status.rows,
                cols: status.cols,
                yolo: status.yolo,
                preview: status.preview,
                sessionName: status.sessionName,
                viewers: status.viewers
            )
            statusBySession[sessionID] = status
        }
    }

    fileprivate func ingestDisconnected(_ reason: String) {
        // If we already knew this pairing was expired (e.g. createSession just
        // failed with Auth), don't clobber that diagnosis with the raw
        // URLSession close reason — the server tearing down the socket right
        // after an auth rejection is part of the same failure, not a new one.
        if case .failed(let existing) = harness,
           existing.lowercased().contains("pairing expired") {
            return
        }
        let lower = reason.lowercased()
        if lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized") {
            harness = .failed("Pairing expired. Scan a new QR code from the harness.")
        } else {
            harness = .failed("Disconnected: \(reason)")
        }
    }

    /// Per-session connection health, driven by the Rust core's reconnect
    /// worker. We aggregate across sessions into the single visible
    /// `HarnessState`: any in-progress reconnect dominates; an auth-flavoured
    /// terminal disconnect promotes to the friendly "Pairing expired" state.
    fileprivate func ingestConnectionHealth(_ sessionID: String, _ health: ConnectionHealth) {
        switch health {
        case .connected:
            connectionHealthBySession[sessionID] = health
            if !sessionLifecycle.isEmpty {
                harness = .live
            } else if harness == .disconnected {
                harness = .linked
            }
        case let .connecting(attempt, maxAttempts):
            connectionHealthBySession[sessionID] = health
            harness = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
        case let .disconnected(reason, auth):
            connectionHealthBySession[sessionID] = health
            if auth {
                harness = .failed("Pairing expired. Scan a new QR code from the harness.")
            } else {
                ingestDisconnected(reason)
            }
        }
    }

    // MARK: - Persistence

    private static let endpointKey = "swekitty.endpoint.url"
    private static let tokenKey = "swekitty.endpoint.token"
    private static let savedServersKey = "swekitty.saved_servers.json"
    private static let legacyEndpointDefaultsKey = "swekitty.endpoint.url"

    private static func loadPersisted() -> StoredEndpoint {
        let token = Keychain.get(tokenKey) ?? ""
        let endpoint = Keychain.get(endpointKey)
            ?? UserDefaults.standard.string(forKey: legacyEndpointDefaultsKey)
            ?? ""
        if !endpoint.isEmpty, Keychain.get(endpointKey) == nil {
            Keychain.set(endpoint, for: endpointKey)
            UserDefaults.standard.removeObject(forKey: legacyEndpointDefaultsKey)
        }
        return StoredEndpoint(url: endpoint, token: token)
    }

    private static func persist(_ e: StoredEndpoint) {
        Keychain.set(e.url.isEmpty ? nil : e.url, for: endpointKey)
        Keychain.set(e.token.isEmpty ? nil : e.token, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: legacyEndpointDefaultsKey)
    }

    private static func loadSavedServers() -> [SavedServer] {
        guard let raw = Keychain.get(savedServersKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedServer].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func persistSavedServers(_ servers: [SavedServer]) {
        if servers.isEmpty {
            Keychain.set(nil, for: savedServersKey)
            return
        }
        guard let data = try? JSONEncoder().encode(servers),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        Keychain.set(raw, for: savedServersKey)
    }

    private func waitUntilCommandReady(timeoutMs: UInt64 = 6000) async throws {
        let pollNs: UInt64 = 100_000_000
        var elapsedNs: UInt64 = 0
        let timeoutNs = timeoutMs * 1_000_000
        while elapsedNs < timeoutNs {
            switch harness {
            case .linked, .live, .reconnecting:
                return
            case .failed(let reason):
                throw NSError(domain: "SessionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            default:
                break
            }
            try await Task.sleep(nanoseconds: pollNs)
            elapsedNs += pollNs
        }
        throw NSError(domain: "SessionStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for harness link"])
    }
}

private extension SessionStore {
    static func shellQuoted(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    static func describe(_ error: Error) -> String {
        if isAuth(error) {
            return "Authentication failed. This pairing token has expired; scan a fresh QR code from the harness."
        }
        return String(describing: error)
    }

    static func isAuth(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("auth(") || text == "auth" || text.contains("unauthorized")
    }
}

/// Wraps either a real `ProjectSession` or an in-flight placeholder so the
/// sidebar can render a row before the server confirms creation.
enum VisibleSession: Identifiable {
    case real(ProjectSession)
    case creating(String)

    var id: String {
        switch self {
        case .real(let s):     return s.id
        case .creating(let p): return p
        }
    }
}

/// Bridges Rust-side callbacks (arbitrary thread) onto the MainActor store.
private final class StoreDelegate: SweKittyDelegate {
    private weak var store: SessionStore?
    init(store: SessionStore) { self.store = store }

    func onPtyData(sessionId: String, data: Data) {
        Task { @MainActor in self.store?.ingestPtyData(sessionId, data) }
    }
    func onChatEvent(sessionId: String, event: ChatEvent) {
        Task { @MainActor in self.store?.ingestChat(sessionId, event) }
    }
    func onPreviewReady(sessionId: String, preview: PreviewInfo) {
        Task { @MainActor in self.store?.ingestPreview(sessionId, preview) }
    }
    func onStatus(status: SessionStatus) {
        Task { @MainActor in self.store?.ingestStatus(status) }
    }
    func onSnapshot(sessionId: String, gunzipped: Data) {
        Task { @MainActor in self.store?.ingestSnapshot(sessionId, gunzipped) }
    }
    func onExit(sessionId: String, code: Int32) {
        Task { @MainActor in self.store?.ingestExit(sessionId, code) }
    }
    func onDisconnected(reason: String) {
        Task { @MainActor in self.store?.ingestDisconnected(reason) }
    }
    func onConnectionHealth(sessionId: String, health: ConnectionHealth) {
        Task { @MainActor in self.store?.ingestConnectionHealth(sessionId, health) }
    }
}
