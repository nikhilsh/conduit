import Testing
import Foundation
@testable import Conduit

// MARK: - ThinkingStreamingTests
//
// Unit coverage for the thinking_streaming view_event pipeline:
//   1. ingestThinkingStreaming sets thinkingBySession.
//   2. thinkingBySession clears on final reply (shouldClearStreaming path).
//   3. thinkingBySession clears on turnActive=false status frame.
//   4. Old replay does NOT clear thinkingBySession (mirrors Bug-B guards).
//   5. ConduitUI.thinkingPeekLine helper: last non-empty line, trimmed, capped.

@Suite("thinking_streaming ingestion + clear")
@MainActor
struct ThinkingStreamingTests {

    // MARK: - ingestThinkingStreaming

    @Test func ingestSetsThinkingBySession() {
        let store = SessionStore()
        let sessionID = "thinking-set-\(UUID().uuidString)"

        store.ingestThinkingStreaming(sessionID, payload: ["content": "First reasoning line."])

        #expect(store.thinkingBySession[sessionID] == "First reasoning line.",
            "ingestThinkingStreaming must store content in thinkingBySession")
    }

    @Test func ingestUpdatesAccumulatedText() {
        let store = SessionStore()
        let sessionID = "thinking-update-\(UUID().uuidString)"

        store.ingestThinkingStreaming(sessionID, payload: ["content": "Part one."])
        store.ingestThinkingStreaming(sessionID, payload: ["content": "Part one.\nPart two."])

        #expect(store.thinkingBySession[sessionID] == "Part one.\nPart two.",
            "second ingest should overwrite with the accumulated text")
    }

    @Test func ingestIgnoresMissingContent() {
        let store = SessionStore()
        let sessionID = "thinking-no-content-\(UUID().uuidString)"

        store.ingestThinkingStreaming(sessionID, payload: [:])

        #expect(store.thinkingBySession[sessionID] == nil,
            "missing content key must be a no-op")
    }

    // MARK: - Clear on reply (shouldClearStreaming path)

    @Test func clearOnFinalReply() {
        let store = SessionStore()
        let sessionID = "thinking-clear-reply-\(UUID().uuidString)"
        let turnTs = "2026-07-01T12:00:01.000Z"

        store.ingestChatStreaming(sessionID, payload: [
            "content": "Streaming prose...",
            "turn_ts": turnTs,
        ])
        store.ingestThinkingStreaming(sessionID, payload: ["content": "Some deep thoughts."])

        // Final assistant message with matching ts triggers shouldClearStreaming.
        let finalMsg = ChatEvent(
            role: "assistant",
            content: "Done.",
            ts: turnTs,
            files: []
        )
        store.ingestChat(sessionID, finalMsg)

        #expect(store.thinkingBySession[sessionID] == nil,
            "final reply must clear thinkingBySession alongside streamingMessage")
    }

    @Test func oldReplayDoesNotClearThinkingBySession() {
        let store = SessionStore()
        let sessionID = "thinking-no-clear-replay-\(UUID().uuidString)"
        let turnTs = "2026-07-01T12:00:01.000Z"

        store.ingestChatStreaming(sessionID, payload: [
            "content": "In-flight prose...",
            "turn_ts": turnTs,
        ])
        store.ingestThinkingStreaming(sessionID, payload: ["content": "Current reasoning."])

        // An older replayed event (ts < turnTs) must NOT clear the thinking state.
        let oldReplay = ChatEvent(
            role: "assistant",
            content: "Old settled message.",
            ts: "2026-07-01T12:00:00.000Z",
            files: []
        )
        store.ingestChat(sessionID, oldReplay)

        #expect(store.thinkingBySession[sessionID] == "Current reasoning.",
            "old replay must not clear in-flight thinkingBySession")
    }

    // MARK: - Clear on status turnActive=false

    @Test func clearOnTurnActiveFalse() {
        let store = SessionStore()
        let sessionID = "thinking-clear-status-\(UUID().uuidString)"

        store.ingestChatStreaming(sessionID, payload: [
            "content": "Streaming...",
            "turn_ts": "2026-07-01T12:00:01.000Z",
        ])
        store.ingestThinkingStreaming(sessionID, payload: ["content": "Mid-flight thought."])

        // Prime the turn as active first.
        let activeStatus = SessionStatus(
            session: sessionID, assistant: "claude", phase: "running",
            health: "healthy", rows: 40, cols: 120, yolo: false, preview: nil,
            sessionName: nil, viewers: nil, turnActive: true,
            reasoningEffort: nil, cwd: nil, startedAt: nil, lastActivityAt: nil,
            displayName: nil, totalInputTokens: nil, totalOutputTokens: nil,
            totalCachedTokens: nil, totalCostUsd: nil, contextUsedTokens: nil,
            contextWindowTokens: nil
        )
        store.ingestStatus(activeStatus)

        // Turn goes idle.
        let idleStatus = SessionStatus(
            session: sessionID, assistant: "claude", phase: "idle",
            health: "healthy", rows: 40, cols: 120, yolo: false, preview: nil,
            sessionName: nil, viewers: nil, turnActive: false,
            reasoningEffort: nil, cwd: nil, startedAt: nil, lastActivityAt: nil,
            displayName: nil, totalInputTokens: nil, totalOutputTokens: nil,
            totalCachedTokens: nil, totalCostUsd: nil, contextUsedTokens: nil,
            contextWindowTokens: nil
        )
        store.ingestStatus(idleStatus)

        #expect(store.thinkingBySession[sessionID] == nil,
            "turnActive=false status must clear thinkingBySession")
    }
}

// MARK: - ThinkingPeekLineTests

@Suite("ConduitUI.thinkingPeekLine")
struct ThinkingPeekLineTests {

    @Test func nilInputReturnsNil() {
        #expect(ConduitUI.thinkingPeekLine(from: nil) == nil)
    }

    @Test func emptyInputReturnsNil() {
        #expect(ConduitUI.thinkingPeekLine(from: "") == nil)
    }

    @Test func whitespaceOnlyReturnsNil() {
        #expect(ConduitUI.thinkingPeekLine(from: "   \n  \n  ") == nil)
    }

    @Test func singleLineReturnsTrimmed() {
        #expect(ConduitUI.thinkingPeekLine(from: "  Hello world  ") == "Hello world")
    }

    @Test func multiLineReturnsLastNonEmpty() {
        let text = "First line.\nSecond line.\nThird line."
        #expect(ConduitUI.thinkingPeekLine(from: text) == "Third line.")
    }

    @Test func trailingBlankLinesSkipped() {
        let text = "First line.\nSecond line.\n\n   \n"
        #expect(ConduitUI.thinkingPeekLine(from: text) == "Second line.")
    }

    @Test func shortLineUnchanged() {
        let line = String(repeating: "x", count: 80)
        #expect(ConduitUI.thinkingPeekLine(from: line) == line)
    }

    @Test func longLineCappedAt80() {
        let long = String(repeating: "a", count: 100)
        let result = ConduitUI.thinkingPeekLine(from: long)
        #expect(result?.count == 80,
            "result must be 79 chars + ellipsis = 80 chars total")
        #expect(result?.hasSuffix("\u{2026}") == true,
            "capped line must end with an ellipsis")
    }

    @Test func exactly79CharsUnchanged() {
        let line = String(repeating: "b", count: 79)
        #expect(ConduitUI.thinkingPeekLine(from: line) == line)
    }
}
