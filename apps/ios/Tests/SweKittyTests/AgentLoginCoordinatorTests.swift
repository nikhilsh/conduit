import Testing
import Foundation
@testable import SweKitty

/// State-machine tests for the v2 agent-login coordinator
/// (`docs/PLAN-AGENT-OAUTH.md` "Approach v2"). No network, no
/// `ASWebAuthenticationSession` — these pin the pure transitions
/// driven by the broker's view_events and the loopback server's
/// captured callback.
@Suite("AgentLoginCoordinator — state machine")
struct AgentLoginCoordinatorTests {

    // MARK: - Fakes

    /// Records outbound WS messages so test cases can assert the
    /// coordinator wrote the right control frames.
    actor RecordingTransport: AgentLoginTransport {
        private(set) var startCalls: [String] = []
        private(set) var callbackCalls: [(token: String, query: String)] = []
        private(set) var cancelCalls: [String] = []

        func sendStartAgentLogin(provider: String) async throws {
            startCalls.append(provider)
        }
        func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {
            callbackCalls.append((sessionToken, queryString))
        }
        func sendCancelAgentLogin(sessionToken: String) async throws {
            cancelCalls.append(sessionToken)
        }
    }

    // MARK: - start → broker URL → success

    /// Happy-path skeleton: the coordinator starts in `.idle`, advances
    /// to `.waitingForBrokerURL` after `start(.openai)`, and surfaces
    /// the right wire-name to the transport.
    @Test @MainActor
    func startSetsWaitingForBrokerURL() async throws {
        let transport = RecordingTransport()
        let c = AgentLoginCoordinator(transport: transport)
        #expect(c.state == .idle)
        try await c.start(.openai)
        #expect(c.state == .waitingForBrokerURL)
        let calls = await transport.startCalls
        #expect(calls == ["openai"])
        #expect(c.provider == .openai)
    }

    /// `handleAgentLoginComplete()` transitions to `.succeeded`
    /// regardless of intermediate state — covers the "fast broker"
    /// scenario where the WS reply arrives before we even bind the
    /// loopback. Also confirms idempotence: a second complete is a
    /// no-op (`.succeeded` stays `.succeeded`).
    @Test @MainActor
    func completeTransitionsToSucceeded() async {
        let c = AgentLoginCoordinator(transport: RecordingTransport())
        c.handleAgentLoginComplete()
        #expect(c.state == .succeeded)
        c.handleAgentLoginComplete()
        #expect(c.state == .succeeded)
    }

    /// `handleAgentLoginFailed(reason:)` transitions to `.failed`
    /// with the supplied reason carried through.
    @Test @MainActor
    func failTransitionsToFailed() async {
        let c = AgentLoginCoordinator(transport: RecordingTransport())
        c.handleAgentLoginFailed(reason: "CLI not on PATH")
        if case .failed(let reason) = c.state {
            #expect(reason == "CLI not on PATH")
        } else {
            Issue.record("expected .failed, got \(c.state)")
        }
    }

    /// `cancel()` while in `.idle` transitions to `.cancelled` and
    /// does NOT call the transport (there's no broker session_token to
    /// cancel yet).
    @Test @MainActor
    func cancelFromIdleSkipsTransport() async {
        let transport = RecordingTransport()
        let c = AgentLoginCoordinator(transport: transport)
        c.cancel()
        #expect(c.state == .cancelled)
        let calls = await transport.cancelCalls
        #expect(calls.isEmpty)
    }

    // MARK: - Loopback parser

    /// The HTTP request-line parser is the hot loop on the loopback
    /// listener; pin its happy path against the codex-shaped redirect.
    @Test
    func parseRequestLineHappyPath() {
        let result = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?code=abc123&state=xyz HTTP/1.1",
            expectedPath: "/auth/callback"
        )
        #expect(result?.code == "abc123")
        #expect(result?.rawQueryString == "code=abc123&state=xyz")
        #expect(result?.errorReason == "")
    }

    /// Provider rejection (`error=access_denied`) lands on
    /// `errorReason` so the sheet can surface it before the broker
    /// even responds.
    @Test
    func parseRequestLineSurfacesError() {
        let result = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?error=access_denied&error_description=user%20denied HTTP/1.1",
            expectedPath: "/auth/callback"
        )
        #expect(result?.errorReason == "access_denied")
        #expect(result?.code == "")
    }

    /// Wrong path → nil (the listener returns 404 — exercised via the
    /// nil branch of `process(_:on:onCallback:)`).
    @Test
    func parseRequestLineWrongPathIsNil() {
        let result = AgentLoginLoopbackServer.parseRequestLine(
            "GET /some-other-path?code=abc HTTP/1.1",
            expectedPath: "/auth/callback"
        )
        #expect(result == nil)
    }

    /// Non-GET methods are rejected. We never expect a POST from the
    /// browser redirect, but rejecting other methods narrows the
    /// attack surface if something on the device decides to probe the
    /// loopback port mid-flight.
    @Test
    func parseRequestLineRejectsNonGET() {
        let result = AgentLoginLoopbackServer.parseRequestLine(
            "POST /auth/callback HTTP/1.1",
            expectedPath: "/auth/callback"
        )
        #expect(result == nil)
    }

    /// Empty query string is structurally valid — the provider
    /// SHOULD include `code=...` but if they don't, the broker treats
    /// the empty-query callback as a failure on its side. We surface
    /// it as a parse with empty code and empty errorReason, leaving
    /// the policy call to the coordinator.
    @Test
    func parseRequestLineEmptyQuery() {
        let result = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback HTTP/1.1",
            expectedPath: "/auth/callback"
        )
        #expect(result?.rawQueryString == "")
        #expect(result?.code == "")
    }
}
