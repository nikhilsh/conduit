import Testing
import Foundation
@testable import SweKitty

/// Coverage for the wire-up between `SessionStore` and
/// `AgentLoginCoordinator` (the v2 OAuth flow). The
/// `LitterAgentLoginSheet` is a SwiftUI body that registers a fresh
/// coordinator on `store.activeLoginCoordinator` and observes the
/// state machine — we test the store-side routing here, not the
/// SwiftUI body directly.
@Suite("LitterAgentLoginSheet — SessionStore routing")
struct LitterAgentLoginSheetTests {

    /// A coordinator parked on `activeLoginCoordinator` receives
    /// `agent_login_url` payloads dispatched through
    /// `routeAgentLoginViewEvent`, advancing into
    /// `.awaitingBrowserRedirect` even before any UI shows up.
    @Test @MainActor
    func storeRoutesAgentLoginURLToActiveCoordinator() async throws {
        let store = SessionStore()
        let transport = NoopTransport()
        let coord = AgentLoginCoordinator(transport: transport)
        store.activeLoginCoordinator = coord

        store.routeAgentLoginViewEvent(
            kind: "agent_login_url",
            payload: [
                "loopback_port": "1455",
                "session_token": "tok-abc",
                "authorize_url": "https://example.com/oauth"
            ]
        )

        // The coordinator does its own loopback bind on this transition.
        // If binding fails (sim port collision, no entitlement) the state
        // falls into `.failed(...)`; either outcome moves out of
        // `.waitingForBrokerURL`, which is what we pin here. The full
        // happy-path is exercised by `AgentLoginCoordinatorTests`.
        switch coord.state {
        case .awaitingBrowserRedirect, .failed:
            // Both are valid post-route states; the routing did fire.
            break
        default:
            Issue.record("expected awaitingBrowserRedirect or failed, got \(coord.state)")
        }
    }

    /// Inbound `agent_login_complete` clears the active coordinator
    /// off the store, so a follow-up login attempt gets a fresh one.
    @Test @MainActor
    func storeClearsCoordinatorOnComplete() {
        let store = SessionStore()
        let coord = AgentLoginCoordinator(transport: NoopTransport())
        store.activeLoginCoordinator = coord
        store.routeAgentLoginViewEvent(kind: "agent_login_complete", payload: [:])
        #expect(store.activeLoginCoordinator == nil)
        #expect(coord.state == .succeeded)
    }

    /// Inbound `agent_login_failed` carries the reason through.
    @Test @MainActor
    func storeRoutesAgentLoginFailed() {
        let store = SessionStore()
        let coord = AgentLoginCoordinator(transport: NoopTransport())
        store.activeLoginCoordinator = coord
        store.routeAgentLoginViewEvent(
            kind: "agent_login_failed",
            payload: ["reason": "CLI not installed on broker host"]
        )
        if case .failed(let reason) = coord.state {
            #expect(reason == "CLI not installed on broker host")
        } else {
            Issue.record("expected .failed, got \(coord.state)")
        }
        #expect(store.activeLoginCoordinator == nil)
    }

    /// The production `SessionStoreAgentLoginTransport` throws
    /// `AgentLoginTransportError` until the Rust UDL bridge ships —
    /// pin that so the gap stays surfaced in CI and we notice the
    /// moment a future PR wires the real send path.
    @Test @MainActor
    func sessionStoreTransportThrowsUntilUDLBridgeShips() async {
        let store = SessionStore()
        let transport = SessionStoreAgentLoginTransport(store: store)
        do {
            try await transport.sendStartAgentLogin(provider: "openai")
            Issue.record("expected sendStartAgentLogin to throw until the UDL bridge ships")
        } catch is AgentLoginTransportError {
            // expected
        } catch {
            Issue.record("expected AgentLoginTransportError, got \(error)")
        }
    }
}

/// No-op transport that lets us spin up an `AgentLoginCoordinator`
/// without recording side-effects — these tests target the store
/// routing, not the outbound wire.
private actor NoopTransport: AgentLoginTransport {
    func sendStartAgentLogin(provider: String) async throws {}
    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {}
    func sendCancelAgentLogin(sessionToken: String) async throws {}
}
