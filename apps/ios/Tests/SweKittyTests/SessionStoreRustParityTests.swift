import Testing
import Foundation
@testable import SweKitty

/// Parity safety-net for the Rust `SessionStoreCore` shadow-write.
///
/// PR `core-store-ios-dualwrite` keeps the existing Swift maps as the
/// read source of truth and folds every `ingest*` event into the Rust
/// reducer in parallel. This suite feeds the same event stream the
/// real harness would emit and asserts the Rust snapshot matches the
/// Swift state at each step — the eventual "flip reads to Rust" PR can
/// land with confidence that the reducer behaves identically.
@Suite("SessionStore.rustParity")
@MainActor
struct SessionStoreRustParityTests {

    @Test func chatEventsParity() {
        let store = SessionStore()
        let sessionID = "rust-parity-chat-\(UUID().uuidString)"

        store.ingestChat(sessionID, ChatEvent(role: "user", content: "first", ts: "t1", files: []))
        store.ingestChat(sessionID, ChatEvent(role: "assistant", content: "thinking", ts: "t2", files: []))
        store.ingestChat(sessionID, ChatEvent(role: "tool", content: "ran cargo test", ts: "t3", files: []))

        let swiftEvents = store.chatLog[sessionID] ?? []
        let rustEvents = store.rustStore.get(sessionId: sessionID)?.chat.events ?? []
        #expect(swiftEvents.count == rustEvents.count)
        #expect(zip(swiftEvents, rustEvents).allSatisfy { $0.role == $1.role && $0.content == $1.content && $0.ts == $1.ts })
    }

    @Test func ptyDataParity() {
        let store = SessionStore()
        let sessionID = "rust-parity-pty-\(UUID().uuidString)"

        // Feed two PTY chunks then an authoritative snapshot then a
        // post-snapshot append — exercises both the append + replace
        // codepaths in the dual-write.
        store.ingestPtyData(sessionID, Data("hello ".utf8))
        store.ingestPtyData(sessionID, Data("world".utf8))
        let swiftAfterPty = store.terminalBuffer[sessionID] ?? Data()
        let rustAfterPty = store.rustStore.get(sessionId: sessionID)?.terminal.scrollback ?? Data()
        #expect(swiftAfterPty == rustAfterPty)
        #expect(swiftAfterPty == Data("hello world".utf8))

        store.ingestSnapshot(sessionID, Data("authoritative".utf8))
        store.ingestPtyData(sessionID, Data(" + more".utf8))
        let swiftFinal = store.terminalBuffer[sessionID] ?? Data()
        let rustFinal = store.rustStore.get(sessionId: sessionID)?.terminal.scrollback ?? Data()
        #expect(swiftFinal == rustFinal)
        #expect(swiftFinal == Data("authoritative + more".utf8))
    }

    @Test func statusReasoningEffortAndLifecycleParity() {
        let store = SessionStore()
        let sessionID = "rust-parity-status-\(UUID().uuidString)"
        let status = SessionStatus(
            session: sessionID,
            assistant: "claude",
            phase: "running",
            health: "green",
            rows: 40,
            cols: 120,
            yolo: false,
            preview: nil,
            sessionName: "Demo",
            viewers: 1,
            reasoningEffort: "high",
            cwd: "/tmp/work",
            startedAt: "2026-05-21T08:00:00Z",
            lastActivityAt: "2026-05-21T08:01:00Z",
            displayName: nil
        )
        store.ingestStatus(status)

        let snap = store.rustStore.get(sessionId: sessionID)
        #expect(snap?.session.reasoningEffort == "high")
        #expect(snap?.session.cwd == "/tmp/work")
        #expect(snap?.status?.phase == "running")
        // ingestStatus also promotes lifecycle -> live on both sides.
        #expect(store.sessionLifecycle[sessionID] == .live)
        switch store.rustStore.lifecycle(sessionId: sessionID) {
        case .some(.live): break
        default: Issue.record("Rust lifecycle should be .live after ingestStatus")
        }
    }

    @Test func exitMarksRustStateAndLifecycle() {
        let store = SessionStore()
        let sessionID = "rust-parity-exit-\(UUID().uuidString)"
        let status = SessionStatus(
            session: sessionID,
            assistant: "claude",
            phase: "running",
            health: "green",
            rows: 24,
            cols: 80,
            yolo: false,
            preview: nil,
            sessionName: nil,
            viewers: nil,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: nil,
            lastActivityAt: nil,
            displayName: nil
        )
        store.ingestStatus(status)
        store.ingestExit(sessionID, 137)

        let snap = store.rustStore.get(sessionId: sessionID)
        #expect(snap?.exited == true)
        #expect(snap?.exitCode == Int32(137))
        switch store.rustStore.lifecycle(sessionId: sessionID) {
        case .some(.exited(let code)): #expect(code == Int32(137))
        default: Issue.record("Rust lifecycle should be .exited(137)")
        }
    }

    @Test func previewParity() {
        let store = SessionStore()
        let sessionID = "rust-parity-preview-\(UUID().uuidString)"
        store.ingestChat(sessionID, ChatEvent(role: "user", content: "go", ts: "t1", files: []))
        let preview = PreviewInfo(port: 5173, url: "http://127.0.0.1:5173")
        store.ingestPreview(sessionID, preview)
        let rustPreview = store.rustStore.get(sessionId: sessionID)?.browser.preview
        #expect(rustPreview?.port == 5173)
        #expect(rustPreview?.url == "http://127.0.0.1:5173")
        #expect(store.preview[sessionID]?.port == 5173)
    }
}
