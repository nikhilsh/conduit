import Testing
import Foundation
@testable import SweKitty

/// `ios-sessions-history` — pure-data view-model tests. The screen
/// itself is a SwiftUI body wired to a `SessionsScreenModel`; lifting
/// the list + search filtering into a value type means we can pin the
/// section grouping, the search predicate, and the empty-state branch
/// without hosting a view tree (same approach as `ThreadSwitcherTests`).
@Suite("SessionsScreen — list + search filtering")
struct SessionsScreenModelTests {

    // MARK: - Grouping by server

    @Test func sessionsGroupedByServerPreserveLatestFirstOrder() {
        // Input list is already latest-first (that's what
        // `SavedSessionsStore.recent` returns). Sections should
        // appear in the order the first session of each server was
        // encountered → the most recently active server's bucket
        // floats to the top.
        let rows: [SavedSession] = [
            row(id: "a-new", server: "srv-a", last: "2026-05-20T05:00:00Z"),
            row(id: "b-mid", server: "srv-b", last: "2026-05-20T03:00:00Z"),
            row(id: "a-old", server: "srv-a", last: "2026-05-20T01:00:00Z"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv-a", "alpha"), savedServer("srv-b", "beta")],
            query: ""
        )
        #expect(model.sections.map(\.serverID) == ["srv-a", "srv-b"])
        #expect(model.sections[0].sessions.map(\.id) == ["a-new", "a-old"])
        #expect(model.sections[1].sessions.map(\.id) == ["b-mid"])
    }

    @Test func sectionUsesSavedServerName() {
        let rows = [row(id: "s", server: "srv-a", last: "ts")]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv-a", "Production")],
            query: ""
        )
        #expect(model.sections.first?.serverName == "Production")
    }

    @Test func sectionFallsBackToServerIDWhenUnknown() {
        let rows = [row(id: "s", server: "srv-unknown", last: "ts")]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [],
            query: ""
        )
        #expect(model.sections.first?.serverName == "srv-unknown")
    }

    // MARK: - Search

    @Test func searchFiltersBySummarySubstring() {
        let rows = [
            row(id: "s-a", server: "srv", last: "ts", summary: "Fix the build pipeline"),
            row(id: "s-b", server: "srv", last: "ts", summary: "Refactor the auth flow"),
            row(id: "s-c", server: "srv", last: "ts", summary: "Investigate the flaky test"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "flaky"
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["s-c"])
    }

    @Test func searchFiltersByIDSubstring() {
        let rows = [
            row(id: "abc-123", server: "srv", last: "ts", summary: "x"),
            row(id: "def-456", server: "srv", last: "ts", summary: "y"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "abc"
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["abc-123"])
    }

    @Test func searchFiltersByAgentName() {
        let rows = [
            row(id: "s-claude", server: "srv", last: "ts", summary: "x", agent: "claude"),
            row(id: "s-codex", server: "srv", last: "ts", summary: "x", agent: "codex"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "codex"
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["s-codex"])
    }

    @Test func searchFiltersByCwd() {
        let rows = [
            row(id: "s-1", server: "srv", last: "ts", summary: "x", cwd: "/repo/frontend"),
            row(id: "s-2", server: "srv", last: "ts", summary: "x", cwd: "/repo/backend"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "frontend"
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["s-1"])
    }

    @Test func searchIsCaseInsensitive() {
        let rows = [row(id: "s-1", server: "srv", last: "ts", summary: "MIXED Case Summary")]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "mixed case"
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["s-1"])
    }

    @Test func emptyQueryReturnsEverySession() {
        let rows = [
            row(id: "s-a", server: "srv", last: "ts", summary: "alpha"),
            row(id: "s-b", server: "srv", last: "ts", summary: "beta"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: ""
        )
        #expect(model.totalRows == 2)
    }

    @Test func whitespaceOnlyQueryReturnsEverySession() {
        let rows = [row(id: "s-a", server: "srv", last: "ts", summary: "alpha")]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "   "
        )
        #expect(model.totalRows == 1)
    }

    // MARK: - Empty states

    @Test func emptyInputProducesEmptyModel() {
        let model = SessionsScreenModel.from(sessions: [], savedServers: [], query: "")
        #expect(model.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.totalRows == 0)
    }

    @Test func nonMatchingQueryStillReportsNotEmptySource() {
        // The screen distinguishes "no rows ever" (use the splash empty
        // state with a 'start one' CTA) from "no matches for this
        // query" (use the search empty state). Pin both signals.
        let rows = [row(id: "s-a", server: "srv", last: "ts", summary: "alpha")]
        let model = SessionsScreenModel.from(
            sessions: rows,
            savedServers: [savedServer("srv", "x")],
            query: "zzz"
        )
        #expect(!model.isEmpty)         // sessions exist
        #expect(model.sections.isEmpty) // but none match
        #expect(model.totalRows == 0)
    }

    // MARK: - Resume decision (read-only unless confirmed live)

    // Read-only is the default. The interactive attach branch fires ONLY
    // when the row is `.live`, we're connected to its server, the id is in
    // the live list, AND the store does not consider it read-only.

    @Test func resumeAttachesLiveOnlyWhenAllConditionsHold() {
        let d = ResumeDecision.decide(
            status: .live,
            connectedToRowServer: true,
            sessionIsListed: true,
            storeSaysReadOnly: false
        )
        #expect(d == .attachLive)
    }

    @Test func resumeStaleLiveRowNotInLiveListIsReadOnly() {
        // The reported bug: a removed/ended session whose persisted status
        // is still `.live` but which the broker no longer lists must open
        // read-only, not interactive.
        let d = ResumeDecision.decide(
            status: .live,
            connectedToRowServer: true,
            sessionIsListed: false,
            storeSaysReadOnly: true
        )
        #expect(d == .readOnlyTranscript)
    }

    @Test func resumeLiveRowListedButStoreSaysReadOnlyIsReadOnly() {
        // Listed but the store positively marked it read-only (exited/failed
        // phase) → the persisted `.live` is stale → read-only.
        let d = ResumeDecision.decide(
            status: .live,
            connectedToRowServer: true,
            sessionIsListed: true,
            storeSaysReadOnly: true
        )
        #expect(d == .readOnlyTranscript)
    }

    @Test func resumeLiveRowOnDifferentServerIsReadOnly() {
        // Not connected to the row's server: we'd have to switch + reconnect
        // to even learn if it's live (racy) → fail closed to read-only.
        let d = ResumeDecision.decide(
            status: .live,
            connectedToRowServer: false,
            sessionIsListed: false,
            storeSaysReadOnly: true
        )
        #expect(d == .readOnlyTranscript)
    }

    @Test func resumeExitedRowIsAlwaysReadOnly() {
        // Even if (impossibly) listed + not-read-only, a non-live status
        // never resumes interactive.
        let d = ResumeDecision.decide(
            status: .exited,
            connectedToRowServer: true,
            sessionIsListed: true,
            storeSaysReadOnly: false
        )
        #expect(d == .readOnlyTranscript)
    }

    @Test func resumeUnknownRowIsAlwaysReadOnly() {
        let d = ResumeDecision.decide(
            status: .unknown,
            connectedToRowServer: true,
            sessionIsListed: true,
            storeSaysReadOnly: false
        )
        #expect(d == .readOnlyTranscript)
    }

    // MARK: - Helpers

    private func row(
        id: String,
        server: String,
        last: String,
        summary: String = "",
        agent: String = "claude",
        cwd: String? = nil
    ) -> SavedSession {
        SavedSession(
            id: id,
            serverID: server,
            agent: agent,
            cwd: cwd,
            firstSeen: last,
            lastSeen: last,
            messageCount: 0,
            summary: summary,
            status: .unknown
        )
    }

    private func savedServer(_ id: String, _ name: String) -> SavedServer {
        SavedServer(
            id: id,
            name: name,
            endpoint: StoredEndpoint(url: "ws://example", token: "t"),
            isDefault: false
        )
    }
}
