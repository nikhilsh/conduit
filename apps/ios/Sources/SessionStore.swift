import Foundation
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

/// Wire shape of `GET /api/session/conversation/<id>` (broker PR #196).
/// The persisted transcript is a flat list of role/content/ts/files
/// rows — the same `conversation.jsonl` the broker replays into a live
/// WS, exposed read-only over HTTP for exited sessions.
struct RemoteConversationFile: Codable, Equatable {
    var path: String
    var rev: String?
}

struct RemoteConversationItem: Codable, Equatable {
    var role: String
    var content: String
    var ts: String?
    var files: [RemoteConversationFile]?
}

struct RemoteConversation: Codable, Equatable {
    var items: [RemoteConversationItem]
}

/// Raised by `fetchConversation` when the broker has no persisted
/// transcript for the session — either the session predates the #196
/// redeploy (the `conversation.jsonl` was never written) or the id is
/// unknown. The viewer renders a friendly "no saved transcript" state
/// for this case instead of a generic error.
struct ConversationNotFoundError: LocalizedError {
    var errorDescription: String? { "No saved transcript for this session." }
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

/// One pinned context (file, URL, or snippet) that the composer
/// surfaces as a chip above the text field. The payload is what the
/// next `sendChat` should fold into the outgoing message; `label` is
/// the short string the chip renders. Identifiable so chip rows can
/// animate inserts/removes cleanly with `ForEach`.
struct PinnedContext: Identifiable, Equatable {
    enum Kind: String, Equatable, Codable {
        case file
        case url
        case snippet
    }
    let id: UUID
    let kind: Kind
    let label: String
    let payload: String

    init(id: UUID = UUID(), kind: Kind, label: String, payload: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.payload = payload
    }

    /// SF Symbol used by the chip view. Centralized here so chip
    /// rendering is data-driven and the model is easy to test.
    var iconName: String {
        switch kind {
        case .file:    return "doc.text"
        case .url:     return "link"
        case .snippet: return "text.quote"
        }
    }
}

/// AI-generated quick replies for a session (task #233). `replies` are
/// the short tap-able strings the broker's one-shot model produced;
/// `forMessageID` ties them to the assistant message they were generated
/// for, so a stale set (from a turn the user has since moved past) can be
/// dropped. Parsed from the broker's `view:"quick_replies"` view_event.
struct AIQuickReplies: Equatable {
    var replies: [String]
    var forMessageID: String

    /// Decode the core's flattened `on_view_event` payload: `replies` is a
    /// JSON-array string, `for_message_id` is plain. Returns nil when the
    /// payload has no usable replies (the caller then clears the chips).
    static func from(payload: [String: String]) -> AIQuickReplies? {
        guard
            let raw = payload["replies"],
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let cleaned = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return AIQuickReplies(
            replies: Array(cleaned.prefix(4)),
            forMessageID: payload["for_message_id"] ?? ""
        )
    }
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

    /// AI-generated quick replies per session (task #233). The broker
    /// emits a `view:"quick_replies"` view_event when an assistant turn
    /// completes; the chat composer renders these as tap-able chips,
    /// replacing the old client-side heuristic. Cleared when the user
    /// sends or a fresh assistant turn arrives.
    var quickReplies: [String: AIQuickReplies] = [:]

    /// Manually pinned context per session — rendered above the
    /// composer as removable chips. PR ios-composer-parity introduces
    /// the data model and the manual `pinContext` API; a follow-up PR
    /// wires drag-from-Files and snippet-from-message into it.
    var pinnedContexts: [String: [PinnedContext]] = [:]

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

    /// Broker AI-generated session titles (task: ai-session-titles) — keyed
    /// by session id, value is the short title the broker minted from the
    /// conversation's purpose, delivered as a `view:"session_title"`
    /// view_event. SEPARATE from `displayNames` (manual rename) so a manual
    /// rename always wins in `displayName(for:)`; the AI title sits just
    /// below it, above the first-message fallback. Persisted in
    /// `UserDefaults` so a history row shows the AI name even before the
    /// broker re-emits it on attach.
    var brokerTitles: [String: String] = SessionStore.loadBrokerTitles() {
        didSet { SessionStore.persistBrokerTitles(brokerTitles) }
    }

    private var client: SweKittyClient?
    private var delegate: StoreDelegate?
    private var foregroundObserver: NSObjectProtocol?
    private var networkReachableObserver: NSObjectProtocol?
    private var networkInterfaceObserver: NSObjectProtocol?

    /// Shadow-write target: the shared Rust reducer (`core::store::SessionStoreCore`).
    /// In this PR the Swift maps above are still the read source of truth;
    /// every `ingest*` also folds the same event into `rustStore`, and a
    /// debug-build assertion in each ingest path verifies the two stay in
    /// sync. Flip `useRustStore` to false to bypass entirely if a later
    /// reducer change ships a regression — kill switch for safe rollout.
    /// PR follow-ups: (1) swap reads onto rustStore, (2) drop the Swift
    /// maps, (3) port the same shadow-write into Android `SessionStore.kt`.
    private let useRustStore = true
    let rustStore = SessionStoreCore()

    /// View-layer coordinator wired in by `SweKittyApp` so `ingestChat`
    /// can hand each terminal-shaped chat event to the streaming
    /// renderer. Optional because tests instantiate `SessionStore`
    /// without a SwiftUI host — the coordinator is then `nil` and the
    /// ingest path stays a no-op for the renderer side. ChatEvent has
    /// no id field; we synthesize a deterministic per-event key from
    /// (role, ts, content-hash) so the same event re-fed yields the
    /// same key (idempotent with the coordinator's update semantics).
    var streamingCoordinator: StreamingRendererCoordinator?

    /// Active per-user agent OAuth v2 coordinator. Set by the
    /// `LitterAgentLoginSheet` when the user taps "Login with …";
    /// inbound `agent_login_url` / `agent_login_complete` /
    /// `agent_login_failed` view_events are routed here so the
    /// coordinator's state machine can advance regardless of which
    /// screen owns the sheet. Cleared on `succeeded` / `failed` /
    /// `cancelled` so a second login attempt picks up a fresh
    /// coordinator instance. See `docs/PLAN-AGENT-OAUTH.md` "Approach
    /// v2" and the comment block on `AgentLoginCoordinator`.
    var activeLoginCoordinator: AgentLoginCoordinator?

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
    // (owned by SweKittyApp's @State), so the NotificationCenter
    // observers are released only at process exit — and Swift 6 actor
    // isolation forbids touching MainActor state from a nonisolated
    // deinit anyway. The path monitor itself now lives on
    // NetworkReachabilityObserver (also app-scoped).

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

        // Path-level reachability is owned by NetworkReachabilityObserver
        // (instantiated at app launch by SweKittyApp). We just listen for
        // the coarse `unsatisfied→satisfied` and `interface-changed`
        // edges and nudge the Rust core into immediate reconnect. The
        // old inline `NWPathMonitor` lived here; A.9 hoisted it so the
        // state machine is independently testable.
        networkReachableObserver = NotificationCenter.default.addObserver(
            forName: .networkBecameReachable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.nudgeNetworkChange()
        }
        networkInterfaceObserver = NotificationCenter.default.addObserver(
            forName: .networkInterfaceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.nudgeNetworkChange()
        }
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

    /// Fetch a session's persisted transcript read-only over HTTP
    /// (`GET /api/session/conversation/<id>`, broker PR #196). Mirrors
    /// `listDirectories`' direct-HTTP + bearer-auth pattern. Used by the
    /// Sessions screen to open an *exited* session — there's no live WS
    /// to replay from, so we read the broker's `conversation.jsonl`
    /// instead.
    ///
    /// The persisted rows are role/content/ts/files only; we map them
    /// into `ConversationItem` (kind `message` / `tool`, status `done`)
    /// so the existing chat renderer can display them unchanged.
    ///
    /// Throws `ConversationNotFoundError` on 404 — sessions created
    /// before the #196 redeploy never wrote a `conversation.jsonl`.
    func fetchConversation(sessionID: String) async throws -> [ConversationItem] {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/session/conversation/\(sessionID)"
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 103, userInfo: [NSLocalizedDescriptionKey: "Failed to build conversation URL"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "SessionStore", code: 104, userInfo: [NSLocalizedDescriptionKey: "Conversation fetch failed"])
        }
        if http.statusCode == 404 {
            throw ConversationNotFoundError()
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SessionStore", code: 104, userInfo: [NSLocalizedDescriptionKey: "Conversation fetch failed (\(http.statusCode))"])
        }
        let decoded = try JSONDecoder().decode(RemoteConversation.self, from: data)
        return decoded.items.enumerated().map { index, raw in
            let role = raw.role.lowercased()
            let kind = role == "tool" ? "tool" : "message"
            let files = (raw.files ?? []).map {
                ViewEventFile(path: $0.path, rev: $0.rev ?? "")
            }
            return ConversationItem(
                id: "saved-\(sessionID)-\(index)",
                role: raw.role,
                kind: kind,
                status: "done",
                content: raw.content,
                ts: raw.ts ?? "",
                files: files,
                toolName: nil,
                command: nil,
                exitCode: nil,
                durationMs: nil,
                diffSummary: nil,
                pendingOptions: []
            )
        }
    }

    /// Terminate AND remove a session on the broker over HTTP
    /// (`DELETE /api/session/<id>`). Mirrors `fetchConversation`'s
    /// direct-HTTP + bearer-auth pattern.
    ///
    /// Unlike the WS `exit` control (which only kills the agent process
    /// and leaves the session recoverable on disk — the bug that made
    /// broker sessions accumulate), this endpoint stops the process, kills
    /// the per-session tmux session, drops the session from the broker's
    /// live set, and archives the on-disk dir out of the active list.
    /// Idempotent server-side: a 200 also covers already-gone sessions.
    ///
    /// Works for exited sessions too — there's no live WS handle required,
    /// just the endpoint + bearer token. The conversation transcript stays
    /// reachable via `fetchConversation` (the broker preserves it under
    /// `archived-sessions/<id>`).
    func deleteSession(sessionID: String) async throws {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/session/\(sessionID)"
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 105, userInfo: [NSLocalizedDescriptionKey: "Failed to build delete URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SessionStore", code: 106, userInfo: [NSLocalizedDescriptionKey: "Session delete failed (\(code))"])
        }
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
                self.sshBootstrapState = .running(message: "Starting server on \(host)…")
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
        // Bug #1: tapping the active server pill used to call
        // `disconnect()`+`connect()` unconditionally. That tore down
        // the live `SweKittyClient` and the subsequent `refreshSessions`
        // observed an empty `list_sessions()` (the fresh Rust client
        // has no `SessionStatus` deltas yet), wiping the visible
        // session list until status frames trickled back in. If the
        // endpoint hasn't actually changed AND we're already linked
        // we just persist the default flag and bail — no need to
        // bounce the socket.
        let endpointChanged = endpoint != server.endpoint
        endpoint = server.endpoint
        if autoConnect {
            if endpointChanged || !harness.isReachable {
                disconnect()
                connect()
            }
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

    /// Drop a saved server entirely — removes the row from `savedServers`,
    /// clears any locally-stored display-name override keyed by that id,
    /// and persists both to disk (Keychain + UserDefaults). Idempotent;
    /// safe to call with an unknown id.
    ///
    /// This is the entry point UI affordances (swipe-to-delete in
    /// Settings, "Forget" context-menu on the server pill) call. It
    /// builds on `removeSavedServer` for the savedServers + endpoint
    /// bookkeeping but additionally sweeps the display-name override —
    /// without that step a stale rename for a `SavedServer.id` we just
    /// dropped would linger in UserDefaults forever.
    func forgetServer(_ id: String) {
        removeSavedServer(id)
        if displayNames[id] != nil {
            displayNames[id] = nil
        }
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
        if useRustStore {
            rustStore.applyLifecycle(sessionId: pendingID, lifecycle: .creating)
        }
        Task {
            do {
                let id = try await client.createSession(assistant: assistant, branch: branch, reasoningEffort: nil, model: nil)
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
                if self.useRustStore {
                    self.rustStore.forgetSession(sessionId: pendingID)
                    self.rustStore.applyLifecycle(sessionId: id, lifecycle: .live)
                }
                self.harness = .live
                self.refreshSessions()
                self.selectedSessionID = id
                // PLAN-AGENT-OAUTH stage 2: now that we have an active
                // session WS (and therefore an authenticated route to
                // the broker), replay any Keychain-stored OAuth
                // credentials. Idempotent on the broker side
                // (last-writer-wins per PLAN §D.1); cheap no-op when
                // the Keychain is empty.
                self.replayStoredAgentCredentials()
            } catch {
                let detail = Self.describe(error)
                self.sessionLifecycle[pendingID] = .failed(detail)
                if self.useRustStore {
                    self.rustStore.applyLifecycle(
                        sessionId: pendingID,
                        lifecycle: .failedToStart(reason: detail)
                    )
                }
                self.sessionCreationError = detail
                if Self.isAuth(error) {
                    self.harness = .failed("Pairing expired. Scan a new QR code from the server.")
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
                    if self.useRustStore {
                        self.rustStore.forgetSession(sessionId: pendingID)
                    }
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
                    self.harness = .failed("Pairing expired. Scan a new QR code from the server.")
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

    /// Archive a session: END it on the broker (free server resources) but
    /// KEEP it in history as a read-only transcript. This is the home-list
    /// swipe action.
    ///
    /// Two-tier delete model (vs `permanentlyDelete`): archiving drops the
    /// row from the *live* `sessions` list and issues the authoritative
    /// broker DELETE (kills agent + tmux, archives the on-disk dir under
    /// `archived-sessions/<id>`), but it does NOT tombstone the session.
    /// Because the row stays in `SavedSessionsStore`, it keeps appearing in
    /// History — now no longer live, so `isReadOnly` is true and it opens
    /// read-only (#223); the broker preserves `conversation.jsonl`, so
    /// `fetchConversation` still serves the transcript.
    func archive(sessionID: String) {
        // Optimistic removal so the row disappears immediately. Previously
        // we cleared local state only *after* the async `exitSession` +
        // `refreshSessions` round-trip, so the row lingered until the
        // network call returned — it read as laggy/broken. Prune locally
        // first; `refreshSessions` re-pulls the live list afterward, so a
        // failed teardown self-corrects (the row reappears).
        sessions.removeAll { $0.id == sessionID }
        sessionLifecycle[sessionID] = nil
        if selectedSessionID == sessionID { selectedSessionID = nil }
        if useRustStore { rustStore.forgetSession(sessionId: sessionID) }
        // NOTE: deliberately NO `SavedSessionsStore.shared.remove(...)` here.
        // Archiving must leave the history row intact so it stays viewable
        // as a read-only transcript. Permanent removal lives in
        // `permanentlyDelete(sessionID:)`, invoked only from History.
        tearDownOnBroker(sessionID: sessionID, phase: "session_archive")
    }

    /// Permanently delete a session from the app's History. Tombstones the
    /// row (`SavedSessionsStore.remove` → `deletedIDs`) so it leaves
    /// History forever and a later broker re-report can never resurrect it,
    /// and also ends it on the broker (idempotent for already-archived /
    /// exited rows). This is the History-only "Delete permanently" action.
    ///
    /// NOTE: the broker's archived dir on disk is NOT purged here — the
    /// tombstone is purely app-side. Reaping `archived-sessions/<id>` on the
    /// server is a separate future enhancement (no broker endpoint yet).
    func permanentlyDelete(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        sessionLifecycle[sessionID] = nil
        if selectedSessionID == sessionID { selectedSessionID = nil }
        if useRustStore { rustStore.forgetSession(sessionId: sessionID) }
        // Delete is terminal: sweep the persistent "Resume" index AND record
        // the tombstone so a status/list refresh (the broker's tmux can
        // linger, #199) can never re-add the row to History.
        SavedSessionsStore.shared.remove(id: sessionID)
        tearDownOnBroker(sessionID: sessionID, phase: "session_delete")
    }

    /// Shared broker teardown for both archive + permanent-delete: closes
    /// the live WS handle (best-effort checkpoint flush) then issues the
    /// authoritative HTTP DELETE that kills the agent + tmux, drops the
    /// session from the broker's active set, and archives its on-disk dir.
    /// No live WS handle is required, so it also works for exited rows.
    private func tearDownOnBroker(sessionID: String, phase: String) {
        Task {
            // WS `exit` closes the live socket + flushes a checkpoint when
            // a session is attached. Best-effort: an exited session has no
            // live handle, and the HTTP DELETE below is the authoritative
            // teardown either way.
            if let client { try? await client.exitSession(sessionId: sessionID) }
            // Authoritative broker-side delete: kills the agent process +
            // tmux, removes the session from the broker's active set, and
            // archives its dir. Without this the broker kept recovering the
            // session on disk and the row reappeared / sessions piled up.
            do {
                try await self.deleteSession(sessionID: sessionID)
            } catch {
                Telemetry.capture(
                    error: error,
                    message: "iOS session teardown failed",
                    tags: ["surface": "ios", "phase": phase],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID]
                )
            }
            self.refreshSessions()
        }
    }

    // MARK: - Terminal / chat I/O

    func sendInput(sessionID: String, bytes: Data) {
        guard let client else { return }
        Task { try? await client.sendInput(sessionId: sessionID, data: bytes) }
    }

    /// Upload a composer attachment to the session's
    /// `<workspace>/uploads/<sessionID>/<filename>` via the core 0x01
    /// binary frame (`SweKittyClient.sendFile`). Awaited by the chat
    /// composer BEFORE the outgoing message is sent, so the bytes have
    /// landed by the time the agent reads the referenced upload path.
    /// Throws when there's no live transport or the WS write fails, so
    /// the caller can surface "upload failed" instead of sending a
    /// message that references a file the broker never received.
    func sendFile(sessionID: String, filename: String, mime: String, bytes: Data) async throws {
        guard let client else { throw SweKittyError.NotConnected(message: "no session transport") }
        try await client.sendFile(
            sessionId: sessionID,
            filename: filename,
            mime: mime,
            payload: bytes
        )
    }

    func sendChat(sessionID: String, message: String) {
        // Bug #2: previously this method returned early when `client`
        // was nil — that swallowed the optimistic local echo *and* the
        // outbound WS write, so typing into the composer simply
        // disappeared if the user happened to send during a reconnect
        // window. Always materialize the local echo first so the user
        // sees their own message, and only skip the outbound WS write
        // when we genuinely have no transport.
        //
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
        let localEvent = ChatEvent(role: "user", content: message, ts: now, files: [])
        chatLog[sessionID, default: []].append(localEvent)
        // The user has answered — clear the AI quick-reply chips so they
        // don't linger over the next turn (task #233).
        quickReplies[sessionID] = nil
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyChat(sessionId: sessionID, event: localEvent)
        }
        guard let client else { return }
        // Don't swallow the send failure with `try?`: if the WS write
        // throws (no session handle yet, reconnect window, NotConnected),
        // the optimistic local echo above makes the message *look* sent
        // while the agent never receives it — exactly the device-reported
        // "appears in chat but the agent never sees it". Surface it so the
        // failure is diagnosable instead of silent.
        Task {
            do {
                try await client.sendChat(sessionId: sessionID, msg: message)
            } catch {
                Telemetry.capture(
                    error: error,
                    message: "chat send to agent failed",
                    tags: ["surface": "ios", "phase": "chat_send"],
                    extras: ["session": sessionID]
                )
            }
        }
    }

    func resize(sessionID: String, rows: UInt16, cols: UInt16) {
        guard let client else { return }
        Task { try? await client.resize(sessionId: sessionID, rows: rows, cols: cols) }
    }

    // MARK: - Agent credentials (PLAN-AGENT-OAUTH stage 2)

    /// Ship the per-user agent OAuth credential to the broker over the
    /// existing authenticated WS. The Rust transport picks any active
    /// session handle (the broker's set_agent_credentials handler keys
    /// the stored blob by bearer-token identity, not per-session — see
    /// docs/PLAN-AGENT-OAUTH.md §D.1).
    ///
    /// Encodes the credential's **native on-disk shape** as JSON (the
    /// inner `AuthDotJson` for OpenAI, the inner `ClaudeCredentialsJson`
    /// for Anthropic). The broker's parser at
    /// `broker/internal/ws/server.go:handleSetAgentCredentials` reads
    /// `credential` as `json.RawMessage` and persists it verbatim, so
    /// staying byte-for-byte aligned with what the agent CLI writes to
    /// disk means the broker can pass it through without translation.
    ///
    /// Throws `SweKittyError.NotConnected` if no session is live; the
    /// caller is expected to keep the Keychain copy and surface a
    /// retry affordance (the Settings → Agent accounts "Sync to broker"
    /// row, or wait for the next `createSession` to fire the resend).
    func sendAgentCredentials(provider: OAuthProvider, credential: OAuthCredential) async throws {
        guard let client else {
            throw SweKittyError.NotConnected(message: "no active swe-kitty client")
        }
        let json = try Self.encodeCredentialAsJSONString(credential)
        try await client.setAgentCredentials(
            provider: provider.rawValue,
            credentialJson: json
        )
    }

    // MARK: - Agent OAuth login v2 (outbound)
    //
    // Forward the three v2 login control frames through the Rust core's
    // UDL surface. Like `sendAgentCredentials`, the flow is identity-
    // scoped, so the core carries each frame over any live session WS;
    // broker handlers are live (PR #114) and progress returns as
    // `agent_login_*` view-events routed by `routeAgentLoginViewEvent`.
    // Throws `SweKittyError.NotConnected` if no session is live — the
    // coordinator surfaces it to the sheet as `.failed`.

    func sendAgentLoginStart(provider: String) async throws {
        guard let client else {
            throw SweKittyError.NotConnected(message: "no active swe-kitty client")
        }
        try await client.startAgentLogin(provider: provider)
    }

    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {
        guard let client else {
            throw SweKittyError.NotConnected(message: "no active swe-kitty client")
        }
        try await client.agentLoginCallback(sessionToken: sessionToken, queryString: queryString)
    }

    func sendAgentLoginCancel(sessionToken: String) async throws {
        guard let client else {
            throw SweKittyError.NotConnected(message: "no active swe-kitty client")
        }
        try await client.cancelAgentLogin(sessionToken: sessionToken)
    }

    /// Encode the credential's native blob to a JSON string suitable
    /// for the wire envelope's `credential` field. Hoisted as a
    /// `static` so the envelope-shape test in
    /// `AgentCredentialEnvelopeTests` can call it without spinning up a
    /// `SessionStore`.
    ///
    /// Why the inner blob and not the enum: the broker writes the bytes
    /// to disk byte-for-byte as `~/.codex/auth.json` /
    /// `~/.claude/.credentials.json`; the discriminated-enum wrapping we
    /// use locally would force the broker to peel a layer it doesn't
    /// care about. Same encoding shape as `AgentLoginSheet`'s
    /// `logCredentialToConsole` (PR #100) so the spike-time
    /// console-eyeball output is exactly what travels the wire.
    nonisolated static func encodeCredentialAsJSONString(_ credential: OAuthCredential) throws -> String {
        let encoder = JSONEncoder()
        let data: Data
        switch credential {
        case .openai(let blob):    data = try encoder.encode(blob)
        case .anthropic(let blob): data = try encoder.encode(blob)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SessionStore.sendAgentCredentials",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "credential JSON utf8 encode failed"]
            )
        }
        return string
    }

    // MARK: - Agent OAuth v2 (litter pattern) transport
    //
    // The v2 flow (docs/PLAN-AGENT-OAUTH.md "Approach v2") drives the
    // OAuth dance broker-side: the iOS app sends a `start_agent_login`
    // control message, the broker spawns the CLI subprocess + emits an
    // `agent_login_url` view_event, the app opens that URL in
    // `ASWebAuthenticationSession`, captures the loopback callback on
    // 127.0.0.1, and ships the raw query string back via
    // `agent_login_callback`. The broker waits for the CLI to mint
    // tokens and emits `agent_login_complete`.
    //
    // The send-side wiring requires UDL surface
    // (`SweKittyClient.start_agent_login` etc.) that hasn't shipped in
    // the SweKittyCore xcframework yet — the broker (PR #114) is live
    // but the Rust→Swift bridge is the missing link. Until that lands,
    // the transport methods throw a typed "not yet bridged" error so
    // the coordinator's state machine resolves to `.failed(...)` with
    // an actionable message instead of hanging forever. The inbound
    // dispatch sites below are already wired so the moment the Rust
    // bridge lands the flow is one method-body update away from green.

    /// Dispatch an inbound `agent_login_*` view_event to the active
    /// coordinator. Called from the WS receive path (see
    /// `dispatchViewEvent(_:)`). No-op when no coordinator is bound —
    /// late deliveries after `cancel()` are silently dropped, same as
    /// the broker side's stale-token handling in `login_session.go`.
    func routeAgentLoginViewEvent(kind: String, payload: [String: String]) {
        guard let coordinator = activeLoginCoordinator else { return }
        switch kind {
        case "agent_login_url":
            guard
                let portStr = payload["loopback_port"], let port = UInt16(portStr),
                let token = payload["session_token"],
                let urlStr = payload["url"], let url = URL(string: urlStr)
            else { return }
            coordinator.handleAgentLoginURL(loopbackPort: port, sessionToken: token, authorizeURL: url)
        case "agent_login_complete":
            coordinator.handleAgentLoginComplete()
            activeLoginCoordinator = nil
        case "agent_login_failed":
            let reason = payload["reason"] ?? "broker reported failure"
            coordinator.handleAgentLoginFailed(reason: reason)
            activeLoginCoordinator = nil
        default:
            break
        }
    }

    /// Re-send any Keychain-stored agent credentials over the (now
    /// live) WS. Called after `createSession` succeeds so a brand-new
    /// pairing immediately gets the user's tokens — without waiting
    /// for the user to navigate to Settings.
    ///
    /// Best-effort: errors are logged via Telemetry but never bubbled
    /// up to the UI, because the Keychain copy is canonical (the broker
    /// just mirrors it). Idempotent on the broker side
    /// (last-writer-wins per PLAN §D.1).
    fileprivate func replayStoredAgentCredentials() {
        for provider in [OAuthProvider.openai, .anthropic] {
            guard let credential = OAuthCredentialStore.load(provider: provider) else { continue }
            Task { @MainActor in
                do {
                    try await self.sendAgentCredentials(provider: provider, credential: credential)
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "iOS agent credential replay failed",
                        tags: [
                            "surface": "ios",
                            "phase": "agent_credentials_replay",
                            "provider": provider.rawValue,
                        ],
                        extras: ["detail": String(describing: error)]
                    )
                }
            }
        }
    }

    /// Upload a file to the session via the 0x01 binary WS frame
    /// (sweswe-parity #file-upload). The broker lands the bytes under
    /// `<workspace>/uploads/<sessionID>/<filename>` and emits a tool
    /// view_event when it's done — that's what surfaces back as a
    /// chat-tab notification, no inline message needed.
    func sendFile(sessionID: String, filename: String, mime: String, payload: Data) {
        guard let client else { return }
        Task {
            try? await client.sendFile(
                sessionId: sessionID,
                filename: filename,
                mime: mime,
                payload: payload
            )
        }
    }

    // MARK: - Pinned context

    /// Pin a context chip onto `sessionID`. No-op if an identical
    /// chip (same kind + payload) is already pinned — keeps the UI
    /// from accumulating duplicates when the same file is dragged
    /// in twice.
    func pinContext(_ ctx: PinnedContext, for sessionID: String) {
        var list = pinnedContexts[sessionID] ?? []
        guard !list.contains(where: { $0.kind == ctx.kind && $0.payload == ctx.payload }) else { return }
        list.append(ctx)
        pinnedContexts[sessionID] = list
    }

    /// Remove a pinned context by id. Used by ContextBar's tap-to-
    /// dismiss affordance.
    func unpinContext(_ id: UUID, from sessionID: String) {
        guard var list = pinnedContexts[sessionID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            pinnedContexts.removeValue(forKey: sessionID)
        } else {
            pinnedContexts[sessionID] = list
        }
    }

    // MARK: - Internal

    fileprivate func refreshSessions() {
        guard let client else { return }
        // Drop any session the user has explicitly deleted. The deployed
        // broker keeps tmux-backed PTYs alive (#199), so `listSessions`
        // can keep reporting a just-deleted session — without this filter
        // it would reappear in the home list and (because its tmux is
        // live) read as interactive. The client-side tombstone is the
        // guarantee that delete is terminal regardless of broker state.
        let listed = client.listSessions()
            .filter { !SavedSessionsStore.shared.isTombstoned(id: $0.id) }
        // Bug #1 follow-up: a fresh client returns `[]` until the
        // first `SessionStatus` delta lands, so blindly assigning
        // `self.sessions = listed` would briefly hide the existing
        // rows on every reconnect. Replace only when we have at
        // least one entry; otherwise keep the prior list visible
        // and let subsequent status frames refresh it incrementally.
        if !listed.isEmpty {
            self.sessions = listed
        }
        // Do NOT blanket-default listed sessions to `.live`. `listSessions`
        // can include recovered / exited / not-currently-running rows, and
        // a default of `.live` made every one of them open interactive
        // (the "History still interactive" bug). Liveness is now proven by
        // a live-phase status delta (`ingestStatus`) or the create/attach
        // round-trip — never by mere presence in the list. We seed a
        // terminal lifecycle from the listed phase when we can already see
        // the session is dead, so `isReadOnly` is correct on first paint
        // even before a fresh status frame arrives.
        for s in self.sessions where sessionLifecycle[s.id] == nil {
            if let phase = statusBySession[s.id]?.phase,
               phase.lowercased().hasPrefix("exited") {
                sessionLifecycle[s.id] = .exited(Self.exitCode(fromPhase: phase) ?? 0)
            }
        }
        for s in self.sessions {
            refreshConversation(sessionID: s.id)
        }
    }

    // `internal` access (not `fileprivate`) so SweKittyTests can drive
    // the parity tests in SessionStoreRustParityTests. Same rationale
    // as `ingestChat` / `ingestStatus`.
    func ingestPtyData(_ sessionID: String, _ bytes: Data) {
        terminalBuffer[sessionID, default: Data()].append(bytes)
        if useRustStore {
            // Synthesize the session in Rust if Swift hasn't seen it yet —
            // PTY data can race ahead of `register_session` from
            // `create_session`. Without the placeholder the `apply_pty_data`
            // returns nil and the parity check below would falsely fail.
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyPtyData(sessionId: sessionID, data: bytes)
            #if DEBUG
            assertRustScrollbackParity(sessionID)
            #endif
        }
    }

    // `internal` (not `fileprivate`) so SweKittyTests can drive this
    // path directly. The fileprivate access was originally to lock
    // down "only the transport delegate can ingest"; that constraint
    // is fine to relax for tests because the type guards (ChatEvent)
    // make malformed calls a compile error anyway.
    /// Ingest a broker-generated quick-reply set for a session (task
    /// #233). Replaces any prior set; an unusable payload (no replies)
    /// clears the chips. Mirrored on Android in `ingestQuickReplies`.
    func ingestQuickReplies(_ sessionID: String, payload: [String: String]) {
        if let qr = AIQuickReplies.from(payload: payload) {
            quickReplies[sessionID] = qr
        } else {
            quickReplies[sessionID] = nil
        }
    }

    func ingestChat(_ sessionID: String, _ event: ChatEvent) {
        chatLog[sessionID, default: []].append(event)
        // A fresh user/assistant turn invalidates the previous turn's AI
        // chips — clear them so stale suggestions don't linger. The
        // broker emits the new set after the assistant turn completes.
        quickReplies[sessionID] = nil
        refreshConversation(sessionID: sessionID)
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyChat(sessionId: sessionID, event: event)
            #if DEBUG
            assertRustChatLogParity(sessionID)
            #endif
        }
        // Notify the streaming renderer that an assistant turn landed.
        // The harness delivers `ChatEvent`s whole (no per-token deltas
        // yet — see broker/transport), so every ingest is the terminal
        // chunk for that fingerprint. The coordinator is keyed by
        // `ConversationItem.id`; we mirror the same id resolution the
        // view will use by matching role+content against the freshly
        // refreshed conversation log. When the broker grows real
        // streaming this is where the partial deltas will land.
        if let coordinator = streamingCoordinator, event.role == "assistant" {
            let fingerprint = "\(event.role)|\(event.content)"
            let id = conversationLog[sessionID]?
                .last(where: { "\($0.role)|\($0.content)" == fingerprint })?
                .id ?? "chat-\(sessionID)-\(event.ts)"
            coordinator.update(itemID: id, content: event.content, isComplete: true)
        }
    }

    fileprivate func refreshConversation(sessionID: String) {
        guard let client else { return }
        if let items = try? client.listConversationItems(sessionId: sessionID) {
            // Preserve locally-echoed `local-*` items not yet reflected by
            // the server (matched by role+content). Once the harness mirrors
            // the same text back under a server id, the local copy drops.
            //
            // Bug #3 nuance: the broker doesn't loop user messages back as
            // `on_chat_event`, so the user's `local-*` echo lives forever
            // in `stillPending`. Appending it *after* `items` would render
            // the assistant's reply above the user's prompt — confusing.
            // Splice by timestamp so order stays chronological.
            let existing = conversationLog[sessionID] ?? []
            let serverFingerprints = Set(items.map { "\($0.role)|\($0.content)" })
            let stillPending = existing.filter {
                $0.id.hasPrefix("local-") && !serverFingerprints.contains("\($0.role)|\($0.content)")
            }
            let merged = items + stillPending
            conversationLog[sessionID] = merged.sorted { $0.ts < $1.ts }
        }
    }

    // `internal` (not `fileprivate`) so SweKittyTests can drive this
    // path directly — same rationale as `ingestChat` above. The status
    // frame carries `reasoningEffort` / `cwd` / `startedAt` etc. and
    // a test confirms `statusBySession` reflects those fields end-to-end.
    func ingestStatus(_ status: SessionStatus) {
        statusBySession[status.session] = status
        if let p = status.preview { preview[status.session] = p }
        // Promote lifecycle from a non-terminal state using the phase the
        // broker actually reported — NOT a blanket `.live`. A status frame
        // for a recovered/exited session carries `phase: "exited…"`; that
        // must lock the row read-only, not resurrect it as interactive.
        // (`.exited` / `.failed` are terminal and never downgraded here.)
        switch sessionLifecycle[status.session] {
        case .none, .creating?:
            if Self.isLivePhase(status.phase) {
                sessionLifecycle[status.session] = .live
            } else if status.phase.lowercased().hasPrefix("exited") {
                // Surface an explicit exit even if we never saw an
                // `exit` frame — e.g. joining an already-dead session.
                let code = Self.exitCode(fromPhase: status.phase) ?? 0
                sessionLifecycle[status.session] = .exited(code)
            }
            // A non-live, non-exited phase (empty / unknown) leaves the
            // lifecycle unset → `isReadOnly` returns true (fail closed).
        case .live?:
            // Already live: a later exited phase still demotes to terminal.
            if status.phase.lowercased().hasPrefix("exited") {
                let code = Self.exitCode(fromPhase: status.phase) ?? 0
                sessionLifecycle[status.session] = .exited(code)
            }
        case .exited?, .failed?:
            break // terminal — never revived by a status delta
        }
        // Mirror a broker-supplied rename label (protocol §3.3) into
        // the local displayNames map so every existing title surface
        // (ThreadSwitcher, HomeScreen, SessionInfo) picks it up without
        // each having to re-read the status bag. Prefer `displayName`;
        // fall back to legacy `sessionName` for older brokers.
        let serverLabel = (status.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (status.sessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        // Only mirror a *meaningful* broker label. The broker frequently
        // echoes the bare session id as its `sessionName`/`displayName`;
        // mirroring that would re-pollute `displayNames` with a UUID and
        // resurrect the raw-id-as-title bug, so we drop any UUID-shaped or
        // id-equal label here.
        if let label = serverLabel,
           !SessionNaming.looksLikeRawID(label, sessionID: status.session),
           displayNames[status.session] != label {
            displayNames[status.session] = label
        }
        harness = .live
        refreshSessions()
        if useRustStore {
            // `apply_status` is the one reducer entry that synthesizes a
            // placeholder when the session id is unknown, so we don't
            // need to call `ensureRustSessionPresent` here.
            _ = rustStore.applyStatus(status: status)
            #if DEBUG
            assertRustStatusParity(status.session)
            #endif
        }
        recordSavedSession(forSessionID: status.session)
    }

    func ingestPreview(_ sessionID: String, _ p: PreviewInfo) {
        preview[sessionID] = p
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyPreview(sessionId: sessionID, preview: p)
            #if DEBUG
            assertRustPreviewParity(sessionID)
            #endif
        }
    }

    func ingestSnapshot(_ sessionID: String, _ gunzipped: Data) {
        // Replace terminal scrollback with the authoritative snapshot from the server.
        terminalBuffer[sessionID] = gunzipped
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applySnapshot(sessionId: sessionID, gunzipped: gunzipped)
            #if DEBUG
            assertRustScrollbackParity(sessionID)
            #endif
        }
    }

    func ingestExit(_ sessionID: String, _ code: Int32) {
        sessionLifecycle[sessionID] = .exited(code)
        recordSavedSession(forSessionID: sessionID, isExited: true)
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
                lastActivityAt: status.lastActivityAt,
                displayName: status.displayName
            )
            statusBySession[sessionID] = status
        }
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyExit(sessionId: sessionID, code: code)
            #if DEBUG
            assertRustLifecycleParity(sessionID)
            #endif
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
            harness = .failed("Pairing expired. Scan a new QR code from the server.")
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
                harness = .failed("Pairing expired. Scan a new QR code from the server.")
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

    // MARK: - Saved-session history

    /// Server-stable identity for the saved-session index. Prefer the
    /// id of the matching `SavedServer` row (carries through across
    /// renames / endpoint mutations); fall back to the endpoint host
    /// for pairings the user hasn't named yet. Stable enough for
    /// `(serverID, sessionID)` to identify a row across launches.
    private var savedHistoryServerID: String {
        if let server = savedServers.first(where: { $0.endpoint == endpoint }) {
            return server.id
        }
        let host = endpoint.displayHost
        return host.isEmpty ? "(unsaved)" : host
    }

    /// Best-effort first user message for the session, scanning whichever
    /// of the typed `conversationLog` / raw `chatLog` actually carries it.
    private func firstUserMessage(in sessionID: String) -> String? {
        if let log = conversationLog[sessionID] {
            if let first = log.first(where: { $0.role.lowercased() == "user" }) {
                return first.content
            }
        }
        if let chat = chatLog[sessionID] {
            if let first = chat.first(where: { $0.role.lowercased() == "user" }) {
                return first.content
            }
        }
        return nil
    }

    /// Fold the latest snapshot of `sessionID` into the persistent
    /// "Resume" index. Invoked from `ingestStatus` (on every status
    /// frame) and `ingestExit` (with `isExited: true` so the row locks
    /// into the terminal status). Idempotent — `SavedSessionsStore.upsert`
    /// suppresses writes when the row would be unchanged.
    private func recordSavedSession(forSessionID sessionID: String, isExited: Bool = false) {
        // We only have a meaningful `ProjectSession` for sessions the
        // live store has confirmed exist; placeholder lifecycle rows
        // (`pending-*`) don't carry an agent or cwd worth persisting.
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let status = statusBySession[sessionID]
        let exitedFromLifecycle: Bool
        if case .exited = sessionLifecycle[sessionID] {
            exitedFromLifecycle = true
        } else {
            exitedFromLifecycle = false
        }
        let messageCount = (conversationLog[sessionID]?.count)
            ?? (chatLog[sessionID]?.count)
            ?? 0
        SavedSessionsStore.shared.upsert(
            session: session,
            serverID: savedHistoryServerID,
            status: status,
            firstUserMessage: firstUserMessage(in: sessionID),
            messageCount: messageCount,
            isExited: isExited || exitedFromLifecycle
        )
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

    private static let brokerTitlesKey = "swekitty.session.brokerTitles"

    static func loadBrokerTitles() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: brokerTitlesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    static func persistBrokerTitles(_ titles: [String: String]) {
        if titles.isEmpty {
            UserDefaults.standard.removeObject(forKey: brokerTitlesKey)
            return
        }
        if let data = try? JSONEncoder().encode(titles) {
            UserDefaults.standard.set(data, forKey: brokerTitlesKey)
        }
    }

    /// Ingest a broker AI session title (task: ai-session-titles). Stores
    /// the title for the session so every title surface (home list,
    /// history, session header) picks it up live. A blank/empty title is
    /// ignored so we never clobber a good name. Mirrored on Android in
    /// `ingestSessionTitle`.
    func ingestSessionTitle(_ sessionID: String, payload: [String: String]) {
        guard let title = payload["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        brokerTitles[sessionID] = title
    }

    /// Friendly, user-facing name for a session. NEVER returns the raw
    /// UUID. Priority (see `SessionNaming`):
    ///   1. A genuine user-set custom name — one the user typed, never a
    ///      UUID. We screen `displayNames[id]` because the broker also
    ///      mirrors its `sessionName`/`displayName` label here, and that
    ///      label is frequently the bare session id.
    ///   2. The broker AI-generated title (`brokerTitles[id]`), once the
    ///      broker has minted one from the conversation's purpose.
    ///   3. The first user chat message (live: scanned from
    ///      `conversationLog`), trimmed to a short single line.
    ///   4. Fallback: `"<agent> · <relative start time>"`.
    func displayName(for session: ProjectSession) -> String {
        if let custom = displayNames[session.id],
           !SessionNaming.looksLikeRawID(custom, sessionID: session.id) {
            return custom
        }
        if let aiTitle = brokerTitles[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aiTitle.isEmpty,
           !SessionNaming.looksLikeRawID(aiTitle, sessionID: session.id) {
            return aiTitle
        }
        if let message = firstUserMessage(in: session.id),
           let title = SessionNaming.titleFromMessage(message) {
            return title
        }
        return SessionNaming.fallbackName(
            agent: session.assistant,
            startedAt: session.startedAt ?? session.lastActivityAt
        )
    }

    /// Whether a session is read-only — there's no live WS to interact
    /// with, so the `ProjectView` collapses to a chat-only, composer-less
    /// transcript (the user can read the log but can't type, switch tabs,
    /// etc.).
    ///
    /// READ-ONLY IS THE DEFAULT. A session opens interactive only when
    /// we can positively confirm it is *currently live on the broker* —
    /// i.e. `isConfirmedLive(sessionID:)`. Everything else (exited,
    /// failed, recovered-but-not-running, archived, or a stale row we
    /// merely listed without a fresh running status) is read-only.
    ///
    /// This inversion fixes the "History still interactive" bug: the old
    /// logic defaulted to interactive and only flipped read-only on a
    /// *confirmed-exited* signal (lifecycle `.exited` or a status phase
    /// of `exited…`). But `refreshSessions` / `ingestStatus` blanket
    /// marked every listed or status-bearing session `.live`, so a dead
    /// session the broker never explicitly reported as exited (app was
    /// disconnected when it died, a recovered session, a phase the broker
    /// reports as non-running) stayed interactive forever. We now require
    /// proof of liveness rather than proof of death.
    func isReadOnly(sessionID: String) -> Bool {
        !isConfirmedLive(sessionID: sessionID)
    }

    /// True only when the session is positively known to be running on
    /// the broker *right now*. Requires BOTH:
    ///   1. a non-terminal local lifecycle (`.live` / `.creating` — never
    ///      `.exited` / `.failed`), and
    ///   2. a current broker status whose `phase` is a live/running phase
    ///      (see `Self.isLivePhase`). A session with no status at all is
    ///      treated as not-confirmed-live: we listed it but the broker
    ///      hasn't told us it's running.
    ///
    /// `.creating` is honored without a status because a brand-new
    /// session we just spun up locally has no broker status yet but is
    /// genuinely on its way live — the create round-trip owns that state.
    func isConfirmedLive(sessionID: String) -> Bool {
        switch sessionLifecycle[sessionID] {
        case .exited, .failed, .none:
            return false
        case .creating:
            // Newly-created session mid-handshake: interactive, even
            // before the first status frame. A confirmed-exited phase
            // (raced ahead) still wins.
            if let phase = statusBySession[sessionID]?.phase,
               !Self.isLivePhase(phase) {
                return false
            }
            return true
        case .live:
            // `.live` is necessary but not sufficient — it can be a
            // stale default. Demand a current running phase if we have a
            // status; if we somehow have a `.live` lifecycle with no
            // status (e.g. a freshly-created session promoted by the
            // create path) trust the lifecycle.
            guard let phase = statusBySession[sessionID]?.phase else {
                return true
            }
            return Self.isLivePhase(phase)
        }
    }

    /// Classify a broker `SessionStatus.phase` as live/running vs
    /// terminal/unknown. The broker reports `running` for an active
    /// agent and `exited` (optionally `exited(N)` after our own
    /// `ingestExit` rewrites it) for a dead one; recovered sessions
    /// restore whatever phase was persisted. We treat anything that
    /// isn't an affirmatively-running phase as NOT live so an unfamiliar
    /// or empty phase fails closed (read-only) rather than open.
    static func isLivePhase(_ phase: String) -> Bool {
        let p = phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.isEmpty { return false }
        if p.hasPrefix("exited") || p.hasPrefix("failed") || p.hasPrefix("dead") {
            return false
        }
        // Known running/active phases emitted by the broker + adapters.
        let live: Set<String> = [
            "running", "ready", "idle", "thinking", "working",
            "starting", "booting", "swapping",
        ]
        return live.contains(p)
    }

    /// Pull the exit code out of an `exited(N)` phase string. The broker
    /// emits a bare `exited`; our own `ingestExit` rewrites the cached
    /// status to `exited(<code>)`. Returns nil when there's no parseable
    /// code (caller defaults to 0).
    static func exitCode(fromPhase phase: String) -> Int32? {
        guard let open = phase.firstIndex(of: "("),
              let close = phase.firstIndex(of: ")"),
              open < close else { return nil }
        let inner = phase[phase.index(after: open)..<close]
        return Int32(inner.trimmingCharacters(in: .whitespaces))
    }

    /// Switch the active session — drives the iPhone `NavigationStack`
    /// destination + the iPad detail pane. No reducer / Rust-core call;
    /// the existing `onChange(of: store.selectedSessionID)` in
    /// `HomeView` picks this up and pushes the target session.
    ///
    /// Lives here (not on a coordinator) so the multi-thread switcher
    /// in `ThreadSwitcherSheet` and any future "jump to thread" deep
    /// link have one place to call. Mirrors litter's
    /// `ConversationThreadSwitcher` semantics. PR H owns the reducer
    /// path; this is the navigation-level setter only.
    func switchTo(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID })
            || sessionLifecycle[sessionID] != nil
        else {
            // No-op if the target doesn't exist — guards against a
            // stale row tap after a session exited and was reaped.
            return
        }
        selectedSessionID = sessionID
    }

    /// Attach to a session that's still LIVE on the broker but isn't in
    /// our local live set yet — the "open a historical row" path from
    /// `SessionsScreen`. The session list on a fresh client is empty
    /// until status frames trickle back (see `refreshSessions`), so we
    /// can't `switchTo` synchronously; instead we `join_session` (which
    /// opens the WS for an existing id — the same `open_session` route
    /// `create_session` takes) and then poll until the row materializes
    /// before navigating.
    ///
    /// Idempotent: if the session is already live locally we just
    /// `switchTo` and return. Assumes the caller has already selected
    /// the right saved server.
    func attachLiveSession(sessionID: String, assistant: String) {
        if sessions.contains(where: { $0.id == sessionID }) {
            switchTo(sessionID: sessionID)
            return
        }
        Task { @MainActor in
            do {
                try await waitUntilCommandReady()
                guard let client else { return }
                // Mark creating so the home list shows the row as
                // attaching rather than vanishing during the round-trip.
                if sessionLifecycle[sessionID] == nil {
                    sessionLifecycle[sessionID] = .creating
                }
                try await client.joinSession(sessionId: sessionID, assistant: assistant)
                self.refreshSessions()
                // Poll briefly for the joined session to surface in
                // `list_sessions()` (it lands as soon as `open_session`
                // inserts it, but status frames can lag). Once present,
                // promote to live + navigate.
                let pollNs: UInt64 = 100_000_000
                var elapsedNs: UInt64 = 0
                let timeoutNs: UInt64 = 6_000_000_000
                while !self.sessions.contains(where: { $0.id == sessionID }),
                      elapsedNs < timeoutNs {
                    try await Task.sleep(nanoseconds: pollNs)
                    elapsedNs += pollNs
                    self.refreshSessions()
                }
                if self.sessions.contains(where: { $0.id == sessionID }) {
                    // Promote the placeholder using the broker's reported
                    // phase, not a blanket `.live`. Joining an existing id
                    // can resolve to a session that already exited; in that
                    // case `ingestStatus` has set `.exited` (so we're no
                    // longer `.creating` and skip this), or — if no status
                    // landed yet but the cached phase is terminal — we lock
                    // it read-only here. Otherwise promote to live and the
                    // destination opens interactive. Either way navigate so
                    // the user lands on the (correctly read-only or live)
                    // session rather than a dead-end.
                    if self.sessionLifecycle[sessionID] == .creating {
                        let phase = self.statusBySession[sessionID]?.phase
                        if let phase, phase.lowercased().hasPrefix("exited") {
                            let code = Self.exitCode(fromPhase: phase) ?? 0
                            self.sessionLifecycle[sessionID] = .exited(code)
                        } else if phase.map(Self.isLivePhase) ?? true {
                            // Live phase, or no status yet (a join we
                            // initiated — trust it as live until a status
                            // frame says otherwise).
                            self.sessionLifecycle[sessionID] = .live
                        }
                        // A non-live, non-exited phase leaves `.creating`
                        // in place; the next status frame resolves it.
                    }
                    self.selectedSessionID = sessionID
                } else if self.sessionLifecycle[sessionID] == .creating {
                    // Never showed up — clear the placeholder so the
                    // list doesn't keep a stuck "attaching" row.
                    self.sessionLifecycle[sessionID] = nil
                }
            } catch {
                if self.sessionLifecycle[sessionID] == .creating {
                    self.sessionLifecycle[sessionID] = nil
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS attach live session failed",
                    tags: ["surface": "ios", "phase": "attach_session"],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID]
                )
            }
        }
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
    /// The fork can target a different reasoning effort and/or model than
    /// the original — both are optional overrides that ride through the
    /// core's `create_session` to the broker, which applies them to the
    /// new agent's CLI flags. nil for either means "same as the original"
    /// (the broker falls back to the adapter default). Reasoning effort
    /// can't be changed mid-session — that's why this is a fork (new
    /// session), not a live switch.
    func forkSession(sessionID: String, reasoningEffort: String? = nil, model: String? = nil) {
        guard let original = sessions.first(where: { $0.id == sessionID }) else { return }
        guard let client else { return }
        Task {
            do {
                let newID = try await client.createSession(
                    assistant: original.assistant,
                    branch: original.branch,
                    reasoningEffort: reasoningEffort,
                    model: model
                )
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
        throw NSError(domain: "SessionStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for server link"])
    }

    // MARK: - Rust shadow-store helpers

    /// Ensure the Rust store has at least a placeholder
    /// `ProjectSessionState` for `sessionID` before applying an event
    /// that would otherwise return nil. iOS' Swift maps tolerate
    /// "apply chat to an unknown session id" (they auto-vivify the
    /// dictionary entry); the Rust store only auto-vivifies on
    /// `apply_status`. Without this nudge, every `apply_chat` /
    /// `apply_pty_data` etc. that lands before the first `on_status`
    /// would silently no-op and the parity asserts would fail.
    fileprivate func ensureRustSessionPresent(_ sessionID: String) {
        guard !rustStore.contains(sessionId: sessionID) else { return }
        rustStore.registerSession(
            session: ProjectSession(
                id: sessionID,
                name: sessionID,
                assistant: statusBySession[sessionID]?.assistant ?? "claude",
                branch: nil,
                preview: preview[sessionID],
                reasoningEffort: statusBySession[sessionID]?.reasoningEffort,
                cwd: statusBySession[sessionID]?.cwd,
                startedAt: statusBySession[sessionID]?.startedAt,
                lastActivityAt: statusBySession[sessionID]?.lastActivityAt,
                displayName: statusBySession[sessionID]?.displayName
            )
        )
    }

    #if DEBUG
    /// Compare scrollback bytes Swift-side vs Rust-side for `sessionID`.
    /// Off in release builds so the FFI hop + memcmp cost doesn't ride
    /// every PTY frame. Reports a single assertionFailure with the size
    /// delta so the test breakpoint can land directly on it.
    fileprivate func assertRustScrollbackParity(_ sessionID: String) {
        let swiftBytes = terminalBuffer[sessionID] ?? Data()
        let rustBytes = rustStore.get(sessionId: sessionID)?.terminal.scrollback ?? Data()
        assert(
            swiftBytes == rustBytes,
            "Rust/Swift scrollback diverged for \(sessionID): swift=\(swiftBytes.count) rust=\(rustBytes.count)"
        )
    }

    fileprivate func assertRustChatLogParity(_ sessionID: String) {
        let swiftEvents = chatLog[sessionID] ?? []
        let rustEvents = rustStore.get(sessionId: sessionID)?.chat.events ?? []
        // Compare counts first — the cheap signal — then by role/content
        // tuple. We don't compare ts because the Rust dedup is on (role,
        // content, ts) and matches the Swift order one-to-one.
        assert(
            swiftEvents.count == rustEvents.count
                && zip(swiftEvents, rustEvents).allSatisfy {
                    $0.role == $1.role && $0.content == $1.content && $0.ts == $1.ts
                },
            "Rust/Swift chat log diverged for \(sessionID): swift=\(swiftEvents.count) rust=\(rustEvents.count)"
        )
    }

    fileprivate func assertRustStatusParity(_ sessionID: String) {
        let swiftStatus = statusBySession[sessionID]
        let rustStatus = rustStore.get(sessionId: sessionID)?.status
        assert(
            swiftStatus?.session == rustStatus?.session
                && swiftStatus?.phase == rustStatus?.phase
                && swiftStatus?.reasoningEffort == rustStatus?.reasoningEffort,
            "Rust/Swift status diverged for \(sessionID)"
        )
    }

    fileprivate func assertRustPreviewParity(_ sessionID: String) {
        let swiftPreview = preview[sessionID]
        let rustPreview = rustStore.get(sessionId: sessionID)?.browser.preview
        assert(
            swiftPreview?.port == rustPreview?.port
                && swiftPreview?.url == rustPreview?.url,
            "Rust/Swift preview diverged for \(sessionID)"
        )
    }

    fileprivate func assertRustLifecycleParity(_ sessionID: String) {
        // The Swift `SessionLifecycle` and Rust-bridged
        // `SessionLifecycleCore` are intentionally separate types (the
        // Swift one predates the FFI; their case names diverge —
        // `.failed` vs `.failedToStart`). Map for comparison.
        let swiftLifecycle = sessionLifecycle[sessionID]
        let rustLifecycle = rustStore.lifecycle(sessionId: sessionID)
        let parityOK: Bool
        switch (swiftLifecycle, rustLifecycle) {
        case (nil, nil): parityOK = true
        case (.creating?, .creating?): parityOK = true
        case (.live?, .live?): parityOK = true
        case let (.exited(swiftCode)?, .exited(code: rustCode)?):
            parityOK = swiftCode == rustCode
        case (.failed?, .failedToStart?): parityOK = true
        default: parityOK = false
        }
        assert(parityOK, "Rust/Swift lifecycle diverged for \(sessionID)")
    }
    #endif
}

private extension SessionStore {
    static let recentDirectoriesByServerKey = "swekitty.recentDirectoriesByServer"

    static func shellQuoted(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    static func describe(_ error: Error) -> String {
        if isAuth(error) {
            return "Authentication failed. This pairing token has expired; scan a fresh QR code from the server."
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
        case .HarnessStartTimeout(let m):   return "Server took too long to come up: \(m)"
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

// MARK: - AgentLoginTransport (Approach v2)
//
// `AgentLoginCoordinator` ships the outbound control envelopes via this
// protocol; each method forwards through the SessionStore's Rust client
// (`startAgentLogin` / `agentLoginCallback` / `cancelAgentLogin`, bridged
// over UDL). The broker handlers are live (PR #114) and the inbound
// dispatch path (`routeAgentLoginViewEvent`) consumes the `agent_login_*`
// view-events, so the flow is now end-to-end.
//
// Concrete `AgentLoginTransport` conformance is a thin actor-isolated
// wrapper around a SessionStore reference so the coordinator
// (`@MainActor`) and the protocol (`Sendable`) compose without
// dragging the store across actor boundaries.

/// Error raised when the v2 OAuth transport can't reach the store
/// (released) — the live-client `NotConnected` case is thrown by the
/// store methods themselves. Caught by `AgentLoginCoordinator` and
/// surfaced to the sheet as a `.failed(reason:)` state.
struct AgentLoginTransportError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// `AgentLoginTransport` impl backed by `SessionStore`. Kept as a
/// separate `final class` (not the store itself) so the `Sendable`
/// conformance can be `nonisolated` while the store stays
/// `@MainActor`.
final class SessionStoreAgentLoginTransport: AgentLoginTransport, @unchecked Sendable {
    private weak var store: SessionStore?

    init(store: SessionStore) { self.store = store }

    func sendStartAgentLogin(provider: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginStart(provider: provider)
    }

    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginCallback(sessionToken: sessionToken, queryString: queryString)
    }

    func sendCancelAgentLogin(sessionToken: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginCancel(sessionToken: sessionToken)
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
    func onViewEvent(sessionId: String, kind: String, payload: [String: String]) {
        Task { @MainActor in
            if kind == "quick_replies" {
                self.store?.ingestQuickReplies(sessionId, payload: payload)
            } else if kind == "session_title" {
                self.store?.ingestSessionTitle(sessionId, payload: payload)
            } else {
                self.store?.routeAgentLoginViewEvent(kind: kind, payload: payload)
            }
        }
    }
}
