import Testing
import Foundation
@testable import Conduit

/// Pins down the rail's row contract. The rail is the iPad sidebar
/// flavor of the home screen — it must surface every session row and
/// highlight whichever id matches `selectedSessionID`. The SwiftUI
/// view is a thin renderer over these rows.
@Suite("ConduitUI.SessionsRailModel")
struct ConduitSessionsRailModelTests {

    @Test func rowsEmptyOnEmptySnapshot() {
        let snap = ConduitUI.HomeSnapshot.empty
        #expect(ConduitUI.SessionsRailModel.rows(snap).isEmpty)
    }

    @Test func rowsCountMatchesSessionCount() {
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "host"
        )
        #expect(ConduitUI.SessionsRailModel.rows(snap).count == 3)
    }

    @Test func activeSessionRowIsHighlighted() {
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: "host"
        )
        let rows = ConduitUI.SessionsRailModel.rows(snap)
        #expect(rows.map(\.isSelected) == [false, true, false])
    }

    // MARK: - Recency grouping (handoff §6)

    @Test func sectionsBucketByRecency() {
        // Anchor "now" and build sessions at known offsets so the buckets
        // are deterministic. ISO8601 with internet date-time format.
        let now = Date(timeIntervalSince1970: 1_750_000_000)   // fixed instant
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ secondsAgo: TimeInterval) -> String {
            iso.string(from: now.addingTimeInterval(-secondsAgo))
        }
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "today", displayName: "T", assistant: "claude", phase: nil, lastActivityAt: stamp(60 * 60)),          // 1h ago
                ConduitUI.HomeSnapshotSession(id: "yest", displayName: "Y", assistant: "claude", phase: nil, lastActivityAt: stamp(60 * 60 * 28)),      // ~28h ago
                ConduitUI.HomeSnapshotSession(id: "week", displayName: "W", assistant: "claude", phase: nil, lastActivityAt: stamp(60 * 60 * 24 * 4)),  // 4d ago
                ConduitUI.HomeSnapshotSession(id: "old", displayName: "O", assistant: "claude", phase: nil, lastActivityAt: stamp(60 * 60 * 24 * 30)),  // 30d ago
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "host"
        )
        let sections = ConduitUI.SessionsRailModel.sections(snap, now: now)
        // All four buckets present, in order, one row each.
        #expect(sections.map(\.title) == ["Today", "Yesterday", "This week", "Earlier"])
        #expect(sections.allSatisfy { $0.rows.count == 1 })
    }

    @Test func sectionsDropEmptyBuckets() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil, lastActivityAt: iso.string(from: now.addingTimeInterval(-120))),
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "host"
        )
        let sections = ConduitUI.SessionsRailModel.sections(snap, now: now)
        #expect(sections.map(\.title) == ["Today"])
    }

    @Test func sectionsPutUndatedRowsInToday() {
        // A session with no parseable timestamp is in-flight/unknown → Today.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "host"
        )
        let sections = ConduitUI.SessionsRailModel.sections(snap)
        #expect(sections.first?.title == "Today")
        #expect(sections.first?.rows.count == 1)
    }

    @Test func noRowHighlightedWhenSelectedIDMissing() {
        // Stale or never-set selection — every row should render
        // unhighlighted (no accidental "first row is selected"
        // fallback).
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "ghost",
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.SessionsRailModel.rows(snap)
        #expect(rows.allSatisfy { $0.isSelected == false })
    }
}
