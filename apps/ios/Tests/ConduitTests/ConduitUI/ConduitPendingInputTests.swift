import Testing
import Foundation
@testable import Conduit

/// Pins the pending-input helpers: per-question grouping recovered from the
/// broker's flattened body (#7) and the duplicate-echo drop (#5).
@Suite("ConduitUI.PendingInput")
struct ConduitPendingInputTests {

    private func item(kind: String, content: String) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            role: kind == "pending_input" ? "assistant" : "assistant",
            kind: kind,
            status: "done",
            content: content,
            ts: "2026-06-05T10:00:00Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
    }

    // MARK: parsePendingQuestions

    @Test func parsesSingleQuestion() {
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions("Proceed with the merge?\n1. Merge now\n2. Hold off")
        #expect(qs.count == 1)
        #expect(qs[0].prompt == "Proceed with the merge?")
        #expect(qs[0].options == ["Merge now", "Hold off"])
    }

    @Test func parsesTwoQuestionsAsSeparateGroups() {
        // Broker shape: blocks separated by a blank line, renumbered per block.
        let body = "Color?\n1. Red\n2. Blue\n\nSize?\n1. S\n2. M"
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(body)
        #expect(qs.count == 2)
        #expect(qs[0] == ConduitUI.PendingQuestion(prompt: "Color?", options: ["Red", "Blue"]))
        #expect(qs[1] == ConduitUI.PendingQuestion(prompt: "Size?", options: ["S", "M"]))
    }

    @Test func parsesQuestionWithoutOptions() {
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions("Anything else?")
        #expect(qs.count == 1)
        #expect(qs[0].prompt == "Anything else?")
        #expect(qs[0].options.isEmpty)
    }

    // MARK: dropPendingInputEchoes

    @Test func dropsPlainEchoContainedInPendingBody() {
        let pending = item(kind: "pending_input", content: "Which code would you like me to review?\n1. Branch\n2. Worktree")
        // A plain assistant message that is just the bare question (a subset
        // of the pending body) is the duplicate the user sees.
        let echo = item(kind: "message", content: "Which code would you like me to review?")
        let kept = ConduitUI.ChatViewModel.dropPendingInputEchoes([echo, pending])
        #expect(kept.count == 1)
        #expect(kept.first?.kind == "pending_input")
    }

    @Test func keepsUnrelatedMessages() {
        let pending = item(kind: "pending_input", content: "Pick one?\n1. A\n2. B")
        let unrelated = item(kind: "message", content: "Here is some unrelated explanation about the change.")
        let kept = ConduitUI.ChatViewModel.dropPendingInputEchoes([unrelated, pending])
        #expect(kept.count == 2)
    }

    @Test func noPendingItemIsNoOp() {
        let a = item(kind: "message", content: "hello there")
        let b = item(kind: "message", content: "general kenobi")
        #expect(ConduitUI.ChatViewModel.dropPendingInputEchoes([a, b]).count == 2)
    }

    // MARK: multiSelect marker (round-4 — broker appends
    // " (select all that apply)" to multi-select questions)

    @Test func stripsMultiSelectMarkerIntoFlag() {
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(
            "Pick colors (select all that apply)\n1. Red\n2. Green\n\nPick one\n1. A\n2. B"
        )
        #expect(qs.count == 2)
        #expect(qs[0].multiSelect)
        #expect(qs[0].prompt == "Pick colors")
        #expect(qs[0].options == ["Red", "Green"])
        #expect(!qs[1].multiSelect)
        #expect(qs[1].prompt == "Pick one")
    }

    @Test func plainQuestionHasNoMultiFlag() {
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions("Proceed?\n1. Yes\n2. No")
        #expect(qs.count == 1)
        #expect(!qs[0].multiSelect)
    }
}
