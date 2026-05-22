import Foundation
import Network

/// Tiny HTTP listener bound to `127.0.0.1:<port>` for the duration of a
/// single agent-login attempt. The provider's OAuth flow redirects the
/// user's browser to `http://localhost:<port>/auth/callback?code=...`
/// at the end of the consent step; this listener catches that GET,
/// extracts the query string, and fires the supplied `onCallback`
/// closure with the URL components.
///
/// Why this exists. `AgentLoginCoordinator` ships the captured query
/// string back to the broker over WS — the broker then forwards it to
/// the still-running CLI subprocess on the broker host. The phone is
/// only a transit hop for the `?code=...` parameter; the token
/// exchange happens on the broker side, where the CLI already has the
/// PKCE verifier in memory.
///
/// Design choices:
/// - Bind `127.0.0.1` only (not `localhost`, not `::1`) so we never
///   accidentally accept a non-loopback connection. The OAuth
///   provider's redirect lives in the same browser-app sandbox as the
///   user; only a same-device adversary could even attempt to race
///   the listener, and on iOS that's effectively the user themselves.
/// - 600 s timeout matches litter's `callbackTimeout` and the codex
///   CLI's own patience window on the broker side.
/// - One-shot semantics: the first valid `GET /<path>?...` resolves
///   the listener and stops it. A second hit (browser retried) is
///   served a friendly HTML page but does not re-fire `onCallback`.
/// - HTTP only — never HTTPS. The provider's redirect_uri whitelist
///   explicitly lists `http://localhost:<port>/auth/callback`, and a
///   self-signed cert on the loopback listener would just confuse
///   the system browser.
///
/// Stage 0 scope (this file): skeleton + unit-testable parser. The
/// `start()` / `stop()` lifecycle is exercised end-to-end in Stage 1
/// when `AgentLoginCoordinator` wires it into `AgentLoginSheet`.
/// Until then this file compiles and is used by tests only.
final class AgentLoginLoopbackServer: @unchecked Sendable {
    /// Result of a single captured callback. The phone forwards
    /// `rawQueryString` to the broker verbatim; the broker normalizes
    /// `code` / `state` / `error` itself when it Dials the CLI's
    /// loopback.
    struct CallbackResult: Equatable {
        /// The raw `?...` segment of the captured GET request — empty
        /// when the redirect carried no query (the broker treats this
        /// as an error). Preserves percent-encoding for round-trip
        /// fidelity.
        let rawQueryString: String

        /// Parsed `code` query item value (empty when absent). Hoisted
        /// for UI ergonomics — the sheet can show "Got the code!"
        /// without re-parsing.
        let code: String

        /// Parsed `error` query item value (empty when absent).
        /// Surfaces provider-side rejection so the sheet can show a
        /// useful message before the broker even responds.
        let errorReason: String
    }

    /// Bound port — `0` until `start()` succeeds. Exposed so the
    /// coordinator can echo it back to the broker in a future
    /// keepalive (Stage 1+).
    private(set) var port: UInt16 = 0

    /// Path the listener accepts. Mirrors what the CLI advertised in
    /// its `redirect_uri` (typically `/auth/callback`). Anything else
    /// gets a 404.
    let path: String

    private let queue = DispatchQueue(label: "sh.nikhil.swekitty.agent-login-loopback")
    private var listener: NWListener?
    private let lock = NSLock()
    private var didDeliver = false

    /// Initializes a listener that will bind `127.0.0.1:port` on
    /// `start()`. `path` defaults to `/auth/callback` to match
    /// the codex CLI's verbatim redirect.
    init(port: UInt16, path: String = "/auth/callback") {
        self.port = port
        self.path = path
    }

    /// Binds the listener and arms it for one callback delivery.
    /// `onCallback` fires on the listener's dispatch queue when a
    /// matching `GET <path>?...` arrives (or on timeout). Errors at
    /// bind time bubble out as throws.
    func start(timeout: TimeInterval = 600,
               onCallback: @escaping @Sendable (Result<CallbackResult, Error>) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AgentLoginLoopbackError.invalidPort(port)
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn, onCallback: onCallback)
        }

        // Arm the timeout on the same dispatch queue so cancellation
        // races with arrival are decided by the lock below — exactly
        // one of (timeout, callback, stop) wins.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fireOnce(.failure(AgentLoginLoopbackError.timedOut), onCallback: onCallback)
        }

        listener.start(queue: queue)
    }

    /// Tears the listener down. Idempotent; subsequent `onCallback`
    /// invocations are suppressed by `didDeliver`. Safe to call from
    /// any thread.
    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        didDeliver = true
        lock.unlock()
        l?.cancel()
    }

    // MARK: - Private

    private func handle(_ connection: NWConnection,
                        onCallback: @escaping @Sendable (Result<CallbackResult, Error>) -> Void) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), onCallback: onCallback)
    }

    private func receive(on connection: NWConnection,
                         buffer: Data,
                         onCallback: @escaping @Sendable (Result<CallbackResult, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.process(next, on: connection, onCallback: onCallback)
                return
            }
            self.receive(on: connection, buffer: next, onCallback: onCallback)
        }
    }

    private func process(_ data: Data,
                         on connection: NWConnection,
                         onCallback: @escaping @Sendable (Result<CallbackResult, Error>) -> Void) {
        let requestText = String(decoding: data, as: UTF8.self)
        let firstLine = requestText.components(separatedBy: "\r\n").first ?? ""
        guard let result = Self.parseRequestLine(firstLine, expectedPath: path) else {
            Self.respond(connection: connection, statusLine: "HTTP/1.1 404 Not Found", body: "Not found")
            return
        }
        Self.respond(connection: connection,
                     statusLine: "HTTP/1.1 200 OK",
                     body: "<html><body><h3>Sign-in complete</h3><p>You can return to the SweKitty app.</p></body></html>")
        fireOnce(.success(result), onCallback: onCallback)
    }

    private func fireOnce(_ result: Result<CallbackResult, Error>,
                          onCallback: @escaping @Sendable (Result<CallbackResult, Error>) -> Void) {
        lock.lock()
        if didDeliver {
            lock.unlock()
            return
        }
        didDeliver = true
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        onCallback(result)
    }

    /// Pure-function parser for the request line. Exposed `static` so
    /// the test layer can drive it without spinning up a real socket.
    static func parseRequestLine(_ line: String, expectedPath: String) -> CallbackResult? {
        // RFC 7230 request line: `<METHOD> <target> <HTTP/version>`
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        // We only accept GET — any provider redirect is a GET.
        guard parts[0] == "GET" else { return nil }
        let target = String(parts[1])

        // Split target into <path>?<query>
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = String(split.first ?? "")
        guard pathOnly == expectedPath else { return nil }
        let query = split.count > 1 ? String(split[1]) : ""

        var code = ""
        var errorReason = ""
        if !query.isEmpty {
            // URLComponents is the path of least resistance — it
            // handles percent-decoding correctly, and we don't care
            // about params we don't recognise.
            var comps = URLComponents()
            comps.percentEncodedQuery = query
            for item in comps.queryItems ?? [] {
                switch item.name {
                case "code": code = item.value ?? ""
                case "error": errorReason = item.value ?? ""
                default: break
                }
            }
        }
        return CallbackResult(rawQueryString: query, code: code, errorReason: errorReason)
    }

    private static func respond(connection: NWConnection, statusLine: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = [
            statusLine,
            "Content-Type: text/html; charset=UTF-8",
            "Connection: close",
            "Content-Length: \(bodyData.count)",
            "",
            ""
        ].joined(separator: "\r\n")
        var resp = Data(header.utf8)
        resp.append(bodyData)
        connection.send(content: resp, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum AgentLoginLoopbackError: LocalizedError {
    case invalidPort(UInt16)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "Invalid loopback port \(p)"
        case .timedOut: return "Sign-in timed out before the browser redirected back."
        }
    }
}
