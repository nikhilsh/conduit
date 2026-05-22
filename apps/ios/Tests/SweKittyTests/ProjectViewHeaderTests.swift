import Testing
import Foundation
@testable import SweKitty

/// Stage 2 — litter-style header restructure. The header is now an
/// explicit three-row layout (controls / path / tab-picker) and the
/// agent dropdown is a compound control (status dot · name · effort ·
/// chevron) — these tests defend that shape so a future refactor
/// can't quietly collapse it.
///
/// We don't host the SwiftUI body (no ViewInspector dep in this
/// target). Instead we test the pure `ProjectHeaderModel` that the
/// view body renders from, which is the same source-of-truth for
/// what shows on screen.
@Suite("ProjectView header — litter Stage 2")
struct ProjectViewHeaderTests {

    // MARK: - Three-row structure

    @Test func headerHasThreeRowsInOrder() {
        // The whole point of Stage 2: render order is controls → path
        // → tab picker. Surface drift (collapsed rows, reordered) would
        // mean the litter visual reference is broken.
        #expect(ProjectHeaderModel.rows == [.controls, .path, .tabPicker])
        #expect(ProjectHeaderModel.rows.count == 3)
    }

    @Test func headerCapsVerticalFootprintAt120pt() {
        // fix-ui-friction-vol2: the user repeatedly flagged the header
        // as eating too much vertical chrome despite Stage 2's
        // tightening pass. The cap defends a regression where a future
        // row gets added without budgeting against the existing three.
        // 120pt is the budget we chose for [pill] · [caption] · [picker]
        // with internal padding.
        #expect(ProjectHeaderModel.maxHeight == 120 as CGFloat)
    }

    // MARK: - Compound agent dropdown

    @Test func agentPillExposesDropdownPayload() {
        let session = makeSession(assistant: "claude", branch: "main")
        let status = makeStatus(assistant: "claude", phase: "running", health: "green")
        let model = ProjectHeaderModel.from(session: session,
                                            status: status,
                                            lifecycleLabel: nil)
        // Status dot + agent name + reasoning-effort label + chevron
        // are all carried on the same pill — one compound control,
        // not four sibling chips.
        #expect(model.agentPill.healthKey == "green")
        #expect(model.agentPill.agentName == "claude")
        #expect(model.agentPill.reasoningEffort == "medium")
        #expect(model.agentPill.showsChevron)
    }

    @Test func reasoningEffortFallsBackToMedium() {
        // Older harnesses don't emit reasoning_effort yet; the pill
        // must always read *something* so the layout doesn't shift.
        let session = makeSession(assistant: "codex", reasoning: nil)
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.agentPill.reasoningEffort == "medium")
    }

    @Test func reasoningEffortHonoursHarnessValue() {
        let session = makeSession(assistant: "claude", reasoning: "high")
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.agentPill.reasoningEffort == "high")
    }

    @Test func unknownHealthShowsAsUnknownDot() {
        // No status frame yet → dot defaults to "unknown" (grey),
        // matching litter's "we don't know yet" treatment.
        let session = makeSession(assistant: "claude")
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.agentPill.healthKey == "unknown")
    }

    // MARK: - Path row

    @Test func pathRowPrefersCwdWhenAvailable() {
        let session = makeSession(assistant: "claude",
                                  name: "fallback-name",
                                  cwd: "/srv/work/repo")
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.pathLabel == "/srv/work/repo")
    }

    @Test func pathRowFallsBackToSessionName() {
        let session = makeSession(assistant: "claude",
                                  name: "fallback-name",
                                  cwd: nil)
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.pathLabel == "fallback-name")
    }

    /// `display_name` (broker `rename_session`, protocol §3.3) wins
    /// over both cwd and name in the header label. Mirror of the
    /// Android `ProjectHeaderModel.from` precedence test so the two
    /// shells render the same renamed label.
    @Test func pathRowPrefersDisplayNameOverCwdAndName() {
        let session = ProjectSession(
            id: "uuid-1234",
            name: "fallback-name",
            assistant: "claude",
            branch: "main",
            preview: nil,
            reasoningEffort: nil,
            cwd: "/srv/work/repo",
            startedAt: nil,
            lastActivityAt: nil,
            displayName: "rename-from-server"
        )
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(model.pathLabel == "rename-from-server")
    }

    @Test func pathSubtitleJoinsBranchPhaseAndLifecycle() {
        let session = makeSession(assistant: "claude", branch: "feature/x")
        let status = makeStatus(assistant: "claude", phase: "running", health: "green")
        let model = ProjectHeaderModel.from(session: session,
                                            status: status,
                                            lifecycleLabel: "exited(0)")
        #expect(model.pathSubtitle == "feature/x · running · exited(0)")
    }

    // MARK: - Viewer badge wiring

    @Test func viewerBadgeHiddenWhenStatusMissing() {
        // No status frame → no viewers info → badge invisible. Same
        // contract as `ViewerCountBadgeModel` defends in isolation,
        // re-asserted here so a refactor of `ProjectHeaderModel.from`
        // can't silently break the wiring.
        let session = makeSession(assistant: "claude")
        let model = ProjectHeaderModel.from(session: session,
                                            status: nil,
                                            lifecycleLabel: nil)
        #expect(!model.viewerBadge.isVisible)
    }

    @Test func viewerBadgeHiddenForLoneViewer() {
        // Broker reports `viewers: 1` (only you) — the badge stays
        // hidden so it doesn't announce the user to themselves.
        let session = makeSession(assistant: "claude")
        let status = makeStatus(assistant: "claude",
                                phase: "running",
                                health: "green",
                                viewers: 1)
        let model = ProjectHeaderModel.from(session: session,
                                            status: status,
                                            lifecycleLabel: nil)
        #expect(!model.viewerBadge.isVisible)
    }

    @Test func viewerBadgeVisibleWhenMultipleViewers() {
        // PR ios-viewer-badge-wire: status carries `viewers > 1`, so
        // the header pill renders "👥 N" with a matching VoiceOver
        // label. This is the one assertion that proves the badge is
        // actually wired into the header (vs. shipping the SwiftUI
        // file and forgetting to call it).
        let session = makeSession(assistant: "claude")
        let status = makeStatus(assistant: "claude",
                                phase: "running",
                                health: "green",
                                viewers: 3)
        let model = ProjectHeaderModel.from(session: session,
                                            status: status,
                                            lifecycleLabel: nil)
        #expect(model.viewerBadge.isVisible)
        #expect(model.viewerBadge.label == "👥 3")
        #expect(model.viewerBadge.accessibilityLabel == "3 viewers")
    }

    // MARK: - Helpers

    private func makeSession(assistant: String,
                             name: String = "swe-kitty",
                             branch: String? = "main",
                             cwd: String? = nil,
                             reasoning: String? = nil) -> ProjectSession {
        // Generated by UniFFI; build-rust.sh regenerates the binding
        // before the test target compiles. The init grew `cwd` /
        // `reasoning_effort` / `started_at` / `last_activity_at` in
        // commit 2666642 (see `core/src/swe_kitty_core.udl`).
        ProjectSession(
            id: "test-\(UUID().uuidString)",
            name: name,
            assistant: assistant,
            branch: branch,
            preview: nil,
            reasoningEffort: reasoning,
            cwd: cwd,
            startedAt: nil,
            lastActivityAt: nil,
            displayName: nil
        )
    }

    private func makeStatus(assistant: String,
                            phase: String,
                            health: String,
                            viewers: UInt32? = nil) -> SessionStatus {
        // The generated SessionStatus init grew optional fields in
        // commit 2666642. Use the regenerated full-init signature
        // (mirrors `SessionStore.ingestExit` so we drift with it).
        SessionStatus(
            session: "test-session",
            assistant: assistant,
            phase: phase,
            health: health,
            rows: 24,
            cols: 80,
            yolo: false,
            preview: nil,
            sessionName: nil,
            viewers: viewers,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: nil,
            lastActivityAt: nil,
            displayName: nil
        )
    }
}
