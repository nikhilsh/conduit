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

    // MARK: - sendChat (bug #2: client-nil regression)

    /// `sendChat` used to start with `guard let client else { return }` —
    /// when the user fired a message during the brief window where the
    /// store had no live client (cold start, reconnect-in-flight) the
    /// optimistic local echo *and* the WS write were both swallowed.
    /// The screen stayed empty and the user thought the app was broken.
    /// We assert here that the local echo lands even without a client,
    /// matching the user-visible "Hi" that should appear immediately.
    @Test func sendChatLocallyEchoesEvenWithoutClient() {
        let store = SessionStore()
        let sessionID = "test-send-noclient-\(UUID().uuidString)"

        // No `connect()` call — `client` is nil.
        store.sendChat(sessionID: sessionID, message: "Hi")

        let log = store.conversationLog[sessionID] ?? []
        #expect(log.count == 1)
        #expect(log.first?.role == "user")
        #expect(log.first?.content == "Hi")
        #expect(log.first?.id.hasPrefix("local-") == true)

        // The raw chat log also gets it so the streaming coordinator
        // path and the Rust shadow store remain in lockstep.
        #expect(store.chatLog[sessionID]?.first?.content == "Hi")
    }

    // MARK: - refreshConversation ordering (bug #3)

    /// `refreshConversation` used to append `stillPending` after the
    /// server-side items. With the broker dropping user messages from
    /// its own typed log (the comment in `sendChat` calls this out),
    /// the local user echo ended up *below* the assistant reply when
    /// rendered — the UI showed the response above the prompt. The fix
    /// merges by timestamp so the order stays chronological. Driven
    /// directly via `ingestChat` (no live client needed): we seed a
    /// local user echo via `sendChat`, then ingest a later-ts assistant
    /// event and confirm the user message stays on top via chatLog,
    /// which is the canonical ordering source.
    @Test func ingestedAssistantEventAppearsAfterLocalUserEchoInChatLog() {
        let store = SessionStore()
        let sessionID = "test-order-\(UUID().uuidString)"

        // 1) Local user echo via sendChat (no client — exercises the
        //    bug-#2 fix too: the echo still lands).
        store.sendChat(sessionID: sessionID, message: "Hi")

        // 2) Broker delivers an assistant event with a later timestamp.
        let assistant = ChatEvent(
            role: "assistant",
            content: "Hello",
            ts: "2999-01-01T00:00:01Z",
            files: []
        )
        store.ingestChat(sessionID, assistant)

        // chatLog preserves arrival order — user first, assistant second.
        let chat = store.chatLog[sessionID] ?? []
        #expect(chat.map(\.role) == ["user", "assistant"])
        #expect(chat.map(\.content) == ["Hi", "Hello"])
    }

    // MARK: - Server-pill switch preserves session list (bug #1)

    /// `selectSavedServer(autoConnect: true)` for the *current* endpoint
    /// used to call `disconnect()`+`connect()`, which clobbered the
    /// visible `sessions` array because a fresh `SweKittyClient` returns
    /// `[]` from `list_sessions()` until status frames trickle in. The
    /// fix short-circuits when the endpoint hasn't changed (or when
    /// the harness is already reachable). This test pins that contract
    /// without standing up a real client: we plant a `SavedServer`
    /// matching the live endpoint and assert `selectSavedServer` does
    /// *not* tear down the harness state machine. Because there's no
    /// real connection, `harness` stays `.disconnected` — the assertion
    /// that matters is "we don't crash and the saved-servers list still
    /// holds the row" (which is what the home pill row reads).
    @Test func selectingActiveServerSkipsReconnect() {
        let store = SessionStore()
        let endpoint = StoredEndpoint(url: "ws://10.0.0.4:1977", token: "tok-\(UUID().uuidString)")
        store.endpoint = endpoint
        store.upsertSavedServer(name: "lab", endpoint: endpoint, makeDefault: true)
        let savedID = store.savedServers.first!.id

        // Simulate "already linked": the user is on this server and
        // sessions have been listed. Direct set is the only seam — no
        // public hook to manufacture a live `SweKittyClient` from the
        // test process. We're not asserting anything about `client`;
        // we just want to observe whether `selectSavedServer` flips
        // `harness` back to `.disconnected` (which is what would
        // happen if the old code path tore down the socket).
        store.harness = .live
        store.sessions = [
            ProjectSession(
                id: "sess-1",
                name: "demo",
                assistant: "claude",
                branch: nil,
                preview: nil,
                reasoningEffort: nil,
                cwd: nil,
                startedAt: nil,
                lastActivityAt: nil,
                displayName: nil
            )
        ]

        store.selectSavedServer(savedID, autoConnect: true)

        // Bug #1 fix: tapping the active server pill while linked
        // must not disconnect (which would empty the sessions list
        // until status frames repopulate it).
        #expect(store.harness == .live)
        #expect(store.sessions.map(\.id) == ["sess-1"])
        #expect(store.savedServers.contains(where: { $0.id == savedID }))
        #expect(store.endpoint == endpoint)
    }

    /// And: switching to a *different* saved server still triggers the
    /// reconnect path (otherwise the user would stay on the prior
    /// endpoint silently). We can only check the side-effect that
    /// `endpoint` updates and `harness` flips off `.live` — the actual
    /// new connection would need a live server.
    @Test func selectingDifferentServerTriggersReconnect() {
        let store = SessionStore()
        let a = StoredEndpoint(url: "ws://10.0.0.4:1977", token: "tok-a")
        let b = StoredEndpoint(url: "ws://10.0.0.5:1977", token: "tok-b")
        store.endpoint = a
        store.upsertSavedServer(name: "a", endpoint: a, makeDefault: true)
        store.upsertSavedServer(name: "b", endpoint: b, makeDefault: false)
        store.harness = .live

        let bID = store.savedServers.first(where: { $0.endpoint == b })!.id
        store.selectSavedServer(bID, autoConnect: true)

        #expect(store.endpoint == b)
        // disconnect() flipped us off live; connect() may have raced
        // to .connecting before we asserted, but either way it must
        // not have stayed .live (which would mean we skipped the
        // intentional bounce).
        #expect(store.harness != .live)
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
            lastActivityAt: "2026-05-21T08:01:00Z",
            displayName: nil
        )
        store.ingestStatus(status)

        let stored = store.statusBySession[sessionID]
        #expect(stored?.reasoningEffort == "high")
        #expect(stored?.cwd == "/tmp/work")
        #expect(stored?.assistant == "claude")
    }
}

/// `fix-history-readonly-default-live` — read-only is the DEFAULT for
/// any session not positively confirmed live on the broker. These pin
/// the inversion so a regression that re-introduces a default-`.live`
/// (the "History still interactive" bug) fails loudly.
@Suite("SessionStore.isReadOnly — read-only unless confirmed live")
@MainActor
struct SessionStoreReadOnlyTests {

    private func session(_ id: String) -> ProjectSession {
        ProjectSession(
            id: id, name: id, assistant: "claude", branch: nil,
            preview: nil, reasoningEffort: nil, cwd: nil,
            startedAt: nil, lastActivityAt: nil, displayName: nil
        )
    }

    private func status(_ id: String, phase: String) -> SessionStatus {
        SessionStatus(
            session: id, assistant: "claude", phase: phase, health: "green",
            rows: 40, cols: 120, yolo: false, preview: nil, sessionName: nil,
            viewers: 1, reasoningEffort: nil, cwd: nil, startedAt: nil,
            lastActivityAt: nil, displayName: nil
        )
    }

    // MARK: isLivePhase classifier

    @Test func livePhasesClassifyLive() {
        for p in ["running", "ready", "idle", "thinking", "RUNNING", " ready "] {
            #expect(SessionStore.isLivePhase(p), "\(p) should be live")
        }
    }

    @Test func terminalAndUnknownPhasesClassifyNotLive() {
        for p in ["exited", "exited(0)", "exited(137)", "failed", "dead", "", "swapped", "zombie"] {
            #expect(!SessionStore.isLivePhase(p), "\(p) should NOT be live")
        }
    }

    @Test func exitCodeParsesFromPhase() {
        #expect(SessionStore.exitCode(fromPhase: "exited(137)") == 137)
        #expect(SessionStore.exitCode(fromPhase: "exited(0)") == 0)
        #expect(SessionStore.exitCode(fromPhase: "exited") == nil)
    }

    // MARK: default = read-only

    @Test func unknownSessionIsReadOnly() {
        let store = SessionStore()
        #expect(store.isReadOnly(sessionID: "never-seen"))
    }

    @Test func listedButNoStatusIsReadOnly() {
        // The core's `list_sessions()` can return rows we have no fresh
        // running status for (recovered / dead). Mere presence must NOT
        // make the row interactive — this is the exact bug.
        let store = SessionStore()
        let id = "listed-\(UUID().uuidString)"
        store.sessions = [session(id)]
        #expect(store.isReadOnly(sessionID: id))
        #expect(!store.isConfirmedLive(sessionID: id))
    }

    // MARK: confirmed live = interactive

    @Test func runningStatusIsInteractive() {
        let store = SessionStore()
        let id = "live-\(UUID().uuidString)"
        store.ingestStatus(status(id, phase: "running"))
        #expect(store.isConfirmedLive(sessionID: id))
        #expect(!store.isReadOnly(sessionID: id))
    }

    // MARK: exited / recovered = read-only

    @Test func ingestExitMakesReadOnly() {
        let store = SessionStore()
        let id = "exit-\(UUID().uuidString)"
        store.ingestStatus(status(id, phase: "running"))
        #expect(!store.isReadOnly(sessionID: id))
        store.ingestExit(id, 0)
        #expect(store.isReadOnly(sessionID: id))
    }

    @Test func statusWithExitedPhaseIsReadOnlyEvenWithoutExitFrame() {
        // Joining an already-dead session: the broker's first status
        // frame reports `exited` (no prior `exit` frame on this client).
        // Must lock read-only, not promote to `.live`.
        let store = SessionStore()
        let id = "recovered-\(UUID().uuidString)"
        store.ingestStatus(status(id, phase: "exited(137)"))
        #expect(store.isReadOnly(sessionID: id))
        if case .exited(let code) = store.sessionLifecycle[id] {
            #expect(code == 137)
        } else {
            Issue.record("expected .exited lifecycle from an exited status phase")
        }
    }

    @Test func liveSessionDemotedByLaterExitedStatus() {
        let store = SessionStore()
        let id = "demote-\(UUID().uuidString)"
        store.ingestStatus(status(id, phase: "running"))
        #expect(!store.isReadOnly(sessionID: id))
        store.ingestStatus(status(id, phase: "exited"))
        #expect(store.isReadOnly(sessionID: id))
    }

    @Test func exitedLifecycleNeverRevivedByLaterRunningStatus() {
        // Terminal is terminal — a stale `running` delta after exit must
        // not resurrect an interactive surface.
        let store = SessionStore()
        let id = "terminal-\(UUID().uuidString)"
        store.ingestExit(id, 0)
        #expect(store.isReadOnly(sessionID: id))
        store.ingestStatus(status(id, phase: "running"))
        #expect(store.isReadOnly(sessionID: id))
    }
}

/// `ios-archive-delete-model` — pins the two-tier delete model split:
///   - `archive(sessionID:)` (home-list swipe): drops the row from the
///     live `sessions` list + ends it on the broker, but does NOT
///     tombstone — the session stays in History as a read-only transcript.
///   - `permanentlyDelete(sessionID:)` (History only): drops the live row
///     AND tombstones via `SavedSessionsStore`, so it leaves History for
///     good.
@Suite("SessionStore — archive vs permanent delete")
@MainActor
struct SessionStoreArchiveDeleteTests {

    private func session(_ id: String) -> ProjectSession {
        ProjectSession(
            id: id, name: id, assistant: "claude", branch: nil,
            preview: nil, reasoningEffort: nil, cwd: nil,
            startedAt: nil, lastActivityAt: nil, displayName: nil
        )
    }

    @Test func archiveDropsLiveRowButDoesNotTombstone() {
        let store = SessionStore()
        let id = "archive-\(UUID().uuidString)"
        store.sessions = [session(id)]
        store.selectedSessionID = id

        store.archive(sessionID: id)

        // Live row gone + selection cleared so the home list updates
        // immediately…
        #expect(!store.sessions.contains { $0.id == id })
        #expect(store.selectedSessionID == nil)
        // …but NO tombstone, so the History row survives as read-only.
        #expect(!SavedSessionsStore.shared.isTombstoned(id: id))
    }

    @Test func permanentlyDeleteDropsLiveRowAndTombstones() {
        let store = SessionStore()
        let id = "permadelete-\(UUID().uuidString)"
        store.sessions = [session(id)]
        store.selectedSessionID = id

        store.permanentlyDelete(sessionID: id)

        #expect(!store.sessions.contains { $0.id == id })
        #expect(store.selectedSessionID == nil)
        // Permanent delete is the ONLY path that tombstones.
        #expect(SavedSessionsStore.shared.isTombstoned(id: id))
    }
}

/// AI session titles (task: ai-session-titles): the broker-minted title
/// flows in via a `view:"session_title"` view_event and slots into the
/// display-name priority BELOW a manual rename and ABOVE the first user
/// message. These pin that ordering and the ingest guard so a refine
/// updates live and a blank title never clobbers a good name.
@Suite("SessionStore — AI session titles")
@MainActor
struct SessionStoreAITitleTests {
    private func session(_ id: String, assistant: String = "claude") -> ProjectSession {
        ProjectSession(
            id: id,
            name: id,
            assistant: assistant,
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: "2026-05-21T08:00:00Z",
            lastActivityAt: nil,
            displayName: nil
        )
    }

    @Test func aiTitleBeatsFirstMessageAndFallback() {
        let store = SessionStore()
        let id = "ai-title-\(UUID().uuidString)"
        let s = session(id)
        store.sessions = [s]

        // First user message is the priority-3 fallback.
        store.ingestChat(id, ChatEvent(role: "user", content: "please help me debug the broker", ts: "1", files: []))
        #expect(store.displayName(for: s) == "please help me debug the broker")

        // Broker AI title arrives → wins over the first message.
        store.ingestSessionTitle(id, payload: ["title": "Debug Broker Session Limit"])
        #expect(store.displayName(for: s) == "Debug Broker Session Limit")
    }

    @Test func manualRenameBeatsAITitle() {
        let store = SessionStore()
        let id = "ai-title-rename-\(UUID().uuidString)"
        let s = session(id)
        store.sessions = [s]

        store.ingestSessionTitle(id, payload: ["title": "Debug Broker Session Limit"])
        #expect(store.displayName(for: s) == "Debug Broker Session Limit")

        // A manual rename always wins.
        store.renameSession(sessionID: id, to: "My Session")
        #expect(store.displayName(for: s) == "My Session")
    }

    @Test func refineUpdatesLive() {
        let store = SessionStore()
        let id = "ai-title-refine-\(UUID().uuidString)"
        let s = session(id)
        store.sessions = [s]

        store.ingestSessionTitle(id, payload: ["title": "Initial Title"])
        #expect(store.displayName(for: s) == "Initial Title")

        store.ingestSessionTitle(id, payload: ["title": "Refined Better Title"])
        #expect(store.displayName(for: s) == "Refined Better Title")
    }

    @Test func blankTitleIsIgnored() {
        let store = SessionStore()
        let id = "ai-title-blank-\(UUID().uuidString)"
        let s = session(id)
        store.sessions = [s]
        store.ingestChat(id, ChatEvent(role: "user", content: "do the thing", ts: "1", files: []))

        // Good title, then a blank one must NOT clobber it.
        store.ingestSessionTitle(id, payload: ["title": "Real Title"])
        store.ingestSessionTitle(id, payload: ["title": "   "])
        #expect(store.displayName(for: s) == "Real Title")

        // And a session that only ever sees a blank title falls through to
        // the first user message.
        let id2 = "ai-title-blank2-\(UUID().uuidString)"
        let s2 = session(id2)
        store.sessions.append(s2)
        store.ingestChat(id2, ChatEvent(role: "user", content: "another ask", ts: "1", files: []))
        store.ingestSessionTitle(id2, payload: ["title": ""])
        #expect(store.displayName(for: s2) == "another ask")
    }

    @Test func uuidShapedTitleIsRejected() {
        // A model that echoed the bare id must not re-pollute the title.
        let store = SessionStore()
        let id = "11111111-2222-3333-4444-555555555555"
        let s = session(id)
        store.sessions = [s]
        store.ingestChat(id, ChatEvent(role: "user", content: "first ask", ts: "1", files: []))
        store.ingestSessionTitle(id, payload: ["title": id])
        #expect(store.displayName(for: s) == "first ask")
    }
}
