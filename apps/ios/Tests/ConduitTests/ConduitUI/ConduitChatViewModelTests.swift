import Testing
import Foundation
@testable import Conduit

/// Pins down the send/placeholder/alignment rules in
/// `ConduitUI.ChatViewModel`. The SwiftUI `ConduitChatView` is a thin
/// renderer; the model is where the logic lives.
@Suite("ConduitUI.ChatViewModel")
struct ConduitChatViewModelTests {

    @Test func canSendIsTrueOnlyWhenDraftHasNonWhitespace() {
        var snap = ConduitUI.ChatSnapshot.empty
        #expect(ConduitUI.ChatViewModel.canSend(snap) == false)

        snap.draft = "   "
        #expect(ConduitUI.ChatViewModel.canSend(snap) == false)

        snap.draft = "hi"
        #expect(ConduitUI.ChatViewModel.canSend(snap) == true)

        snap.draft = "\n\nhello\n"
        #expect(ConduitUI.ChatViewModel.canSend(snap) == true)
    }

    @Test func placeholderUsesAgentNameWhenProvided() {
        #expect(ConduitUI.ChatViewModel.composerPlaceholder(forAgent: "claude") == "Message claude…")
        #expect(ConduitUI.ChatViewModel.composerPlaceholder(forAgent: nil) == "Message…")
        #expect(ConduitUI.ChatViewModel.composerPlaceholder(forAgent: "") == "Message…")
    }

    @Test func userMessagesAlignTrailingEverythingElseLeading() {
        let user = ConduitUI.ChatMessage(id: "1", role: .user, text: "hi", meta: nil)
        let assistant = ConduitUI.ChatMessage(id: "2", role: .assistant, text: "hi", meta: nil)
        let system = ConduitUI.ChatMessage(id: "3", role: .system, text: "warn", meta: nil)
        let tool = ConduitUI.ChatMessage(id: "4", role: .tool, text: "out", meta: nil)

        #expect(ConduitUI.ChatViewModel.alignment(for: user) == .trailing)
        #expect(ConduitUI.ChatViewModel.alignment(for: assistant) == .leading)
        #expect(ConduitUI.ChatViewModel.alignment(for: system) == .leading)
        #expect(ConduitUI.ChatViewModel.alignment(for: tool) == .leading)
    }

    // MARK: suggestedReplies

    @Test func suggestedRepliesEmptyForStatementOrBlank() {
        #expect(ConduitUI.ChatViewModel.suggestedReplies(forLastAssistant: "").isEmpty)
        #expect(ConduitUI.ChatViewModel.suggestedReplies(forLastAssistant: "   ").isEmpty)
        // A plain declarative statement (no question, no plan/done/error
        // markers) shouldn't produce noisy chips.
        #expect(ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "The file has 200 lines of Swift."
        ).isEmpty)
    }

    @Test func suggestedRepliesForGoAheadRequest() {
        let r = ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "Should I delete the old config file?"
        )
        #expect(r == ["Yes, go ahead", "No", "Explain"])
    }

    @Test func suggestedRepliesForStatedPlan() {
        // No question mark, but the agent declared a next step.
        let r = ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "I'll refactor the parser and add tests."
        )
        #expect(r == ["Go ahead", "Wait", "Explain"])
    }

    @Test func suggestedRepliesForCompletion() {
        let r = ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "Done — the build passes and all tests are green."
        )
        #expect(r == ["What's next?", "Show me", "Thanks"])
    }

    @Test func suggestedRepliesForError() {
        let r = ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "The command failed: permission denied on /etc/hosts."
        )
        #expect(r == ["Try again", "Show details", "Skip it"])
    }

    @Test func suggestedRepliesForGenericQuestion() {
        let r = ConduitUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "Which database are you using?"
        )
        #expect(r == ["Yes", "No", "Tell me more"])
    }

    @Test func suggestedRepliesNeverExceedThree() {
        // Whatever the branch, the contract is at most 3 chips.
        for text in [
            "Should I proceed? It failed earlier and I'll retry. Done?",
            "Error: I'll fix it. Want me to?",
        ] {
            #expect(ConduitUI.ChatViewModel.suggestedReplies(forLastAssistant: text).count <= 3)
        }
    }

    // MARK: isAgentWorking (typing-indicator predicate)

    @Test func isAgentWorkingTrueWhileStreaming() {
        // Streaming wins regardless of the trailing role/status/content.
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "assistant", lastStatus: "done", lastContentEmpty: false, isStreaming: true
        ))
    }

    @Test func isAgentWorkingTrueWhenUserMessageIsLast() {
        // The user just sent — no assistant turn has started yet.
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "user", lastStatus: "", lastContentEmpty: false, isStreaming: false
        ))
        // Case-insensitive on the role.
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "USER", lastStatus: "", lastContentEmpty: false, isStreaming: false
        ))
    }

    @Test func isAgentWorkingTrueForBusyAssistantBeforeFirstToken() {
        // Pre-first-token "thinking": assistant item exists, busy status, but
        // NO content yet → show the indicator.
        for status in ["thinking", "working", "pending", "streaming", "running"] {
            #expect(ConduitUI.ChatViewModel.isAgentWorking(
                lastRole: "assistant", lastStatus: status, lastContentEmpty: true, isStreaming: false
            ), "status \(status) with empty content should read as busy")
            // Status check is case-insensitive.
            #expect(ConduitUI.ChatViewModel.isAgentWorking(
                lastRole: "assistant", lastStatus: status.uppercased(), lastContentEmpty: true, isStreaming: false
            ))
        }
    }

    @Test func isAgentWorkingFalseWhenAssistantHasContent() {
        // Device feedback v0.0.68: the broker leaves a finished turn's status
        // stuck at a "busy" value ("running"/"working"). Once the assistant
        // has actually produced content and streaming has stopped, the turn
        // is DONE — the stale status must not keep the typing indicator on.
        for status in ["thinking", "working", "pending", "streaming", "running"] {
            #expect(!ConduitUI.ChatViewModel.isAgentWorking(
                lastRole: "assistant", lastStatus: status, lastContentEmpty: false, isStreaming: false
            ), "status \(status) with content present should read as settled")
        }
    }

    @Test func isAgentWorkingFalseForSettledAssistant() {
        #expect(!ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "assistant", lastStatus: "done", lastContentEmpty: false, isStreaming: false
        ))
        #expect(!ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "assistant", lastStatus: "", lastContentEmpty: true, isStreaming: false
        ))
    }

    @Test func isAgentWorkingFalseWhenNoEvents() {
        // Empty log → nil role/status → not busy.
        #expect(!ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: nil, lastStatus: nil, lastContentEmpty: true, isStreaming: false
        ))
    }

    @Test func isAgentWorkingTrustsServerTurnActiveOverLogRole() {
        // The reconnect fix: the broker's authoritative `turn_active` wins
        // over the log-role inference for structured-chat sessions.
        // turn_active=false clears a stuck indicator even though the trailing
        // log item is still the user's prompt (turn finished while
        // backgrounded) …
        #expect(!ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "user", lastStatus: "", lastContentEmpty: false,
            isStreaming: false, serverTurnActive: false
        ))
        // … and turn_active=true keeps it on even with a settled-looking log.
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "assistant", lastStatus: "done", lastContentEmpty: false,
            isStreaming: false, serverTurnActive: true
        ))
        // Local streaming still wins immediately (lower latency than waiting
        // for the next status frame).
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "assistant", lastStatus: "done", lastContentEmpty: false,
            isStreaming: true, serverTurnActive: false
        ))
        // nil (TUI-scrape session / pre-field broker) → fall back to the
        // log-role inference unchanged.
        #expect(ConduitUI.ChatViewModel.isAgentWorking(
            lastRole: "user", lastStatus: "", lastContentEmpty: false,
            isStreaming: false, serverTurnActive: nil
        ))
    }

    // MARK: - appearanceRenderRevision (per-row Equatable digest)

    @Test func appearanceRevisionStableForSameInputs() {
        let a = ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice",
            glow: true, dark: true, collapseTurns: false
        )
        let b = ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice",
            glow: true, dark: true, collapseTurns: false
        )
        #expect(a == b)
    }

    @Test func appearanceRevisionChangesWhenAnyInputChanges() {
        let base = ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice",
            glow: true, dark: true, collapseTurns: false
        )
        // Each render-affecting input must move the revision, or an
        // equatable row would stale-out when that setting changes.
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "mono", bodyPointSize: 15, palette: "ice", glow: true, dark: true, collapseTurns: false))
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 17, palette: "ice", glow: true, dark: true, collapseTurns: false))
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "amber", glow: true, dark: true, collapseTurns: false))
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice", glow: false, dark: true, collapseTurns: false))
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice", glow: true, dark: false, collapseTurns: false))
        #expect(base != ConduitUI.ChatViewModel.appearanceRenderRevision(
            fontFamily: "system", bodyPointSize: 15, palette: "ice", glow: true, dark: true, collapseTurns: true))
    }
}
