import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct StoredEndpoint: Equatable {
    var url: String
    var token: String

    static let empty = StoredEndpoint(url: "", token: "")

    var isComplete: Bool { !url.isEmpty && !token.isEmpty }

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

@Observable
@MainActor
final class SessionStore {
    // Persisted endpoint (v1: UserDefaults; replaced by Keychain in task 009).
    var endpoint: StoredEndpoint {
        didSet { Self.persist(endpoint) }
    }

    var connection: ConnectionState = .disconnected
    var sessions: [ProjectSession] = []
    var selectedSessionID: String?

    /// Latest SessionStatus seen for each session — drives the health badge + agent badge.
    var statusBySession: [String: SessionStatus] = [:]

    /// Append-only terminal scrollback per session. TerminalTab observes this and
    /// re-feeds the SwiftTerm view on appear / after reconnect.
    var terminalBuffer: [String: Data] = [:]

    /// Chat log per session, oldest first.
    var chatLog: [String: [ChatEvent]] = [:]

    /// Last-known preview info per session (nil until the agent reports one).
    var preview: [String: PreviewInfo] = [:]

    private var client: SweKittyClient?
    private var delegate: StoreDelegate?

    init() {
        self.endpoint = Self.loadPersisted()
    }

    // MARK: - Connection

    func connect() {
        guard endpoint.isComplete else {
            connection = .failed("missing endpoint or token")
            return
        }
        connection = .connecting
        let newClient = SweKittyClient(endpoint: endpoint.url, bearerToken: endpoint.token)
        let newDelegate = StoreDelegate(store: self)
        self.client = newClient
        self.delegate = newDelegate
        Task {
            do {
                try await newClient.connect(delegate: newDelegate)
                self.connection = .connected
                self.refreshSessions()
            } catch {
                self.connection = .failed(String(describing: error))
            }
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        delegate = nil
        connection = .disconnected
    }

    // MARK: - Session lifecycle

    func createSession(assistant: String, branch: String? = nil) {
        guard let client else { return }
        Task {
            do {
                let id = try await client.createSession(assistant: assistant, branch: branch)
                self.refreshSessions()
                self.selectedSessionID = id
            } catch {
                self.connection = .failed("create_session: \(error)")
            }
        }
    }

    func switchAgent(sessionID: String, to assistant: String) {
        guard let client else { return }
        Task {
            do { try await client.switchAgent(sessionId: sessionID, assistant: assistant) }
            catch { self.connection = .failed("switch_agent: \(error)") }
        }
    }

    func exit(sessionID: String) {
        guard let client else { return }
        Task {
            try? await client.exitSession(sessionId: sessionID)
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
    }

    fileprivate func ingestPtyData(_ sessionID: String, _ bytes: Data) {
        terminalBuffer[sessionID, default: Data()].append(bytes)
    }

    fileprivate func ingestChat(_ sessionID: String, _ event: ChatEvent) {
        chatLog[sessionID, default: []].append(event)
    }

    fileprivate func ingestStatus(_ status: SessionStatus) {
        statusBySession[status.session] = status
        if let p = status.preview { preview[status.session] = p }
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
        connection = .failed("disconnected: \(reason)")
    }

    // MARK: - Persistence

    private static let endpointKey = "swekitty.endpoint.url"
    private static let tokenKey = "swekitty.endpoint.token"

    private static func loadPersisted() -> StoredEndpoint {
        StoredEndpoint(
            url: UserDefaults.standard.string(forKey: endpointKey) ?? "",
            token: Keychain.get(tokenKey) ?? "",
        )
    }

    private static func persist(_ e: StoredEndpoint) {
        UserDefaults.standard.set(e.url, forKey: endpointKey)
        Keychain.set(e.token.isEmpty ? nil : e.token, for: tokenKey)
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
}
