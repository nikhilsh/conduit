import Testing
import Foundation
@testable import SweKitty

/// Pins down the `LitterChatView` events-derivation contract — i.e.
/// what `LitterUI.ChatViewModel.mergedEvents(conversation:chatLog:)`
/// returns when the broker delivers an assistant reply through the
/// raw `chatLog` stream but not (yet) the typed `conversationLog`.
///
/// Pre-#119 the legacy `ChatTab` had the same fallback inline; the
/// #119 cutover dropped it and codex replies stopped surfacing in
/// the chat tab. These tests guard against a repeat regression.
@Suite("LitterUI.ChatViewModel.mergedEvents")
struct LitterChatIngestTests {

    // MARK: - Helpers

    private func conv(
        id: String,
        role: String,
        content: String,
        ts: String,
        kind: String = "message"
    ) -> ConversationItem {
        ConversationItem(
            id: id,
            role: role,
            kind: kind,
            status: "done",
            content: content,
            ts: ts,
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

    private func raw(role: String, content: String, ts: String) -> ChatEvent {
        ChatEvent(role: role, content: content, ts: ts, files: [])
    }

    // MARK: - Tests

    @Test func emptyChatLogReturnsConversationUnchanged() {
        let convo = [
            conv(id: "s-1", role: "user",      content: "hi",    ts: "1"),
            conv(id: "s-2", role: "assistant", content: "hello", ts: "2")
        ]
        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: convo,
            chatLog: []
        )
        #expect(merged.map(\.id) == ["s-1", "s-2"])
    }

    @Test func emptyConversationFallsBackEntirelyToChatLog() {
        // The bug shape from the report: typed conversationLog is empty
        // for an active codex session, but the broker delivered the
        // assistant reply through `on_chat_event` into `chatLog`. The
        // chat tab MUST surface it.
        let raws = [
            raw(role: "user",      content: "Testing",   ts: "10"),
            raw(role: "assistant", content: "Received.", ts: "11")
        ]
        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: [],
            chatLog: raws
        )
        #expect(merged.count == 2)
        #expect(merged.map(\.role) == ["user", "assistant"])
        #expect(merged.map(\.content) == ["Testing", "Received."])
        // Synthesized items carry a stable `chatlog-` prefix so they
        // sort/diff predictably and never collide with server ids.
        #expect(merged.allSatisfy { $0.id.hasPrefix("chatlog-") })
    }

    @Test func mergedEventsAreOrderedByTimestamp() {
        // Typed log has the user echo at ts=1; the broker later emits
        // the assistant reply through chatLog at ts=2. The merged
        // stream must keep them chronological (PR #111 contract).
        let convo = [conv(id: "s-1", role: "user", content: "hi", ts: "1")]
        let raws = [raw(role: "assistant", content: "reply", ts: "2")]

        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: convo,
            chatLog: raws
        )
        #expect(merged.map(\.ts) == ["1", "2"])
        #expect(merged.map(\.role) == ["user", "assistant"])
        #expect(merged.last?.content == "reply")
    }

    @Test func chatLogEventsAlreadyInConversationAreDeduped() {
        // `refreshConversation` may surface a typed item that mirrors
        // the same role+content the chatLog already has. Don't double
        // up — fingerprint (role|content) is the dedupe key, matching
        // the legacy local-echo handling in `SessionStore`.
        let convo = [
            conv(id: "s-1", role: "user",      content: "hi",    ts: "1"),
            conv(id: "s-2", role: "assistant", content: "hello", ts: "2")
        ]
        let raws = [
            raw(role: "user",      content: "hi",    ts: "1"),
            raw(role: "assistant", content: "hello", ts: "2")
        ]
        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: convo,
            chatLog: raws
        )
        #expect(merged.count == 2)
        #expect(merged.map(\.id) == ["s-1", "s-2"])
    }

    @Test func toolRoleSyntheticItemsCarryToolKind() {
        // A raw chat event with role=tool should synthesize a kind=tool
        // ConversationItem so LitterEventRow routes it to LitterToolCard
        // instead of LitterChatMessageRow (matches the legacy fallback
        // in deleted ChatTab.swift).
        let raws = [raw(role: "tool", content: "stdout: ok", ts: "1")]
        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: [],
            chatLog: raws
        )
        #expect(merged.count == 1)
        #expect(merged[0].role == "tool")
        #expect(merged[0].kind == "tool")
    }

    @Test func codexAssistantReplyReachesChatTabEvenWhenTypedLogIsSparse() {
        // End-to-end shape of the bug report: user types "Testing",
        // codex acks via PTY (`> Testing`) and replies with `Received.`
        // The broker mirrors both into chatLog via `on_chat_event`,
        // but listConversationItems hasn't caught up yet so only the
        // local user echo lives in the typed conversationLog. The
        // chat tab must still render the assistant reply.
        let convo = [
            // Local user echo from `sendChat`, carries a `local-` id.
            conv(id: "local-abc", role: "user", content: "Testing", ts: "10")
        ]
        let raws = [
            raw(role: "user",      content: "Testing",   ts: "10"),
            raw(role: "assistant", content: "Received.", ts: "11")
        ]
        let merged = LitterUI.ChatViewModel.mergedEvents(
            conversation: convo,
            chatLog: raws
        )
        let assistantReplies = merged.filter { $0.role == "assistant" }
        #expect(assistantReplies.count == 1)
        #expect(assistantReplies.first?.content == "Received.")
        // And the local user echo is preserved (not duplicated).
        #expect(merged.filter { $0.role == "user" }.count == 1)
    }
}
