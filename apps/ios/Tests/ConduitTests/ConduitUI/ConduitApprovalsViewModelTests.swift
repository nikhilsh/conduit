import Testing
import Foundation
@testable import Conduit

/// Pins the pure Approvals queue + risk rules in
/// `ConduitUI.ApprovalsViewModel`. The SwiftUI view is a renderer over the
/// queue, so these rules are what's load-bearing for the surface — and the
/// gate must stay identical to the Home needs-you banner
/// (`HomeViewModel.isAwaitingInput`).
@Suite("ConduitUI.ApprovalsViewModel")
struct ConduitApprovalsViewModelTests {

    private typealias Candidate = (
        id: String, title: String, agent: String, branch: String?,
        lastItemRole: String?, lastItemKind: String?,
        command: String?, content: String
    )

    @Test func queueEmptyWhenNothingAwaitingInput() {
        let candidates: [Candidate] = [
            ("s1", "Idle", "claude", "main", "assistant", "message", nil, "done"),
            ("s2", "User turn", "codex", nil, "user", "message", nil, "hi"),
        ]
        #expect(ConduitUI.ApprovalsViewModel.queue(candidates).isEmpty)
    }

    @Test func queueIncludesOnlyPendingInputSessions() {
        let candidates: [Candidate] = [
            ("s1", "Fix auth refresh loop", "claude", "fix/auth-refresh",
             "assistant", "pending_input", "git push origin fix/auth", "approve?"),
            ("s2", "Idle", "codex", nil, "assistant", "message", nil, "ok"),
        ]
        let q = ConduitUI.ApprovalsViewModel.queue(candidates)
        #expect(q.count == 1)
        #expect(q[0].id == "s1")
        #expect(q[0].title == "Fix auth refresh loop")
        #expect(q[0].branch == "fix/auth-refresh")
        // Prefers the structured command for the prompt.
        #expect(q[0].prompt == "git push origin fix/auth")
    }

    @Test func awaitingGateMatchesHomeBanner() {
        // A user-authored last item is never awaiting, even with the kind.
        let userLast: [Candidate] = [
            ("u", "U", "claude", nil, "user", "pending_input", nil, "")
        ]
        #expect(ConduitUI.ApprovalsViewModel.queue(userLast).isEmpty)
        // Cross-check the shared gate directly.
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: "user", lastItemKind: "pending_input") == false)
        #expect(ConduitUI.HomeViewModel.isAwaitingInput(lastItemRole: "assistant", lastItemKind: "pending_input"))
    }

    @Test func promptFallsBackToContentThenGeneric() {
        #expect(ConduitUI.ApprovalsViewModel.promptText(command: nil, content: "Pick one:\n1. yes") == "Pick one:\n1. yes")
        #expect(ConduitUI.ApprovalsViewModel.promptText(command: "  ", content: "  ") == "Agent is waiting for your input")
    }

    @Test func riskDestructiveBeatsWrites() {
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: "rm -rf node_modules && pnpm i", content: "") == .destructive)
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: "git push --force", content: "") == .destructive)
    }

    @Test func riskWritesFiles() {
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: "git commit -m wip", content: "") == .writesFiles)
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: nil, content: "I'll write_file src/usage.ts") == .writesFiles)
    }

    @Test func riskDefaultsToSafe() {
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: "ls -la", content: "") == .safe)
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: nil, content: "") == .safe)
    }

    @Test func riskIsCaseInsensitive() {
        #expect(ConduitUI.ApprovalsViewModel.classifyRisk(command: "GIT PUSH --FORCE", content: "") == .destructive)
    }
}
