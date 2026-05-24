import Testing
import Foundation
@testable import SweKitty

/// Pins down the row-derivation rules in `LitterUI.HomeViewModel`. The
/// SwiftUI view is a renderer over these rows, so the model is what's
/// load-bearing for the home screen.
@Suite("LitterUI.HomeViewModel")
struct LitterHomeViewModelTests {

    @Test func rowsEmptyOnEmptySnapshot() {
        let snap = LitterUI.HomeSnapshot.empty
        #expect(LitterUI.HomeViewModel.rows(snap).isEmpty)
    }

    @Test func sessionRowSubtitleHasAssistantPhaseAndHost() {
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(
                    id: "s1",
                    displayName: "feature-branch",
                    assistant: "claude",
                    phase: "working"
                )
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "192.168.4.30"
        )
        let rows = LitterUI.HomeViewModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].subtitle == "claude · working · 192.168.4.30")
    }

    @Test func sessionRowFlagsSelectedWhenIDMatches() {
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                LitterUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: nil
        )
        let rows = LitterUI.HomeViewModel.rows(snap)
        #expect(rows[0].isSelected == false)
        #expect(rows[1].isSelected == true)
    }

    @Test func sessionRowRunStateIsIndependentOfSelection() {
        // device bug #9: the status dot tracked selection, so a second
        // *running* session looked stopped. Run state must come from the
        // phase, not which row is attached — both running sessions show
        // green even though only one is selected; an exited one is muted.
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: "working"),
                LitterUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "codex", phase: nil),
                LitterUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: "exited(0)"),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: nil
        )
        let rows = LitterUI.HomeViewModel.rows(snap)
        #expect(rows[0].isRunning == true)   // working, not selected
        #expect(rows[1].isRunning == true)   // ready (nil), selected
        #expect(rows[2].isRunning == false)  // exited
        #expect(rows[0].isSelected == false) // running but not attached → still green
    }

    @Test func subtitleFallsBackToLocalHostWhenEndpointMissing() {
        // The home subtitle has to print *something* even before the
        // user has paired a server — litter shows the local host name
        // so the user can tell at a glance which server a session
        // belongs to.
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "s", displayName: "S", assistant: "claude", phase: "ready")
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = LitterUI.HomeViewModel.rows(snap)
        #expect(rows[0].subtitle == "claude · ready · local")
    }

    @Test func emptyStateChangesByHarnessReachability() {
        let unreachable = LitterUI.HomeSnapshot.empty
        #expect(LitterUI.HomeViewModel.emptyTitle(unreachable) == "Waiting for harness")
        #expect(LitterUI.HomeViewModel.emptySymbol(unreachable) == "cloud.slash")

        let reachable = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "local"
        )
        #expect(LitterUI.HomeViewModel.emptyTitle(reachable) == "No sessions yet")
        #expect(LitterUI.HomeViewModel.emptySymbol(reachable) == "sparkles")
    }

    @Test func placeholdersAppearAfterRealSessions() {
        // Placeholder = an in-flight session-creation, must render
        // *under* real sessions so a long-running placeholder doesn't
        // displace the live ones.
        let snap = LitterUI.HomeSnapshot(
            harness: .live,
            sessions: [
                LitterUI.HomeSnapshotSession(id: "real", displayName: "real", assistant: "claude", phase: nil)
            ],
            placeholders: [
                LitterUI.HomeSnapshotPlaceholder(id: "ph", label: "asking harness…")
            ],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = LitterUI.HomeViewModel.rows(snap)
        #expect(rows.count == 2)
        if case .session = rows[0].kind {} else { Issue.record("first row should be session") }
        if case .creatingPlaceholder = rows[1].kind {} else { Issue.record("second row should be placeholder") }
    }
}
