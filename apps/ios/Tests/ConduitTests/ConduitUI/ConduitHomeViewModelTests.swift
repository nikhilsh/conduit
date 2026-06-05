import Testing
import Foundation
@testable import Conduit

/// Pins down the row-derivation rules in `ConduitUI.HomeViewModel`. The
/// SwiftUI view is a renderer over these rows, so the model is what's
/// load-bearing for the home screen.
@Suite("ConduitUI.HomeViewModel")
struct ConduitHomeViewModelTests {

    @Test func rowsEmptyOnEmptySnapshot() {
        let snap = ConduitUI.HomeSnapshot.empty
        #expect(ConduitUI.HomeViewModel.rows(snap).isEmpty)
    }

    @Test func sessionRowSecondaryLineCarriesAgentAndStatus() {
        // The secondary line is now structured: agent + status word +
        // relative time (host dropped — it wasn't useful). A connected,
        // non-exited session reads "running".
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(
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
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows.count == 1)
        #expect(rows[0].agent == "claude")
        #expect(rows[0].statusText == "running")
    }

    @Test func sessionRowStatusReadsExitedAndIdle() {
        // An `exited…` phase reads "exited"; a disconnected harness reads
        // "idle" (device bug #30 — can't trust a stale running phase).
        let exited = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [ConduitUI.HomeSnapshotSession(id: "e", displayName: "E", assistant: "claude", phase: "exited(0)")],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        #expect(ConduitUI.HomeViewModel.rows(exited)[0].statusText == "exited")

        let disconnected = ConduitUI.HomeSnapshot(
            harness: .disconnected,
            sessions: [ConduitUI.HomeSnapshotSession(id: "d", displayName: "D", assistant: "claude", phase: "working")],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        #expect(ConduitUI.HomeViewModel.rows(disconnected)[0].statusText == "idle")
    }

    @Test func sessionRowRelativeTimeIsDeterministic() {
        let now = ISO8601DateFormatter().date(from: "2026-05-25T12:00:00Z")!
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(
                    id: "s1",
                    displayName: "x",
                    assistant: "claude",
                    phase: "working",
                    lastActivityAt: "2026-05-25T11:58:00Z"
                )
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap, now: now)
        #expect(rows[0].relativeTime == "2m ago")
    }

    @Test func sessionRowDropsEphemeralWorkDir() {
        // The per-session scratch dir must NOT surface as a project path;
        // a real cwd does.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(
                    id: "eph",
                    displayName: "eph",
                    assistant: "claude",
                    phase: "working",
                    workingDir: SessionNaming.meaningfulWorkingDir("/root/.conduit/sessions/abc/work")
                ),
                ConduitUI.HomeSnapshotSession(
                    id: "real",
                    displayName: "real",
                    assistant: "claude",
                    phase: "working",
                    workingDir: SessionNaming.meaningfulWorkingDir("/Users/me/code/conduit")
                ),
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].workingDir == nil)
        #expect(rows[1].workingDir == "/Users/me/code/conduit")
    }

    @Test func sessionRowFlagsSelectedWhenIDMatches() {
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "claude", phase: nil),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].isSelected == false)
        #expect(rows[1].isSelected == true)
    }

    @Test func sessionRowRunStateIsIndependentOfSelection() {
        // device bug #9: the status dot tracked selection, so a second
        // *running* session looked stopped. Run state must come from the
        // phase, not which row is attached — both running sessions show
        // green even though only one is selected; an exited one is muted.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: "working"),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "codex", phase: nil),
                ConduitUI.HomeSnapshotSession(id: "c", displayName: "C", assistant: "claude", phase: "exited(0)"),
            ],
            placeholders: [],
            selectedSessionID: "b",
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].isRunning == true)   // working, not selected
        #expect(rows[1].isRunning == true)   // ready (nil), selected
        #expect(rows[2].isRunning == false)  // exited
        #expect(rows[0].isSelected == false) // running but not attached → still green
    }

    @Test func sessionRowsMutedWhenDisconnected() {
        // device bug #30: stale phase ("running") must NOT show green when
        // the connection is down — the app can't know real state.
        let snap = ConduitUI.HomeSnapshot(
            harness: .disconnected,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "a", displayName: "A", assistant: "claude", phase: "working"),
                ConduitUI.HomeSnapshotSession(id: "b", displayName: "B", assistant: "codex", phase: "ready"),
            ],
            placeholders: [],
            selectedSessionID: "a",
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].isRunning == false) // disconnected → muted despite "working"
        #expect(rows[1].isRunning == false)
    }

    @Test func secondaryLineOmitsTimeWhenNoTimestamp() {
        // No `lastActivityAt` → the relative-time slot is empty (the row
        // simply doesn't render the time chip). Agent + status still show.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "s", displayName: "S", assistant: "claude", phase: "ready")
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].agent == "claude")
        #expect(rows[0].statusText == "running")
        #expect(rows[0].relativeTime == "")
    }

    @Test func emptyStateChangesByHarnessReachability() {
        let unreachable = ConduitUI.HomeSnapshot.empty
        #expect(ConduitUI.HomeViewModel.emptyTitle(unreachable) == "Waiting for server")
        #expect(ConduitUI.HomeViewModel.emptySymbol(unreachable) == "cloud.slash")

        let reachable = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: "local"
        )
        #expect(ConduitUI.HomeViewModel.emptyTitle(reachable) == "No sessions yet")
        #expect(ConduitUI.HomeViewModel.emptySymbol(reachable) == "sparkles")
    }

    @Test func sessionRowCarriesActivityPreview() {
        // The card's third line is a one-line preview of the latest
        // activity. The view layer pre-condenses it and hands it through
        // the snapshot; the row simply carries it.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(
                    id: "s1",
                    displayName: "feature-branch",
                    assistant: "claude",
                    phase: "working",
                    lastActivityPreview: "Run: cargo test"
                )
            ],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows[0].lastActivityPreview == "Run: cargo test")
    }

    @Test func sessionRowPreviewDefaultsEmpty() {
        // No preview supplied → the row carries an empty string and the
        // view drops the line.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [ConduitUI.HomeSnapshotSession(id: "s", displayName: "S", assistant: "claude", phase: "ready")],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        #expect(ConduitUI.HomeViewModel.rows(snap)[0].lastActivityPreview == "")
    }

    @Test func activityPreviewPrefersToolCommand() {
        // A tool item surfaces its command, labelled by the tool name.
        let preview = ConduitUI.HomeViewModel.activityPreview(
            role: "tool",
            kind: "tool",
            toolName: "Bash",
            command: "cargo test --all\nshould-not-show",
            content: "ignored body"
        )
        #expect(preview == "Bash: cargo test --all")
    }

    @Test func activityPreviewFallsBackToAssistantBody() {
        // An assistant message uses its first non-empty line, condensed.
        let preview = ConduitUI.HomeViewModel.activityPreview(
            role: "assistant",
            kind: "message",
            toolName: nil,
            command: nil,
            content: "\n   Here is the   plan\nmore detail"
        )
        #expect(preview == "Here is the plan")
    }

    @Test func activityPreviewClipsLongLines() {
        let long = String(repeating: "a", count: 200)
        let preview = ConduitUI.HomeViewModel.activityPreview(
            role: "assistant",
            kind: "message",
            toolName: nil,
            command: nil,
            content: long,
            budget: 10
        )
        #expect(preview?.count == 10)            // 9 chars + ellipsis
        #expect(preview?.hasSuffix("…") == true)
    }

    @Test func activityPreviewNilOnEmptyContent() {
        let preview = ConduitUI.HomeViewModel.activityPreview(
            role: "assistant",
            kind: "message",
            toolName: nil,
            command: nil,
            content: "   \n  "
        )
        #expect(preview == nil)
    }

    // MARK: "Needs you" banner (handoff §B.10)

    @Test func awaitingInputOnlyForUnansweredPendingInput() {
        // The real signal: the LAST transcript item is a non-user
        // `pending_input` (approval prompt / options menu).
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: "assistant", lastItemKind: "pending_input") == true)
        // A user reply after the prompt clears it (last item is the user's).
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: "user", lastItemKind: "pending_input") == false)
        // A normal assistant message is not a block.
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: "assistant", lastItemKind: "message") == false)
        // No transcript at all → not waiting.
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: nil, lastItemKind: nil) == false)
    }

    @Test func needsYouBannerHiddenWhenNoSessionWaiting() {
        // No fabricated count: a session mid-reply yields an empty banner.
        let banner = ConduitUI.HomeViewModel.needsYouBanner([
            (id: "a", title: "Fix auth", agent: "claude", lastItemRole: "assistant", lastItemKind: "message")
        ])
        #expect(banner.count == 0)
        #expect(banner.primaryID == nil)
    }

    @Test func needsYouBannerCollectsWaitingSessionsInOrder() {
        let banner = ConduitUI.HomeViewModel.needsYouBanner([
            (id: "a", title: "Fix auth", agent: "claude", lastItemRole: "assistant", lastItemKind: "pending_input"),
            (id: "b", title: "Idle one", agent: "codex", lastItemRole: "assistant", lastItemKind: "message"),
            (id: "c", title: "Approve push", agent: "codex", lastItemRole: "assistant", lastItemKind: "pending_input")
        ])
        #expect(banner.count == 2)
        #expect(banner.primaryID == "a")
        #expect(banner.sessions.map(\.id) == ["a", "c"])
    }

    @Test func placeholdersAppearAfterRealSessions() {
        // Placeholder = an in-flight session-creation, must render
        // *under* real sessions so a long-running placeholder doesn't
        // displace the live ones.
        let snap = ConduitUI.HomeSnapshot(
            harness: .live,
            sessions: [
                ConduitUI.HomeSnapshotSession(id: "real", displayName: "real", assistant: "claude", phase: nil)
            ],
            placeholders: [
                ConduitUI.HomeSnapshotPlaceholder(id: "ph", label: "asking harness…")
            ],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
        let rows = ConduitUI.HomeViewModel.rows(snap)
        #expect(rows.count == 2)
        if case .session = rows[0].kind {} else { Issue.record("first row should be session") }
        if case .creatingPlaceholder = rows[1].kind {} else { Issue.record("second row should be placeholder") }
    }
}
