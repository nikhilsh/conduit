import Testing
import Foundation
@testable import SweKitty

/// Pins down the rail's row contract. The rail is the iPad sidebar
/// flavor of the home screen — it must surface every session row and
/// highlight whichever id matches `selectedSessionID`. The SwiftUI
/// view is a thin renderer over these rows.
@Suite("LitterUI.SessionsRailModel")
struct LitterSessionsRailModelTests {

    @Test func rowsEmptyOnEmptySnapshot() {
        let snap = LitterUI.HomeSnapshot.empty
        #expect(LitterUI.SessionsRailModel.rows(snap).isEmpty)
    }

    @Test func rowsCountMatchesSessionCount() {
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "host"
        )
        #expect(LitterUI.SessionsRailModel.rows(snap).count == 3)
    }

    @Test func activeSessionRowIsHighlighted() {
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: "host"
        )
        let rows = LitterUI.SessionsRailModel.rows(snap)
        #expect(rows.map(\.isSelected) == [false, true, false])
    }

    @Test func noRowHighlightedWhenSelectedIDMissing() {
        // Stale or never-set selection — every row should render
        // unhighlighted (no accidental "first row is selected"
        // fallback).
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "ghost",
            endpointDisplayHost: nil
        )
        let rows = LitterUI.SessionsRailModel.rows(snap)
        #expect(rows.allSatisfy { $0.isSelected == false })
    }
}
