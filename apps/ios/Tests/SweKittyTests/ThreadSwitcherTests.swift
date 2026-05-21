import Testing
import Foundation
@testable import SweKitty

/// `litter-multi-thread` — ThreadSwitcherSheet view model. Same
/// pattern as `ProjectViewHeaderTests`: assert against the pure-data
/// `ThreadSwitcherModel` rather than hosting the SwiftUI body, so the
/// shape of the sheet (same-server list, empty-state CTA, multi-thread
/// pill strip) is locked in without a UI test rig.
@Suite("ThreadSwitcherSheet — multi-thread parity")
struct ThreadSwitcherTests {

    // MARK: - Same-server filtering

    @Test func sameServerListExcludesActiveSession() {
        // The sheet's "other sessions on this server" list must skip
        // the session the user is currently inside — otherwise the
        // user can "switch" to the thread they're already on, which
        // is a confusing no-op.
        let active = makeSession(id: "active", assistant: "claude")
        let other1 = makeSession(id: "peer-a", assistant: "claude")
        let other2 = makeSession(id: "peer-b", assistant: "codex")

        let model = ThreadSwitcherModel.from(
            allSessions: [active, other1, other2],
            activeSessionID: "active",
            currentServerID: "srv-1"
        )

        let ids = model.sameServerSessions.map(\.id)
        #expect(ids == ["peer-a", "peer-b"])
        #expect(!ids.contains("active"))
    }

    @Test func sameServerListOnlyContainsServerScopedSessions() {
        // The store only ever holds sessions for the currently
        // connected endpoint, so "filter by current server" collapses
        // to "all sessions in the store except the active one." This
        // test pins that behaviour so a future refactor that wires
        // a wire-side `serverID` doesn't accidentally drop sessions.
        let active = makeSession(id: "active", assistant: "claude")
        let peers = (0..<3).map { makeSession(id: "peer-\($0)", assistant: "claude") }
        let model = ThreadSwitcherModel.from(
            allSessions: [active] + peers,
            activeSessionID: "active",
            currentServerID: "srv-1"
        )
        #expect(model.sameServerSessions.count == 3)
        for s in peers {
            #expect(model.sameServerSessions.contains(where: { $0.id == s.id }))
        }
    }

    // MARK: - Empty state + CTA

    @Test func emptyStateWhenOnlyOneSessionExists() {
        // Lone active session → no other threads to switch to →
        // sheet must surface the empty-state CTA so the user has a
        // way forward instead of staring at a blank list.
        let only = makeSession(id: "only", assistant: "claude")
        let model = ThreadSwitcherModel.from(
            allSessions: [only],
            activeSessionID: "only",
            currentServerID: "srv-1"
        )
        #expect(model.sameServerSessions.isEmpty)
        #expect(model.sameServerIsEmpty)
        // All-sessions strip still has the active one — the peek
        // strip is "across all servers" and intentionally shows the
        // current thread so the user has a visual anchor.
        #expect(model.allSessions.count == 1)
    }

    @Test func nonEmptyStateHidesEmptyCTA() {
        let active = makeSession(id: "a", assistant: "claude")
        let peer = makeSession(id: "b", assistant: "codex")
        let model = ThreadSwitcherModel.from(
            allSessions: [active, peer],
            activeSessionID: "a",
            currentServerID: "srv-1"
        )
        #expect(!model.sameServerIsEmpty)
        #expect(model.sameServerSessions.count == 1)
    }

    // MARK: - Multi-thread peek pill strip

    @Test func peekStripIncludesEverySessionAcrossServers() {
        // The pill strip is the "multi-thread peek" affordance — it
        // shows ALL sessions the client knows about, including the
        // active one (highlighted) so the user has a visual anchor.
        // On iOS today that's same-server only because the store
        // never holds remote-server sessions, but the test asserts
        // the model contract so a future wire-side serverID lands
        // cleanly.
        let s1 = makeSession(id: "s-1", assistant: "claude")
        let s2 = makeSession(id: "s-2", assistant: "codex")
        let s3 = makeSession(id: "s-3", assistant: "claude")
        let model = ThreadSwitcherModel.from(
            allSessions: [s1, s2, s3],
            activeSessionID: "s-1",
            currentServerID: "srv-1"
        )
        #expect(model.allSessions.map(\.id) == ["s-1", "s-2", "s-3"])
        // Active session is INCLUDED in the peek strip even though
        // it's excluded from the same-server list below.
        #expect(model.allSessions.contains(where: { $0.id == model.activeSessionID }))
    }

    @Test func peekStripPreservesWireOrder() {
        // Render order of the pill strip mirrors the wire order so
        // a refactor that sorts the list (by name / by activity) is
        // explicit, not accidental.
        let names = ["zeta", "alpha", "mu", "beta"]
        let sessions = names.map { makeSession(id: $0, assistant: "claude") }
        let model = ThreadSwitcherModel.from(
            allSessions: sessions,
            activeSessionID: "alpha",
            currentServerID: "srv-1"
        )
        #expect(model.allSessions.map(\.id) == names)
    }

    // MARK: - Helpers

    private func makeSession(id: String, assistant: String) -> ProjectSession {
        ProjectSession(
            id: id,
            name: id,
            assistant: assistant,
            branch: "main",
            preview: nil,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: nil,
            lastActivityAt: nil
        )
    }
}
