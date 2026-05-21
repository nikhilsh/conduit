import Testing
import Foundation
@testable import SweKitty

/// Closes the SessionStore-tests deferred from PR #20.
///
/// SessionStore is the largest unit on the client and has heavy
/// init-time side effects (NWPathMonitor, NotificationCenter,
/// UserDefaults). The strategy doc accepts a thin first test against
/// `ingestChat` directly — that's what's here. Future PRs can widen
/// the surface (saved-server CRUD, dedupe, conversation refresh) once
/// a proper init seam exists.
@Suite("SessionStore.ingestChat")
@MainActor
struct SessionStoreTests {

    @Test func appendsChatEventToChatLog() {
        let store = SessionStore()
        let sessionID = "test-session-\(UUID().uuidString)"
        let event = ChatEvent(
            role: "assistant",
            content: "hello world",
            ts: "2026-05-21T08:00:00Z",
            files: []
        )

        store.ingestChat(sessionID, event)

        #expect(store.chatLog[sessionID]?.count == 1)
        #expect(store.chatLog[sessionID]?.first?.role == "assistant")
        #expect(store.chatLog[sessionID]?.first?.content == "hello world")
    }

    @Test func appendsAreOrderedAndPerSession() {
        let store = SessionStore()
        let session1 = "test-1-\(UUID().uuidString)"
        let session2 = "test-2-\(UUID().uuidString)"

        store.ingestChat(session1, ChatEvent(role: "user",      content: "first",  ts: "1", files: []))
        store.ingestChat(session2, ChatEvent(role: "user",      content: "other",  ts: "1", files: []))
        store.ingestChat(session1, ChatEvent(role: "assistant", content: "second", ts: "2", files: []))

        // Session 1 has both events in arrival order.
        #expect(store.chatLog[session1]?.map(\.content) == ["first", "second"])
        // Session 2 has only its own event — keys are isolated.
        #expect(store.chatLog[session2]?.map(\.content) == ["other"])
    }

    @Test func ingestWithoutClientDoesNotCrashRefreshConversation() {
        // ingestChat calls refreshConversation which has
        // `guard let client else { return }`. The test process has
        // no live client, so this exercises the no-op branch — if
        // someone refactors that guard out, this catches the crash.
        let store = SessionStore()
        let sessionID = "test-noclient-\(UUID().uuidString)"

        store.ingestChat(sessionID, ChatEvent(
            role: "assistant",
            content: "no client present",
            ts: "now",
            files: []
        ))

        // Survival is the assertion. chatLog still gets the event;
        // conversationLog stays whatever it was (empty by default).
        #expect(store.chatLog[sessionID]?.count == 1)
    }

    @Test func ingestStatusCarriesReasoningEffortThrough() {
        // Closes the "thread reasoning effort through ProjectSession"
        // TODO that used to live in SessionInfoView.swift. The Rust
        // core already folds `SessionStatus.reasoning_effort` into the
        // owning `ProjectSession` via `apply_status`; this test pins
        // the Swift side so a future refactor doesn't quietly drop
        // the field on the floor between the WS delegate callback and
        // the `statusBySession` dictionary the info sheet reads from.
        let store = SessionStore()
        let sessionID = "test-effort-\(UUID().uuidString)"

        let status = SessionStatus(
            session: sessionID,
            assistant: "claude",
            phase: "running",
            health: "healthy",
            rows: 40,
            cols: 120,
            yolo: false,
            preview: nil,
            sessionName: "demo",
            viewers: 1,
            reasoningEffort: "high",
            cwd: "/tmp/work",
            startedAt: "2026-05-21T08:00:00Z",
            lastActivityAt: "2026-05-21T08:01:00Z"
        )
        store.ingestStatus(status)

        let stored = store.statusBySession[sessionID]
        #expect(stored?.reasoningEffort == "high")
        #expect(stored?.cwd == "/tmp/work")
        #expect(stored?.assistant == "claude")
    }
}
