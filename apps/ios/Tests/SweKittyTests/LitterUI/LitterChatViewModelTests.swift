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
}
