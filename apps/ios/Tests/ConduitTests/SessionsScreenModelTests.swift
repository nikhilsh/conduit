import Testing
import Foundation
@testable import Conduit

/// `ios-sessions-history` — pure-data view-model tests. The screen
/// itself is a SwiftUI body wired to a `SessionsScreenModel`; lifting
/// the list + search filtering into a value type means we can pin the
/// section grouping, the search predicate, and the empty-state branch
/// without hosting a view tree (same approach as `ThreadSwitcherTests`).
@Suite("SessionsScreen — list + search filtering")
struct SessionsScreenModelTests {

    // MARK: - Grouping by recency bucket

    // Fixed "now" anchor used by every time-bucket test so the grouping is
    // deterministic regardless of when CI runs. Buckets are computed
    // against the device calendar, so we use a calendar pinned to UTC to
    // match the UTC timestamps the helper rows carry.
    private static let now = ISO8601DateFormatter().date(from: "2026-05-25T12:00:00Z")!
    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func build(
        _ rows: [SavedSession],
        servers: [SavedServer] = [],
        query: String = ""
    ) -> SessionsScreenModel {
        SessionsScreenModel.from(
            sessions: rows,
            savedServers: servers,
            query: query,
            now: Self.now,
            calendar: Self.utcCalendar
        )
    }

    @Test func sessionsGroupedIntoTimeBuckets() {
        // One row per bucket relative to the 2026-05-25T12:00 anchor.
        let rows: [SavedSession] = [
            row(id: "today",      server: "srv", last: "2026-05-25T09:00:00Z"),
            row(id: "yesterday",  server: "srv", last: "2026-05-24T09:00:00Z"),
            row(id: "thisweek",   server: "srv", last: "2026-05-21T09:00:00Z"),
            row(id: "earlier",    server: "srv", last: "2026-04-01T09:00:00Z"),
        ]
        let model = build(rows)
        #expect(model.sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
        #expect(model.sections.map { $0.sessions.map(\.id) } == [["today"], ["yesterday"], ["thisweek"], ["earlier"]])
    }

    @Test func emptyBucketsAreOmittedInFixedOrder() {
        // No "Yesterday" rows → that bucket simply doesn't appear, and the
        // remaining buckets keep their fixed Today→Earlier order.
        let rows: [SavedSession] = [
            row(id: "earlier", server: "srv", last: "2026-01-01T09:00:00Z"),
            row(id: "today",   server: "srv", last: "2026-05-25T08:00:00Z"),
        ]
        let model = build(rows)
        #expect(model.sections.map(\.title) == ["Today", "Earlier"])
    }

    @Test func rowsWithinBucketAreLatestFirst() {
        // Input is already latest-first (what `recent()` returns); the
        // grouping must preserve that within a bucket.
        let rows: [SavedSession] = [
            row(id: "t-late",  server: "srv", last: "2026-05-25T11:00:00Z"),
            row(id: "t-early", server: "srv", last: "2026-05-25T01:00:00Z"),
        ]
        let model = build(rows)
        #expect(model.sections.count == 1)
        #expect(model.sections[0].sessions.map(\.id) == ["t-late", "t-early"])
    }

    @Test func multiServerRowsShareTimeBuckets() {
        // Server identity is now a per-row chip, not the section — rows
        // from different servers land in the same time bucket.
        let rows: [SavedSession] = [
            row(id: "a", server: "srv-a", last: "2026-05-25T11:00:00Z"),
            row(id: "b", server: "srv-b", last: "2026-05-25T10:00:00Z"),
        ]
        let model = build(
            rows,
            servers: [savedServer("srv-a", "alpha"), savedServer("srv-b", "beta")]
        )
        #expect(model.sections.map(\.title) == ["Today"])
        #expect(model.sections[0].sessions.map(\.id) == ["a", "b"])
        #expect(model.serverName(for: rows[0]) == "alpha")
        #expect(model.serverName(for: rows[1]) == "beta")
    }

    @Test func serverNameFallsBackToServerIDWhenUnknown() {
        let rows = [row(id: "s", server: "srv-unknown", last: "2026-05-25T09:00:00Z")]
        let model = build(rows)
        #expect(model.serverName(for: rows[0]) == "srv-unknown")
    }

    @Test func unparseableTimestampSinksToEarlier() {
        let rows = [row(id: "s", server: "srv", last: "not-a-date")]
        let model = build(rows)
        #expect(model.sections.map(\.title) == ["Earlier"])
    }

    // MARK: - Filter chips (All / Running / claude / codex)

    @Test func runningFilterKeepsOnlyLiveRows() {
        let rows = [
            row(id: "live",   server: "srv", last: "2026-05-25T09:00:00Z", agent: "claude", status: .live),
            row(id: "exited", server: "srv", last: "2026-05-25T08:00:00Z", agent: "claude", status: .exited),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows, savedServers: [], query: "", filter: .running
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["live"])
    }

    @Test func agentFiltersKeepOnlyThatAgent() {
        let rows = [
            row(id: "c", server: "srv", last: "2026-05-25T09:00:00Z", agent: "claude"),
            row(id: "x", server: "srv", last: "2026-05-25T08:00:00Z", agent: "codex"),
        ]
        let claudeOnly = SessionsScreenModel.from(
            sessions: rows, savedServers: [], query: "", filter: .claude
        )
        #expect(claudeOnly.sections.flatMap(\.sessions).map(\.id) == ["c"])
        let codexOnly = SessionsScreenModel.from(
            sessions: rows, savedServers: [], query: "", filter: .codex
        )
        #expect(codexOnly.sections.flatMap(\.sessions).map(\.id) == ["x"])
    }

    @Test func allFilterIsCombinedWithSearch() {
        // The chip filter composes with the search predicate: codex chip +
        // a summary needle narrows to a single row.
        let rows = [
            row(id: "x1", server: "srv", last: "2026-05-25T09:00:00Z", summary: "Fix flaky test", agent: "codex"),
            row(id: "x2", server: "srv", last: "2026-05-25T08:00:00Z", summary: "Bump deps", agent: "codex"),
            row(id: "c1", server: "srv", last: "2026-05-25T07:00:00Z", summary: "Fix flaky test", agent: "claude"),
        ]
        let model = SessionsScreenModel.from(
            sessions: rows, savedServers: [], query: "flaky", filter: .codex
        )
        #expect(model.sections.flatMap(\.sessions).map(\.id) == ["x1"])
    }

    @Test func filterExcludingEverythingKeepsSourceNonEmpty() {
        // Running chip with no live rows → no sections, but the source set
        // is non-empty so the screen shows the "no matches" state, not the
        // "no sessions yet" splash.
        let rows = [row(id: "e", server: "srv", last: "2026-05-25T09:00:00Z", status: .exited)]
        let model = SessionsScreenModel.from(
            sessions: rows, savedServers: [], query: "", filter: .running
        )
        #expect(!model.isEmpty)
        #expect(model.sections.isEmpty)
    }

    // MARK: - Outcome derivation

    @Test func outcomeFromPersistedStatus() {
        #expect(SessionsScreenModel.Outcome.from(
            row(id: "a", server: "s", last: "ts", status: .live)) == .running)
        #expect(SessionsScreenModel.Outcome.from(
            row(id: "b", server: "s", last: "ts", status: .exited)) == .ended)
        // Unknown degrades to the honest neutral, never a fabricated merged.
        #expect(SessionsScreenModel.Outcome.from(
            row(id: "c", server: "s", last: "ts", status: .unknown)) == .ended)
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
        cwd: String? = nil,
        status: SavedSessionStatus = .unknown
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
            status: status
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
