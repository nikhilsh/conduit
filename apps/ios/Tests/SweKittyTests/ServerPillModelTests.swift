import Testing
import Foundation
@testable import SweKitty

/// Litter parity audit item A.3 (iOS half) — defends the `ServerPill`
/// visual contract by asserting against the pure-data `ServerPillModel`.
/// Same approach as `ProjectHeaderModel` / `InSessionBottomBarModel`:
/// no SwiftUI host, just the formatting and status-mapping rules the
/// view body renders from. Drift between the model and the rendered
/// surface is loud.
@Suite("ServerPillModel — pill formatting & status mapping")
struct ServerPillModelTests {

    // MARK: - Caption formatting

    @Test func savedCaptionIsBareHostPort() {
        // Saved pills only need host:port — the section already says
        // "Saved servers", so the row caption shouldn't repeat itself.
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .live
        )
        #expect(model.caption == "10.0.0.4:1977")
    }

    @Test func discoveredCaptionPrefixesWithDiscovered() {
        // Discovered pills appear in the same row as saved pills, so
        // the caption must distinguish them at a glance. The "discovered"
        // prefix is the contract the UI relies on.
        let model = ServerPillModel.fromDiscovered(
            id: "kitty-1977",
            name: "kitty-1977",
            host: "192.168.1.10",
            port: 1977,
            version: "1",
            isActive: false
        )
        #expect(model.caption == "discovered · 192.168.1.10:1977")
    }

    // MARK: - Duplicate-host collapse (fix-server-pill-duplicate-host)

    @Test func pillCollapsesToSingleLineWhenNameMatchesCaption() {
        // PR #47 polish bug: when the user saves a server without
        // picking a custom label, SessionStore seeds `name` with
        // `endpoint.displayHost` ("host:port") — and the pill rendered
        // that same string on both lines. Collapse to host-only on
        // line 1 + drop the subtitle entirely.
        let server = mkSaved(name: "10.0.0.4:1977", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .live
        )
        #expect(model.subtitle == nil)
        #expect(model.displayName == "10.0.0.4")
    }

    @Test func pillCollapsesWhenNameIsEmpty() {
        // Defensive: a stored SavedServer with an empty name (legacy
        // rows, migration edge cases) shouldn't render an empty bold
        // line + the host:port caption below. Fall back to host.
        let server = mkSaved(name: "", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(model.subtitle == nil)
        #expect(model.displayName == "10.0.0.4")
    }

    @Test func pillShowsBothLinesWhenUserSetCustomName() {
        // Happy path — the user picked "Studio" so line 1 stays
        // "Studio" and the subtitle surfaces the host:port below.
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .live
        )
        #expect(model.displayName == "Studio")
        #expect(model.subtitle == "10.0.0.4:1977")
    }

    // MARK: - Status mapping (saved entries)

    @Test func savedActiveLiveIsLive() {
        // Active + harness live → green dot. This is the canonical
        // "we're talking to this server" state.
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .live
        )
        #expect(model.status == .live)
        #expect(model.isActive)
    }

    @Test func savedActiveConnectingIsConnecting() {
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .connecting
        )
        #expect(model.status == .connecting)
    }

    @Test func savedActiveReconnectingIsConnecting() {
        // Reconnecting collapses into the same "yellow" connecting dot
        // — the pill is too small to spell out the attempt counter.
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .reconnecting(attempt: 2, maxAttempts: 5)
        )
        #expect(model.status == .connecting)
    }

    @Test func savedActiveFailedIsFailed() {
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .failed("nope")
        )
        #expect(model.status == .failed)
    }

    @Test func savedInactiveIsIdle() {
        // A saved server that *isn't* the active endpoint shouldn't
        // light up green just because the harness link is live for a
        // different one. Idle = gray dot.
        let server = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let model = ServerPillModel.fromSaved(
            server,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.5:1977", token: "t"),
            harness: .live
        )
        #expect(model.status == .idle)
        #expect(!model.isActive)
    }

    // MARK: - Saved vs Discovered prefix

    @Test func idIsPrefixedByKind() {
        // The pill row renders saved + discovered together. If the IDs
        // collided (a discovered row whose service name matches a
        // saved UUID is implausible but cheap to defend), SwiftUI's
        // ForEach would warn. Prefixing keeps the namespace clean.
        let saved = mkSaved(id: "abc", name: "Studio", url: "ws://10.0.0.4:1977")
        let savedModel = ServerPillModel.fromSaved(
            saved,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        let discoveredModel = ServerPillModel.fromDiscovered(
            id: "abc",
            name: "Studio",
            host: "10.0.0.4",
            port: 1977,
            version: nil,
            isActive: false
        )
        #expect(savedModel.id == "saved:abc")
        #expect(discoveredModel.id == "discovered:abc")
        #expect(savedModel.id != discoveredModel.id)
    }

    @Test func kindIsSurfacedOnModel() {
        let saved = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let savedModel = ServerPillModel.fromSaved(
            saved,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        let discoveredModel = ServerPillModel.fromDiscovered(
            id: "kitty",
            name: "kitty",
            host: "1.2.3.4",
            port: 1977,
            version: nil,
            isActive: false
        )
        #expect(savedModel.kind == .saved)
        #expect(discoveredModel.kind == .discovered)
    }

    // MARK: - Accessibility

    @Test func accessibilityLabelPrefixesByKind() {
        // Screen readers need to hear *which kind* of pill they're on
        // — otherwise "Studio, 10.0.0.4 port 1977" sounds the same
        // for saved and discovered rows.
        let saved = mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")
        let savedModel = ServerPillModel.fromSaved(
            saved,
            currentEndpoint: StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t"),
            harness: .live
        )
        #expect(savedModel.accessibilityLabel.hasPrefix("Saved server "))

        let discoveredModel = ServerPillModel.fromDiscovered(
            id: "kitty",
            name: "kitty",
            host: "1.2.3.4",
            port: 1977,
            version: nil,
            isActive: false
        )
        #expect(discoveredModel.accessibilityLabel.hasPrefix("Nearby server "))
    }

    // MARK: - host:port parsing

    @Test func splitHostPortHandlesWsScheme() {
        let parsed = ServerPillModel.splitHostPort("ws://192.168.1.10:1977")
        #expect(parsed?.host == "192.168.1.10")
        #expect(parsed?.port == 1977)
    }

    @Test func splitHostPortReturnsNilOnMalformed() {
        // Pathological inputs (empty / missing port) shouldn't crash
        // — the caller falls back to the displayHost in that case.
        #expect(ServerPillModel.splitHostPort("") == nil)
        #expect(ServerPillModel.splitHostPort("not a url") == nil)
    }

    // MARK: - Helpers

    private func mkSaved(id: String = UUID().uuidString,
                          name: String,
                          url: String,
                          isDefault: Bool = false) -> SavedServer {
        SavedServer(
            id: id,
            name: name,
            endpoint: StoredEndpoint(url: url, token: "tok"),
            isDefault: isDefault
        )
    }
}
