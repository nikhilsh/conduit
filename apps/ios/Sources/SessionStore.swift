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

/// One-shot UI cue triggered after a pairing completes.
/// `Identifiable` so it can drive `.sheet(item:)` cleanly — when the
/// sheet dismisses, the binding clears this back to nil and stale
/// pairings don't re-trigger the sheet on next launch.
struct PendingAgentPick: Identifiable, Equatable {
    let id: UUID = UUID()
    let hostNote: String
}

struct SavedServer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var endpoint: StoredEndpoint
    var isDefault: Bool
}

struct RemoteDirectoryEntry: Codable, Equatable, Identifiable {
    var name: String
    var path: String
    var is_dir: Bool
    var id: String { path }
}

struct RemoteDirectoryListing: Codable, Equatable {
    var path: String
    var parent: String
    var entries: [RemoteDirectoryEntry]
}

extension StoredEndpoint: Codable {}

/// UI-level status for the SSH-bootstrap flow. Independent of `HarnessState`
/// because bootstrap runs *before* we have an endpoint to connect to: the
/// progress line ("Starting harness…") lives in the SSH login sheet, not
/// the main pairing status.
enum SshBootstrapState: Equatable {
    case idle
    case running(message: String)
    case failed(reason: String)
}

/// Outstanding TOFU prompt presented to the user mid-bootstrap. The bridge
/// blocks on the user's tap before letting the SSH handshake continue.
struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: UInt16
    let fingerprint: String
}

@Observable
@MainActor
final class SessionStore {
    /// Persisted endpoint in the keychain so pairings survive app reinstalls.
    var endpoint: StoredEndpoint {
        didSet {
            Self.persist(endpoint)
            refreshRecentDirectories()
        }
    }

    var harness: HarnessState = .disconnected
    var sessions: [ProjectSession] = []
    var selectedSessionID: String?
    var savedServers: [SavedServer] = []
    var recentDirectories: [String] = []

    /// SSH-bootstrap progress. Observed by the SSH login sheet.
    var sshBootstrapState: SshBootstrapState = .idle

    /// Active TOFU prompt. SweKittyApp observes this and presents a sheet.
    var pendingHostKey: HostKeyPrompt?

    /// Resolver for the active TOFU prompt. Wired up by the bridge; consumed
    /// by the SwiftUI sheet's Accept/Reject buttons.
    private var hostKeyResolver: ((Bool) -> Void)?

    /// Banner-style error for the most recent session-creation failure.
    /// Cleared automatically the next time the user tries again.
    var sessionCreationError: String?

    /// Per-session lifecycle. Sessions whose entry is `.creating` appear
    /// in the list as placeholders even before the server reports them.
    var sessionLifecycle: [String: SessionLifecycle] = [:]

    /// Latest SessionStatus seen for each session — drives the health badge + agent badge.
    var statusBySession: [String: SessionStatus] = [:]

    /// Append-only terminal scrollback per session. TerminalTab observes this and
    /// re-feeds the WKTerminalView on appear / after reconnect.
    var terminalBuffer: [String: Data] = [:]

    /// Per-session xterm.js serialized render state, captured by
    /// `WKTerminalView.dismantleUIView` (tab switch / background) and
    /// replayed by the next attach so the user doesn't see an empty
    /// terminal waiting for live PTY bytes. ANSI string from
    /// `SerializeAddon.serialize()`. In-memory only; cross-launch
    /// persistence would need disk write-through.
    var terminalSnapshot: [String: String] = [:]

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

    /// Set when a fresh pairing (deep link, QR scan, etc.) completes;
    /// drives the `AgentPickerSheet` so the user lands directly on
    /// "pick Claude or Codex" instead of an empty session list. UI
    /// resets this to nil when the sheet dismisses.
    var pendingAgentPick: PendingAgentPick?

    /// Local rename map — keyed by session id, value is the user-supplied
    /// display name. Persists in `UserDefaults` so a rename survives
    /// relaunch even though the Rust core doesn't know about it.
    var displayNames: [String: String] = SessionStore.loadDisplayNames() {
        didSet { SessionStore.persistDisplayNames(displayNames) }
    }

    private var client: SweKittyClient?
    private var delegate: StoreDelegate?
    private var pathMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    /// Path identifier we've seen so we don't nudge on first activation.
    private var lastPath: NWPath?

    init() {
        self.endpoint = Self.loadPersisted()
        self.savedServers = Self.loadSavedServers()
        self.recentDirectories = []
        if endpoint.isComplete && !savedServers.contains(where: { $0.endpoint == endpoint }) {
            upsertSavedServer(name: endpoint.displayHost, endpoint: endpoint, makeDefault: true)
        }
        refreshRecentDirectories()
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

    func listDirectories(path: String?) async throws -> RemoteDirectoryListing {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/fs/list"
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 101, userInfo: [NSLocalizedDescriptionKey: "Failed to build directory URL"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SessionStore", code: 102, userInfo: [NSLocalizedDescriptionKey: "Directory listing failed"])
        }
        return try JSONDecoder().decode(RemoteDirectoryListing.self, from: data)
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

    // MARK: - SSH bootstrap

    /// Drive `sshBootstrap` from the UniFFI surface, pipe the resulting
    /// `local_port` + `token` into our existing pairing flow.
    ///
    /// `serverName` defaults to the human-friendly `user@host` if omitted.
    /// `anthropicApiKey` / `openaiApiKey` are forwarded into the harness'
    /// `docker run -e ...` so first-launch agents work without a follow-up
    /// SSH session — both are optional. The bootstrap script also reads
    /// any host-side env if these are empty.
    func connectViaSSH(
        credentials: SshCredentials,
        serverName: String? = nil,
        anthropicApiKey: String = "",
        openaiApiKey: String = "",
        imageRef: String? = nil
    ) {
        let host = credentials.host
        let port = credentials.port
        let user = credentials.username
        sshBootstrapState = .running(message: "Connecting to \(user)@\(host):\(port)…")

        Task {
            let preToken = UUID().uuidString
            let bridge = SshHostKeyBridge(store: self, host: host, port: port)
            do {
                self.sshBootstrapState = .running(message: "Starting harness on \(host)…")
                let result = try await sshBootstrap(
                    credentials: credentials,
                    preAllocatedToken: preToken,
                    anthropicApiKey: anthropicApiKey,
                    openaiApiKey: openaiApiKey,
                    imageRef: imageRef,
                    hostKeyDelegate: bridge
                )
                let endpoint = StoredEndpoint(
                    url: "ws://127.0.0.1:\(result.localPort)",
                    token: result.token
                )
                let name = serverName?.isEmpty == false
                    ? serverName!
                    : "\(user)@\(host)"
                self.endpoint = endpoint
                self.upsertSavedServer(name: name, endpoint: endpoint, makeDefault: true)
                self.disconnect()
                self.connect()
                self.sshBootstrapState = .idle
                Telemetry.capture(
                    error: NSError(domain: "ios.ssh_bootstrap", code: 0, userInfo: [NSLocalizedDescriptionKey: "ok"]),
                    message: "iOS SSH bootstrap success",
                    tags: ["surface": "ios", "phase": "ssh_bootstrap", "reused": result.reused ? "1" : "0"],
                    extras: [
                        "host": host,
                        "remote_port": "\(result.remotePort)",
                        "local_port": "\(result.localPort)",
                    ]
                )
            } catch let err as SshError {
                let detail = Self.describeSsh(err)
                self.sshBootstrapState = .failed(reason: detail)
                Telemetry.capture(
                    error: err,
                    message: "iOS SSH bootstrap failed",
                    tags: ["surface": "ios", "phase": "ssh_bootstrap", "code": Self.sshCode(err)],
                    extras: ["host": host, "user": user, "detail": detail]
                )
            } catch {
                let detail = String(describing: error)
                self.sshBootstrapState = .failed(reason: detail)
                Telemetry.capture(
                    error: error,
                    message: "iOS SSH bootstrap failed",
                    tags: ["surface": "ios", "phase": "ssh_bootstrap", "code": "unknown"],
                    extras: ["host": host, "user": user, "detail": detail]
                )
            }
        }
    }

    /// Called from `SshHostKeyBridge` on the main actor when the SSH
    /// handshake hits an unknown fingerprint. The completion runs when
    /// the user taps Accept/Reject in `HostKeyPromptSheet`.
    fileprivate func presentHostKeyPrompt(
        host: String,
        port: UInt16,
        fingerprint: String,
        completion: @escaping (Bool) -> Void
    ) {
        hostKeyResolver = completion
        pendingHostKey = HostKeyPrompt(host: host, port: port, fingerprint: fingerprint)
    }

    /// Invoked by the TOFU sheet's buttons.
    func resolveHostKeyPrompt(accept: Bool) {
        guard let prompt = pendingHostKey else { return }
        if accept {
            SshHostKeyTrustStore.trust(host: prompt.host, port: prompt.port, fingerprint: prompt.fingerprint)
        }
        pendingHostKey = nil
        let resolver = hostKeyResolver
        hostKeyResolver = nil
        resolver?(accept)
    }

    func clearSshBootstrap() {
        sshBootstrapState = .idle
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

    func createSession(
        assistant: String,
        branch: String? = nil,
        startupCwd: String? = nil,
        initialPrompt: String? = nil
    ) {
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
                        self.rememberRecentDirectory(trimmed)
                    }
                }
                if let initialPrompt {
                    let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        try? await client.sendChat(sessionId: id, msg: trimmed)
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
        // Optimistic local echo so the user sees their message immediately.
        // The harness doesn't loop user messages back as `on_chat_event`, so
        // without this the chat tab stays empty until the assistant replies.
        // The synthetic item carries a `local-` id; `refreshConversation`
        // preserves it until the server's typed log catches up by content.
        let now = ISO8601DateFormatter().string(from: Date())
        let item = ConversationItem(
            id: "local-\(UUID().uuidString)",
            role: "user",
            kind: "message",
            status: "done",
            content: message,
            ts: now,
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: []
        )
        conversationLog[sessionID, default: []].append(item)
        chatLog[sessionID, default: []].append(ChatEvent(role: "user", content: message, ts: now, files: []))
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

    // `internal` (not `fileprivate`) so SweKittyTests can drive this
    // path directly. The fileprivate access was originally to lock
    // down "only the transport delegate can ingest"; that constraint
    // is fine to relax for tests because the type guards (ChatEvent)
    // make malformed calls a compile error anyway.
    func ingestChat(_ sessionID: String, _ event: ChatEvent) {
        chatLog[sessionID, default: []].append(event)
        refreshConversation(sessionID: sessionID)
    }

    fileprivate func refreshConversation(sessionID: String) {
        guard let client else { return }
        if let items = try? client.listConversationItems(sessionId: sessionID) {
            // Preserve locally-echoed `local-*` items not yet reflected by
            // the server (matched by role+content). Once the harness mirrors
            // the same text back under a server id, the local copy drops.
            let existing = conversationLog[sessionID] ?? []
            let serverFingerprints = Set(items.map { "\($0.role)|\($0.content)" })
            let stillPending = existing.filter {
                $0.id.hasPrefix("local-") && !serverFingerprints.contains("\($0.role)|\($0.content)")
            }
            conversationLog[sessionID] = items + stillPending
        }
    }

    // `internal` (not `fileprivate`) so SweKittyTests can drive this
    // path directly — same rationale as `ingestChat` above. The status
    // frame carries `reasoningEffort` / `cwd` / `startedAt` etc. and
    // a test confirms `statusBySession` reflects those fields end-to-end.
    func ingestStatus(_ status: SessionStatus) {
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
                viewers: status.viewers,
                reasoningEffort: status.reasoningEffort,
                cwd: status.cwd,
                startedAt: status.startedAt,
                lastActivityAt: status.lastActivityAt
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
        Telemetry.capture(
            error: NSError(domain: "SessionStore", code: 0, userInfo: [NSLocalizedDescriptionKey: reason]),
            message: "iOS disconnected from harness",
            tags: [
                "surface": "ios",
                "phase": "disconnect",
                "reason_code": Self.connectionReasonCode(from: reason),
            ],
            extras: [
                "endpoint": endpoint.displayHost,
                "detail": reason,
            ]
        )
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
                Telemetry.capture(
                    error: NSError(domain: "SessionStore", code: 401, userInfo: [NSLocalizedDescriptionKey: reason]),
                    message: "iOS connection health auth failure",
                    tags: [
                        "surface": "ios",
                        "phase": "connection_health",
                        "reason_code": "auth_expired",
                    ],
                    extras: [
                        "endpoint": endpoint.displayHost,
                        "session_id": sessionID,
                        "detail": reason,
                    ]
                )
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

    private static let displayNamesKey = "swekitty.session.displayNames"

    static func loadDisplayNames() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: displayNamesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    static func persistDisplayNames(_ names: [String: String]) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: displayNamesKey)
            return
        }
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: displayNamesKey)
        }
    }

    /// User-supplied name for a session if any, otherwise the harness name.
    func displayName(for session: ProjectSession) -> String {
        displayNames[session.id] ?? session.name
    }

    /// Locally rename a session — persisted to `UserDefaults`, no
    /// harness round-trip. Empty/whitespace strings clear the override.
    func renameSession(sessionID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayNames[sessionID] = nil
        } else {
            displayNames[sessionID] = trimmed
        }
    }

    /// Fork: create a fresh session with the same assistant + branch,
    /// and seed it with a one-line hand-off pointing at the original.
    /// v1 stays fully client-side (no Rust core change); Stage 3 of
    /// docs/PLAN-LITTER-UI.md flagged a `fork_session` UDL method as a
    /// future optimization but the client-side path is enough for now.
    func forkSession(sessionID: String) {
        guard let original = sessions.first(where: { $0.id == sessionID }) else { return }
        guard let client else { return }
        Task {
            do {
                let newID = try await client.createSession(assistant: original.assistant, branch: original.branch)
                let seed = "Forked from \(original.name) (id \(sessionID)). Pick up where the previous session left off."
                try? await client.sendChat(sessionId: newID, msg: seed)
                self.sessionLifecycle[newID] = .live
                self.refreshSessions()
                self.selectedSessionID = newID
                self.displayNames[newID] = "Fork: \(self.displayName(for: original))"
            } catch {
                let detail = Self.describe(error)
                self.sessionCreationError = "fork: \(detail)"
                Telemetry.capture(
                    error: error,
                    message: "iOS fork session failed",
                    tags: ["surface": "ios", "phase": "fork_session"],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID, "detail": detail]
                )
            }
        }
    }

    private func refreshRecentDirectories() {
        let all = Self.loadRecentDirectoriesByServer()
        recentDirectories = all[endpoint.displayHost] ?? []
    }

    private func rememberRecentDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = Self.loadRecentDirectoriesByServer()
        let key = endpoint.displayHost
        var current = all[key] ?? []
        current.removeAll { $0 == trimmed }
        current.insert(trimmed, at: 0)
        if current.count > 12 { current = Array(current.prefix(12)) }
        all[key] = current
        Self.persistRecentDirectoriesByServer(all)
        recentDirectories = current
    }

    private static func loadRecentDirectoriesByServer() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: recentDirectoriesByServerKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persistRecentDirectoriesByServer(_ value: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: recentDirectoriesByServerKey)
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
    static let recentDirectoriesByServerKey = "swekitty.recentDirectoriesByServer"

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

    static func describeSsh(_ err: SshError) -> String {
        switch err {
        case .Dial(let m):                  return "Couldn't reach the host: \(m)"
        case .Handshake(let m):             return "SSH handshake failed: \(m)"
        case .HostKeyRejected(let m):       return "Host key rejected: \(m)"
        case .AuthFailed(let m):            return "Authentication failed: \(m)"
        case .DockerMissing(let m):         return "Docker is not installed on the server: \(m)"
        case .DockerPermission(let m):      return "User can't reach Docker: \(m)"
        case .PortConflict(let m):          return "Server port is already in use: \(m)"
        case .HarnessStartTimeout(let m):   return "Harness took too long to come up: \(m)"
        case .BootstrapExitCode(let m):     return "Bootstrap script failed: \(m)"
        case .BootstrapParse(let m):        return "Couldn't parse bootstrap output: \(m)"
        case .PortForward(let m):           return "Port forward failed: \(m)"
        case .Io(let m):                    return "I/O error: \(m)"
        }
    }

    static func sshCode(_ err: SshError) -> String {
        switch err {
        case .Dial:                  return "dial"
        case .Handshake:             return "handshake"
        case .HostKeyRejected:       return "host_key_rejected"
        case .AuthFailed:            return "auth_failed"
        case .DockerMissing:         return "docker_missing"
        case .DockerPermission:      return "docker_permission"
        case .PortConflict:          return "port_conflict"
        case .HarnessStartTimeout:   return "harness_start_timeout"
        case .BootstrapExitCode:     return "bootstrap_exit"
        case .BootstrapParse:        return "bootstrap_parse"
        case .PortForward:           return "port_forward"
        case .Io:                    return "io"
        }
    }

    static func connectionReasonCode(from reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized") {
            return "auth_expired"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "timeout"
        }
        if lower.contains("refused") {
            return "ws_refused"
        }
        if lower.contains("network") {
            return "network_unavailable"
        }
        return "disconnected"
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

/// Bridges the Rust SSH layer's TOFU callback into the SwiftUI sheet.
/// The Rust side invokes `acceptHostKey(fingerprint:)` synchronously on a
/// background runtime thread; we either short-circuit on a previously
/// trusted fingerprint or block via a semaphore while the user taps
/// Accept/Reject on the main actor.
final class SshHostKeyBridge: SshHostKeyDelegate {
    private weak var store: SessionStore?
    private let host: String
    private let port: UInt16

    init(store: SessionStore, host: String, port: UInt16) {
        self.store = store
        self.host = host
        self.port = port
    }

    func acceptHostKey(fingerprint: String) -> Bool {
        if let trusted = SshHostKeyTrustStore.known(host: host, port: port), trusted == fingerprint {
            return true
        }
        let sem = DispatchSemaphore(value: 0)
        var decision = false
        let host = self.host
        let port = self.port
        Task { @MainActor in
            guard let store = self.store else {
                sem.signal()
                return
            }
            store.presentHostKeyPrompt(host: host, port: port, fingerprint: fingerprint) { accepted in
                decision = accepted
                sem.signal()
            }
        }
        sem.wait()
        return decision
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
