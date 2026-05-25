import Testing
import Foundation
@testable import SweKitty

/// Pins down the send/placeholder/alignment rules in
/// `LitterUI.ChatViewModel`. The SwiftUI `LitterChatView` is a thin
/// renderer; the model is where the logic lives.
@Suite("LitterUI.ChatViewModel")
struct LitterChatViewModelTests {

    @Test func canSendIsTrueOnlyWhenDraftHasNonWhitespace() {
        var snap = LitterUI.ChatSnapshot.empty
        #expect(LitterUI.ChatViewModel.canSend(snap) == false)

        snap.draft = "   "
        #expect(LitterUI.ChatViewModel.canSend(snap) == false)

        snap.draft = "hi"
        #expect(LitterUI.ChatViewModel.canSend(snap) == true)

        snap.draft = "\n\nhello\n"
        #expect(LitterUI.ChatViewModel.canSend(snap) == true)
    }

    @Test func placeholderUsesAgentNameWhenProvided() {
        #expect(LitterUI.ChatViewModel.composerPlaceholder(forAgent: "claude") == "Message claude…")
        #expect(LitterUI.ChatViewModel.composerPlaceholder(forAgent: nil) == "Message…")
        #expect(LitterUI.ChatViewModel.composerPlaceholder(forAgent: "") == "Message…")
    }

    @Test func userMessagesAlignTrailingEverythingElseLeading() {
        let user = LitterUI.ChatMessage(id: "1", role: .user, text: "hi", meta: nil)
        let assistant = LitterUI.ChatMessage(id: "2", role: .assistant, text: "hi", meta: nil)
        let system = LitterUI.ChatMessage(id: "3", role: .system, text: "warn", meta: nil)
        let tool = LitterUI.ChatMessage(id: "4", role: .tool, text: "out", meta: nil)

        #expect(LitterUI.ChatViewModel.alignment(for: user) == .trailing)
        #expect(LitterUI.ChatViewModel.alignment(for: assistant) == .leading)
        #expect(LitterUI.ChatViewModel.alignment(for: system) == .leading)
        #expect(LitterUI.ChatViewModel.alignment(for: tool) == .leading)
    }

    // MARK: suggestedReplies

    @Test func suggestedRepliesEmptyForStatementOrBlank() {
        #expect(LitterUI.ChatViewModel.suggestedReplies(forLastAssistant: "").isEmpty)
        #expect(LitterUI.ChatViewModel.suggestedReplies(forLastAssistant: "   ").isEmpty)
        // A plain declarative statement (no question, no plan/done/error
        // markers) shouldn't produce noisy chips.
        #expect(LitterUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "The file has 200 lines of Swift."
        ).isEmpty)
    }

    @Test func suggestedRepliesForGoAheadRequest() {
        let r = LitterUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "Should I delete the old config file?"
        )
        #expect(r == ["Yes, go ahead", "No", "Explain"])
    }

    @Test func suggestedRepliesForStatedPlan() {
        // No question mark, but the agent declared a next step.
        let r = LitterUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "I'll refactor the parser and add tests."
        )
        #expect(r == ["Go ahead", "Wait", "Explain"])
    }

    @Test func suggestedRepliesForCompletion() {
        let r = LitterUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "Done — the build passes and all tests are green."
        )
        #expect(r == ["What's next?", "Show me", "Thanks"])
    }

    @Test func suggestedRepliesForError() {
        let r = LitterUI.ChatViewModel.suggestedReplies(
            forLastAssistant: "The command failed: permission denied on /etc/hosts."
        )
        #expect(r == ["Try again", "Show details", "Skip it"])
    }

    @Test func suggestedRepliesForGenericQuestion() {
        let r = LitterUI.ChatViewModel.suggestedReplies(
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
            #expect(LitterUI.ChatViewModel.suggestedReplies(forLastAssistant: text).count <= 3)
        }
    }
}
