import Testing
import Foundation
@testable import Conduit

// MARK: - ConduitFoundSessionsModelTests
//
// Unit tests for ConduitUI.FoundSessionsModel. Mirrors ConduitHomeViewModelTests
// pattern: pure snapshot-in -> rows-out, no SwiftUI, deterministic.

@Suite("ConduitUI.FoundSessionsModel")
struct ConduitFoundSessionsModelTests {

    // MARK: - Test fixtures

    func makeSession(
        id: String,
        title: String = "Test session",
        cwd: String = "/root/projects/api",
        isRunning: Bool = false,
        lastActivityAt: Date = Date().addingTimeInterval(-300)
    ) -> SessionStore.FoundSession {
        SessionStore.FoundSession(
            id: id,
            externalID: id,
            agent: "claude",
            title: title,
            cwd: cwd,
            gitBranch: "main",
            turnCount: 10,
            lastActivityAt: lastActivityAt,
            isRunning: isRunning
        )
    }

    func makeSnap(
        sessions: [SessionStore.FoundSession] = [],
        adoptedIDs: Set<String> = [],
        hiddenIDs: Set<String> = [],
        query: String = "",
        filter: ConduitUI.FoundSessionsFilter = .recent,
        discoveryState: ConduitUI.FoundSessionsDiscoveryState = .loaded,
        totalOnDisk: Int = 0
    ) -> ConduitUI.FoundSessionsSnapshot {
        ConduitUI.FoundSessionsSnapshot(
            boxID: "box-1",
            boxName: "Prod VPS",
            sessions: sessions,
            adoptedExternalIDs: adoptedIDs,
            hiddenIDs: hiddenIDs,
            query: query,
            filter: filter,
            discoveryState: discoveryState,
            totalOnDisk: totalOnDisk > 0 ? totalOnDisk : sessions.count
        )
    }

    // MARK: - Row state mapping

    @Test func idleSessionMapsToIdleState() {
        let snap = makeSnap(sessions: [makeSession(id: "s1", isRunning: false)])
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].state == .idle)
    }

    @Test func runningSessionMapsToRunningState() {
        let snap = makeSnap(sessions: [makeSession(id: "s1", isRunning: true)])
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].state == .running)
    }

    @Test func adoptedSessionDeduped() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1", isRunning: false)],
            adoptedIDs: ["s1"]
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].state == .adopted)
    }

    @Test func adoptedTakesPrecedenceOverRunning() {
        // A session marked adopted is .adopted even if is_running=true
        let snap = makeSnap(
            sessions: [makeSession(id: "s1", isRunning: true)],
            adoptedIDs: ["s1"]
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows[0].state == .adopted)
    }

    // MARK: - Hidden IDs

    @Test func hiddenSessionExcludedFromRecent() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1"), makeSession(id: "s2")],
            hiddenIDs: ["s1"],
            filter: .recent
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].externalID == "s2")
    }

    @Test func hiddenSessionExcludedFromByFolder() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1"), makeSession(id: "s2")],
            hiddenIDs: ["s1"],
            filter: .byFolder
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(!rows.contains(where: { $0.externalID == "s1" }))
    }

    @Test func hiddenSessionIncludedInAllFilter() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1"), makeSession(id: "s2")],
            hiddenIDs: ["s1"],
            filter: .all
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        // Both rows come back; the hidden one carries isHidden=true
        #expect(rows.count == 2)
        let hiddenRow = rows.first { $0.externalID == "s1" }
        #expect(hiddenRow?.isHidden == true)
    }

    // MARK: - Search

    @Test func searchFiltersByTitle() {
        let snap = makeSnap(
            sessions: [
                makeSession(id: "s1", title: "Refactor auth flow"),
                makeSession(id: "s2", title: "Fix payment bugs"),
            ],
            query: "auth"
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].externalID == "s1")
    }

    @Test func searchFiltersByCwd() {
        let snap = makeSnap(
            sessions: [
                makeSession(id: "s1", cwd: "/root/projects/api"),
                makeSession(id: "s2", cwd: "/root/projects/frontend"),
            ],
            query: "frontend"
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].externalID == "s2")
    }

    @Test func searchCaseInsensitive() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1", title: "Refactor Auth Flow")],
            query: "auth"
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 1)
    }

    @Test func emptySearchReturnsAll() {
        let snap = makeSnap(
            sessions: [makeSession(id: "s1"), makeSession(id: "s2")],
            query: ""
        )
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 2)
    }

    // MARK: - Sort order

    @Test func rowsSortedMostRecentFirst() {
        let now = Date()
        let older = makeSession(id: "old", lastActivityAt: now.addingTimeInterval(-3600))
        let newer = makeSession(id: "new", lastActivityAt: now.addingTimeInterval(-60))
        let snap = makeSnap(sessions: [older, newer], filter: .recent)
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows[0].externalID == "new")
        #expect(rows[1].externalID == "old")
    }

    @Test func recentFilterCappsAt20() {
        let sessions = (0..<25).map { i in
            makeSession(id: "s\(i)", lastActivityAt: Date().addingTimeInterval(Double(-i * 60)))
        }
        let snap = makeSnap(sessions: sessions, filter: .recent)
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        #expect(rows.count == 20)
    }

    // MARK: - Grouping

    @Test func groupedKeysByFolder() {
        let sessions = [
            makeSession(id: "s1", cwd: "/root/api"),
            makeSession(id: "s2", cwd: "/root/frontend"),
            makeSession(id: "s3", cwd: "/root/api"),
        ]
        let snap = makeSnap(sessions: sessions, filter: .byFolder)
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        let groups = ConduitUI.FoundSessionsModel.grouped(rows)
        #expect(groups.count == 2)
        let apiGroup = groups.first { $0.cwd == "/root/api" }
        #expect(apiGroup?.rows.count == 2)
    }

    @Test func groupedPreservesRecencyOrder() {
        let now = Date()
        let sessions = [
            makeSession(id: "s1", cwd: "/root/api", lastActivityAt: now.addingTimeInterval(-120)),
            makeSession(id: "s2", cwd: "/root/frontend", lastActivityAt: now.addingTimeInterval(-60)),
        ]
        // s2 (frontend) was more recent -- should appear first in groups
        let snap = makeSnap(sessions: sessions, filter: .byFolder)
        let rows = ConduitUI.FoundSessionsModel.rows(snap)
        let groups = ConduitUI.FoundSessionsModel.grouped(rows)
        // Groups are ordered by the recency of their first (most-recent) session
        // frontend (s2, -60s) newer than api (s1, -120s)
        #expect(groups[0].cwd == "/root/frontend")
        #expect(groups[1].cwd == "/root/api")
    }

    // MARK: - Footer text

    @Test func footerTextSingleSession() {
        let text = ConduitUI.FoundSessionsModel.footerText(recentCount: 1, totalOnDisk: 1)
        #expect(text == "1 session found")
    }

    @Test func footerTextMultipleSessions() {
        let text = ConduitUI.FoundSessionsModel.footerText(recentCount: 5, totalOnDisk: 5)
        #expect(text == "5 sessions found")
    }

    @Test func footerTextHonestVolumeLineWhenMoreOnDisk() {
        let text = ConduitUI.FoundSessionsModel.footerText(recentCount: 5, totalOnDisk: 142)
        #expect(text.contains("142 on disk"))
        #expect(text.contains("5 recent"))
    }

    // MARK: - Relative time

    @Test func relativeTimeJustNow() {
        let now = Date()
        let t = ConduitUI.FoundSessionsModel.relativeTime(now.addingTimeInterval(-10), now: now)
        #expect(t == "just now")
    }

    @Test func relativeTimeMinutesAgo() {
        let now = Date()
        let t = ConduitUI.FoundSessionsModel.relativeTime(now.addingTimeInterval(-120), now: now)
        #expect(t == "2m ago")
    }

    @Test func relativeTimeHoursAgo() {
        let now = Date()
        let t = ConduitUI.FoundSessionsModel.relativeTime(now.addingTimeInterval(-7200), now: now)
        #expect(t == "2h ago")
    }

    // MARK: - Empty / offline / error state derivation

    @Test func emptySnapshotHasCorrectDiscoveryState() {
        var snap = makeSnap(sessions: [], discoveryState: .empty)
        snap.filter = .recent
        let state = ConduitUI.FoundSessionsModel.discoveryState(snap)
        #expect(state == .empty)
    }

    @Test func offlineSnapshotHasCorrectDiscoveryState() {
        let snap = makeSnap(sessions: [], discoveryState: .offline)
        let state = ConduitUI.FoundSessionsModel.discoveryState(snap)
        #expect(state == .offline)
    }

    @Test func scanningSnapshotState() {
        let snap = makeSnap(sessions: [], discoveryState: .scanning)
        #expect(ConduitUI.FoundSessionsModel.discoveryState(snap) == .scanning)
    }

    @Test func errorSnapshotState() {
        let snap = makeSnap(sessions: [], discoveryState: .error("failed"))
        if case .error(let msg) = ConduitUI.FoundSessionsModel.discoveryState(snap) {
            #expect(msg == "failed")
        } else {
            Issue.record("Expected error state")
        }
    }

    // MARK: - RecentCount

    @Test func recentCountIsCappedAt20() {
        let sessions = (0..<30).map { i in makeSession(id: "s\(i)") }
        let snap = makeSnap(sessions: sessions)
        #expect(snap.recentCount == 20)
    }

    @Test func recentCountWithFewSessions() {
        let snap = makeSnap(sessions: [makeSession(id: "s1"), makeSession(id: "s2")])
        #expect(snap.recentCount == 2)
    }
}
