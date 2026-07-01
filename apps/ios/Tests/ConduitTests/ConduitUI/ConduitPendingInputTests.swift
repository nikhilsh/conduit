import Testing
import Foundation
@testable import Conduit

/// Pins the pending-input helpers: per-question grouping recovered from the
/// broker's flattened body (#7) and the duplicate-echo drop (#5).
@Suite("ConduitUI.PendingInput")
struct ConduitPendingInputTests {

    private func item(kind: String, content: String, role: String = "assistant", pendingOptions: [String] = []) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            role: role,
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
            pendingOptions: pendingOptions,
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

    @Test func stripsBrokerSentinelLine() {
        // The deterministic sentinel must never reach the user; the parser
        // drops it and parses the real question/options beneath.
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(
            "[[conduit:needs-input]]\nProceed?\n1. Yes\n2. No"
        )
        #expect(qs.count == 1)
        #expect(qs[0].prompt == "Proceed?")
        #expect(qs[0].options == ["Yes", "No"])
    }

    // MARK: parsePendingResolution (persisted answered-state rehydration)

    /// The persisted resolution marker is decoded into answered=true + the
    /// chosen answer text. This is the authoritative state a freshly-reloaded
    /// card uses — no local @State is involved.
    @Test func parsesAnsweredResolutionFromTranscript() {
        let content = "[[conduit:needs-input]]\n"
            + #"[[conduit:resolved]]{"answered":true,"answer":"Merge now"}"# + "\n"
            + "Proceed with the merge?\n1. Merge now\n2. Hold off"
        let res = ConduitUI.ChatViewModel.parsePendingResolution(content)
        #expect(res?.answered == true)
        #expect(res?.answer == "Merge now")
    }

    /// A timed-out / no-answer resolution marks the card resolved (answered
    /// flag) but carries no answer text — no option is highlighted.
    @Test func parsesTimedOutResolutionWithNoAnswer() {
        let content = "[[conduit:needs-input]]\n"
            + #"[[conduit:resolved]]{"answered":false}"# + "\n"
            + "Ship it?\n1. Yes\n2. No"
        let res = ConduitUI.ChatViewModel.parsePendingResolution(content)
        #expect(res?.answered == false)
        #expect(res?.answer == nil)
    }

    /// Backward-compat: a pending-input card with NO resolution marker (an
    /// unanswered card, or a transcript written before this feature) decodes
    /// to nil — the card renders unanswered exactly as before.
    @Test func legacyCardWithoutMarkerHasNoResolution() {
        let content = "[[conduit:needs-input]]\nProceed?\n1. Yes\n2. No"
        #expect(ConduitUI.ChatViewModel.parsePendingResolution(content) == nil)
        #expect(ConduitUI.ChatViewModel.parsePendingResolution("just a reply") == nil)
    }

    /// The resolution marker line must NEVER render as visible question prose:
    /// `parsePendingQuestions` filters it out alongside the sentinel.
    @Test func resolutionMarkerStrippedFromQuestionText() {
        let content = "[[conduit:needs-input]]\n"
            + #"[[conduit:resolved]]{"answered":true,"answer":"Yes"}"# + "\n"
            + "Proceed?\n1. Yes\n2. No"
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(content)
        #expect(qs.count == 1)
        #expect(qs[0].prompt == "Proceed?")
        #expect(qs[0].options == ["Yes", "No"])
    }

    // MARK: dedup: original + resolved card collapse to one answered card

    /// When the broker re-publishes a resolved copy of an answered
    /// AskUserQuestion, the resolved card carries an extra
    /// `[[conduit:resolved]]{...}` marker line that the original lacks.
    /// The raw content strings differ, so the old content-keyed dedup kept
    /// both. The fix: key on stripped content so they match, and let the
    /// answered (resolved-marker) card win.
    @Test func dedupeCollapseOriginalAndResolvedToAnsweredCard() {
        let originalContent = "[[conduit:needs-input]]\nProceed with the merge?\n1. Merge now\n2. Hold off"
        let resolvedContent = "[[conduit:needs-input]]\n"
            + #"[[conduit:resolved]]{"answered":true,"answer":"Merge now"}"# + "\n"
            + "Proceed with the merge?\n1. Merge now\n2. Hold off"
        let original = item(kind: "pending_input", content: originalContent)
        let resolved = item(kind: "pending_input", content: resolvedContent)

        // Both orders must collapse to one card and the survivor must be answered.
        for order in [[original, resolved], [resolved, original]] {
            let result = ConduitUI.ChatViewModel.dropPendingInputEchoes(order)
            #expect(result.count == 1)
            let res = ConduitUI.ChatViewModel.parsePendingResolution(result[0].content)
            #expect(res != nil, "survivor must carry the resolution marker (answered card won)")
            #expect(res?.answered == true)
            #expect(res?.answer == "Merge now")
        }
    }

    /// Genuinely distinct questions (different stripped prompt) must NOT be
    /// merged — both cards survive even when one is resolved.
    @Test func dedupeKeepsDistinctQuestions() {
        let q1 = item(kind: "pending_input", content: "[[conduit:needs-input]]\nMerge?\n1. Yes\n2. No")
        let q2Resolved = item(kind: "pending_input",
            content: "[[conduit:needs-input]]\n"
                + #"[[conduit:resolved]]{"answered":true,"answer":"Yes"}"# + "\n"
                + "Deploy?\n1. Yes\n2. No")
        let result = ConduitUI.ChatViewModel.dropPendingInputEchoes([q1, q2Resolved])
        #expect(result.count == 2)
    }

    /// Multi-question answers are newline-joined ("A\nB") — the echo drop must
    /// suppress them even though no single option matches the whole string.
    @Test func multiQuestionAnswerEchoIsDropped() {
        let card = item(
            kind: "pending_input",
            content: "[[conduit:needs-input]]\nStartup behavior?\n1. Default-on for everyone\n2. Opt-in\n\nParallelism?\n1. Both, in parallel\n2. Sequential",
            pendingOptions: ["Default-on for everyone", "Opt-in", "Both, in parallel", "Sequential"]
        )
        let echo = item(kind: "message", content: "Default-on for everyone\nBoth, in parallel", role: "user")
        let result = ConduitUI.ChatViewModel.dropPendingInputEchoes([card, echo])
        #expect(result.count == 1)
        #expect(result[0].kind == "pending_input")
    }

    /// dropPendingInputEchoes uses the stripped key when matching plain echoes,
    /// so a raw echo of the question body (without markers) is still dropped
    /// even when the surviving pending_input card carries the resolved marker.
    @Test func echoDropWorksAgainstResolvedCard() {
        let resolvedContent = "[[conduit:needs-input]]\n"
            + #"[[conduit:resolved]]{"answered":true,"answer":"Merge now"}"# + "\n"
            + "Proceed with the merge?\n1. Merge now\n2. Hold off"
        let resolved = item(kind: "pending_input", content: resolvedContent)
        let echo = item(kind: "message", content: "Proceed with the merge?")
        let result = ConduitUI.ChatViewModel.dropPendingInputEchoes([echo, resolved])
        #expect(result.count == 1)
        #expect(result[0].kind == "pending_input")
    }
}
