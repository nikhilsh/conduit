import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// State-machine driver for the v2 agent-login flow (litter-faithful,
/// docs/PLAN-AGENT-OAUTH.md "Approach v2"). Orchestrates:
///
///   1. Send `start_agent_login` over WS.
///   2. Wait for `agent_login_url` view_event from broker.
///   3. Bind a local 127.0.0.1 loopback listener on the supplied port.
///   4. Open the authorize URL in `ASWebAuthenticationSession`.
///   5. When the browser redirects back to the loopback, ship the
///      captured query string over WS via `agent_login_callback`.
///   6. Wait for `agent_login_complete` and resolve.
///
/// The actual UI wiring (sheet button → `start(.openai)`) lands in
/// Stage 1. This file ships the testable state machine + the protocol
/// glue; Stage 1's `AgentLoginSheet` replacement calls `start(...)`
/// and observes the `state` published value.
///
/// Why pull the orchestration into its own type vs. inlining into
/// `AgentLoginSheet`: the broker emits the login view_events through
/// the same session-WS that powers the rest of the app, so the
/// receive-side dispatcher (in `SessionStore`) needs to be able to
/// route incoming events to a coordinator instance regardless of
/// which screen owns the sheet. Hoisting the state machine here lets
/// Settings → "Re-login" reuse it without duplicating the wire glue.
///
/// Concurrency: `@MainActor` because every transition either reads
/// `state` (UI binding) or kicks off an `ASWebAuthenticationSession`
/// (UI-thread only). The loopback listener fires on its own queue
/// and we hop back to MainActor before mutating state.
@MainActor
final class AgentLoginCoordinator {
    enum State: Equatable {
        case idle
        case waitingForBrokerURL
        case awaitingBrowserRedirect(loopbackPort: UInt16, sessionToken: String, authorizeURL: URL)
        case forwardingCallback(sessionToken: String)
        case succeeded
        case failed(reason: String)
        case cancelled
    }

    /// Provider this coordinator is driving — set by `start(...)`.
    /// Read-only after start so the UI can show the right copy.
    private(set) var provider: AgentLoginProvider?

    /// Current state. Observers (the SwiftUI sheet) react to changes
    /// via a published surface in Stage 1. For now we expose the raw
    /// var so test code can read it synchronously.
    private(set) var state: State = .idle

    /// The wire transport. Injected so tests can swap in a fake that
    /// records outbound messages and synthesises inbound view_events.
    /// In production this is wired to `SessionStore`/the Rust core's
    /// WS handle.
    private let transport: AgentLoginTransport

    /// Loopback listener handle — non-nil only while we're in the
    /// `awaitingBrowserRedirect` phase. We retain it on `self` so
    /// the listener isn't deallocated mid-flight when the sheet body
    /// rebuilds.
    private var loopback: AgentLoginLoopbackServer?

    /// The web auth session, retained for the same reason as
    /// `loopback`. `ASWebAuthenticationSession` deallocates → cancel
    /// if you don't hold it.
    #if canImport(AuthenticationServices)
    private var webSession: ASWebAuthenticationSession?
    private let presentationProvider: AgentLoginPresentationProvider?
    #endif

    init(transport: AgentLoginTransport,
         presentationProvider: AgentLoginPresentationProvider? = nil) {
        self.transport = transport
        #if canImport(AuthenticationServices)
        self.presentationProvider = presentationProvider
        #endif
    }

    /// Kicks off the v2 flow for `provider`. Returns when the flow
    /// resolves (success, failure, cancellation). Stage 0 ships the
    /// state machine and protocol surface; Stage 1 wires the actual
    /// `ASWebAuthenticationSession.start()` call site once the broker
    /// PR lands and we can verify end-to-end.
    func start(_ provider: AgentLoginProvider) async throws {
        self.provider = provider
        state = .waitingForBrokerURL
        try await transport.sendStartAgentLogin(provider: provider.wireName)
        // The transport's reply lands via `handleViewEvent(_:)` —
        // typically routed from SessionStore's WS dispatcher. We
        // don't `await` it here in Stage 0; Stage 1 will plumb a
        // continuation in.
    }

    /// Inbound `agent_login_url` view_event. Wired up by Stage 1's
    /// `SessionStore` dispatcher. Idempotent: a second event with a
    /// fresh token aborts the previous attempt.
    func handleAgentLoginURL(loopbackPort: UInt16, sessionToken: String, authorizeURL: URL) {
        // Bind the loopback listener BEFORE opening the browser, so a
        // very fast OAuth completion (cached browser session) doesn't
        // redirect into a void.
        let server = AgentLoginLoopbackServer(port: loopbackPort)
        do {
            try server.start { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleLoopbackResult(result, sessionToken: sessionToken)
                }
            }
        } catch {
            state = .failed(reason: "Could not bind loopback :\(loopbackPort): \(error.localizedDescription)")
            return
        }
        self.loopback = server
        state = .awaitingBrowserRedirect(loopbackPort: loopbackPort,
                                          sessionToken: sessionToken,
                                          authorizeURL: authorizeURL)
        // Stage 1: open the browser. We defer the actual presentation
        // to a host-provided callback so this file doesn't have to
        // import UIKit; `AgentLoginPresentationProvider` is the seam.
        #if canImport(AuthenticationServices)
        guard let presentationProvider else { return }
        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            // `callbackURLScheme` is required by the API but unused
            // in v2 — our callback lands on the loopback HTTP server,
            // not on a scheme intercept. Pass a placeholder; the
            // completionHandler will only fire on user cancel.
            callbackURLScheme: "swekitty"
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The legitimate "happy path" terminates via the
                // loopback callback above, not via this closure.
                // We only land here on user-cancel or error.
                if let error {
                    if let asErr = error as? ASWebAuthenticationSessionError,
                       asErr.code == .canceledLogin {
                        self.cancel()
                    } else {
                        self.fail("browser: \(error.localizedDescription)")
                    }
                }
            }
        }
        session.presentationContextProvider = presentationProvider
        session.prefersEphemeralWebBrowserSession = false
        self.webSession = session
        session.start()
        #endif
    }

    /// Inbound `agent_login_complete` view_event.
    func handleAgentLoginComplete() {
        loopback?.stop()
        loopback = nil
        #if canImport(AuthenticationServices)
        webSession?.cancel()
        webSession = nil
        #endif
        state = .succeeded
    }

    /// Inbound `agent_login_failed` view_event.
    func handleAgentLoginFailed(reason: String) {
        fail(reason)
    }

    /// User-driven cancel (sheet dismissed). Tears down local state
    /// and notifies the broker so the CLI subprocess dies.
    func cancel() {
        loopback?.stop()
        loopback = nil
        #if canImport(AuthenticationServices)
        webSession?.cancel()
        webSession = nil
        #endif
        if case .awaitingBrowserRedirect(_, let sessionToken, _) = state {
            Task { try? await transport.sendCancelAgentLogin(sessionToken: sessionToken) }
        } else if case .forwardingCallback(let sessionToken) = state {
            Task { try? await transport.sendCancelAgentLogin(sessionToken: sessionToken) }
        }
        state = .cancelled
    }

    // MARK: - Private

    private func fail(_ reason: String) {
        loopback?.stop()
        loopback = nil
        #if canImport(AuthenticationServices)
        webSession?.cancel()
        webSession = nil
        #endif
        state = .failed(reason: reason)
    }

    private func handleLoopbackResult(
        _ result: Result<AgentLoginLoopbackServer.CallbackResult, Error>,
        sessionToken: String
    ) {
        switch result {
        case .failure(let error):
            fail(error.localizedDescription)
        case .success(let callback):
            if !callback.errorReason.isEmpty {
                fail("provider error: \(callback.errorReason)")
                return
            }
            if callback.code.isEmpty {
                fail("loopback delivered no authorization code")
                return
            }
            state = .forwardingCallback(sessionToken: sessionToken)
            Task {
                do {
                    try await transport.sendAgentLoginCallback(
                        sessionToken: sessionToken,
                        queryString: callback.rawQueryString
                    )
                    // `agent_login_complete` arrives async via the WS
                    // dispatcher → handleAgentLoginComplete().
                } catch {
                    fail("forward to broker failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Provider identity for the v2 flow. Distinct from
/// `OAuthProvider` (the v1 enum) so the deprecated v1 code path can
/// continue to compile during the transition; Stage 4 will collapse
/// the two.
enum AgentLoginProvider: String, Sendable {
    case openai
    case anthropic

    /// Wire-name value sent in `start_agent_login.provider` — pinned
    /// to lowercase to match the broker's switch in
    /// `broker/internal/oauth/login_session.go` and
    /// `broker/internal/credentials/store.go`.
    var wireName: String { rawValue }
}

/// Wire-transport contract for the coordinator. Stage 1's SessionStore
/// implements this against the live WS; tests inject a fake that
/// records outbound payloads and exposes setters to synthesize
/// inbound view_events.
protocol AgentLoginTransport: Sendable {
    func sendStartAgentLogin(provider: String) async throws
    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws
    func sendCancelAgentLogin(sessionToken: String) async throws
}

#if canImport(AuthenticationServices)
/// Presentation context provider for `ASWebAuthenticationSession`.
/// Hoisted as a protocol so the coordinator doesn't have to import
/// UIKit directly — the iOS app supplies a concrete implementer
/// (typically `SessionStore` or a dedicated `WindowProvider`) that
/// returns the active key window. Stage 1 wires this in.
protocol AgentLoginPresentationProvider: ASWebAuthenticationPresentationContextProviding, Sendable {}
#endif
