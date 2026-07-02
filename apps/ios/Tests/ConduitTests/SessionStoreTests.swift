import Testing
import Foundation
@testable import Conduit

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

        // Optimistic-send: with no client the message is QUEUED (not dropped)
        // and the echo is marked pending so the bubble shows "sending…". A
        // later connect/foreground flush re-delivers it.
        #expect(log.first?.status == "pending")
        let localID = log.first?.id ?? ""
        #expect(store.pendingChats.isPending(localID, in: sessionID))
        #expect(store.pendingChats.entries(for: sessionID).first?.message == "Hi")
    }

    // MARK: - UnknownSession downgrade (broker restart/GC)

    /// When the broker has forgotten a session (restart/redeploy/GC) a queued
    /// send returns `ConduitError.UnknownSession`. The deliver path must STOP
    /// retrying (drop the entry so later flushes don't re-hit the dead
    /// session) and flip the echo to `expired` so the bubble offers Resume,
    /// instead of burning the retry budget + capturing a Sentry ERROR.
    @Test func unknownSessionMarksEchoExpiredAndDropsFromQueue() {
        let store = SessionStore()
        let sessionID = "test-expired-\(UUID().uuidString)"

        // Seed an optimistic echo (no client -> queued + pending).
        store.sendChat(sessionID: sessionID, message: "Hi")
        let localID = store.conversationLog[sessionID]?.first?.id ?? ""
        #expect(store.pendingChats.isPending(localID, in: sessionID))

        // Drive the UnknownSession handler the deliver catch-branch calls.
        store.handleExpiredSession(sessionID: sessionID, localID: localID, box: nil)

        // Echo is now `expired` (drives the Resume footer) and the entry is
        // gone from the queue so flushes won't re-deliver into a dead session.
        #expect(store.conversationLog[sessionID]?.first?.status == "expired")
        #expect(store.pendingChats.isPending(localID, in: sessionID) == false)
    }

    /// The `UnknownSession` detector must match the exact UniFFI case (case 6)
    /// and reject every other error so genuine failures keep their retry +
    /// error-capture path.
    @Test func isUnknownSessionMatchesOnlyThatCase() {
        let store = SessionStore()
        #expect(store.isUnknownSession(ConduitError.UnknownSession(message: "gone")) == true)
        #expect(store.isUnknownSession(ConduitError.Connection(message: "x")) == false)
        #expect(store.isUnknownSession(ConduitError.NotConnected(message: "x")) == false)
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
    /// visible `sessions` array because a fresh `ConduitClient` returns
    /// `[]` from `list_sessions()` until status frames trickle in. The
    /// fix short-circuits when the endpoint hasn't changed (or when
    /// the harness is already reachable). This test pins that contract
    /// without standing up a real client: we plant a `SavedServer`
    /// matching the live endpoint and assert `selectSavedServer` does
    /// *not* tear down the harness state machine — `harness` must stay
    /// `.live` rather than bouncing back to `.connecting`.
    @Test func selectingActiveServerSkipsReconnect() {
        let store = SessionStore()
        let endpoint = StoredEndpoint(url: "ws://10.0.0.4:1977", token: "tok-\(UUID().uuidString)")
        store.endpoint = endpoint
        store.upsertSavedServer(name: "lab", endpoint: endpoint, makeDefault: true)
        let savedID = store.savedServers.first(where: { $0.endpoint == endpoint })!.id

        // Simulate "already linked": the user is on this server and
        // sessions have been listed. Direct set is the only seam — no
        // public hook to manufacture a live `ConduitClient` from the
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
                displayName: nil,
                totalInputTokens: nil,
                totalOutputTokens: nil,
                totalCachedTokens: nil,
                totalCostUsd: nil,
                contextUsedTokens: nil,
                contextWindowTokens: nil
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
            displayName: nil,
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalCachedTokens: nil,
            totalCostUsd: nil,
            contextUsedTokens: nil,
            contextWindowTokens: nil
        )
        store.ingestStatus(status)

        let stored = store.statusBySession[sessionID]
        #expect(stored?.reasoningEffort == "high")
        #expect(stored?.cwd == "/tmp/work")
        #expect(stored?.assistant == "claude")
    }

    // MARK: - hasPendingAsk + elicitation bypass (Bug 4 deadlock fix)

    /// `hasPendingAsk` must be true when the last non-user item is a
    /// `pending_input` and false otherwise. Pins the detection predicate
    /// so a rename of the kind string doesn't silently re-introduce the
    /// deadlock.
    @Test func hasPendingAskDetectsPendingInputKind() {
        let store = SessionStore()
        let sessionID = "test-pending-ask-\(UUID().uuidString)"

        // No items: should be false.
        #expect(!store.hasPendingAsk(sessionID: sessionID))

        // Seed a pending_input item directly into conversationLog.
        let pendingItem = ConversationItem(
            id: "pi-1", role: "assistant", kind: "pending_input",
            status: "pending", content: "Do you approve?",
            ts: "2026-06-12T10:00:00Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: ["Yes", "No"],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [pendingItem]
        #expect(store.hasPendingAsk(sessionID: sessionID))

        // After the user answers, hasPendingAsk clears immediately: a user
        // message following the prompt means the broker already consumed the
        // ask, so the next message is a normal turn (not an answer).
        let userEcho = ConversationItem(
            id: "local-1", role: "user", kind: "message",
            status: "pending", content: "Yes",
            ts: "2026-06-12T10:00:01Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [pendingItem, userEcho]
        // The user echo after the prompt clears it: the answer was sent, so a
        // further message is a new turn, not an answer to the (consumed) ask.
        #expect(!store.hasPendingAsk(sessionID: sessionID))

        // Replace the pending_input with a normal assistant response.
        let reply = ConversationItem(
            id: "srv-2", role: "assistant", kind: "message",
            status: "done", content: "Approved!",
            ts: "2026-06-12T10:00:02Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [pendingItem, userEcho, reply]
        #expect(!store.hasPendingAsk(sessionID: sessionID))
    }

    // MARK: hasPendingAsk scanning fix (Bug A)

    private func makeConversationItem(
        id: String, role: String, kind: String, content: String = ""
    ) -> ConversationItem {
        ConversationItem(
            id: id, role: role, kind: kind,
            status: "done", content: content,
            ts: "2026-06-12T10:00:00Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
    }

    /// pending_input followed by an assistant message should still be pending
    /// (the old strict-last-non-user check would return false here).
    @Test func hasPendingAskIgnoresTrailingAssistantItems() {
        let store = SessionStore()
        let sid = "test-trailing-\(UUID().uuidString)"
        let pi = makeConversationItem(id: "pi-1", role: "assistant", kind: "pending_input",
                                      content: "Approve?")
        let followUp = makeConversationItem(id: "msg-1", role: "assistant", kind: "message",
                                            content: "Thinking...")
        store.conversationLog[sid] = [pi, followUp]
        #expect(store.hasPendingAsk(sessionID: sid),
                "pending_input with trailing assistant msg should still be pending")
    }

    /// A resolved pending_input (broker marker present) followed by chatter
    /// must NOT be pending -- the answer is already done.
    @Test func hasPendingAskFalseWhenResolvedPendingInputFollowedByChatter() {
        let store = SessionStore()
        let sid = "test-resolved-trailing-\(UUID().uuidString)"
        let resolvedContent = "[[conduit:needs-input]]\n[[conduit:resolved]]{\"answered\":true,\"answer\":\"Yes\"}\nApprove?"
        let pi = makeConversationItem(id: "pi-1", role: "assistant", kind: "pending_input",
                                      content: resolvedContent)
        let followUp = makeConversationItem(id: "msg-1", role: "assistant", kind: "message",
                                            content: "Done!")
        store.conversationLog[sid] = [pi, followUp]
        #expect(!store.hasPendingAsk(sessionID: sid),
                "resolved pending_input with trailing chatter must NOT be pending")
    }

    /// No pending_input in the log at all: must return false.
    @Test func hasPendingAskFalseWhenNoPendingInput() {
        let store = SessionStore()
        let sid = "test-no-pi-\(UUID().uuidString)"
        let msg = makeConversationItem(id: "m1", role: "assistant", kind: "message",
                                       content: "Hello")
        store.conversationLog[sid] = [msg]
        #expect(!store.hasPendingAsk(sessionID: sid),
                "no pending_input means not pending")
    }

    /// `answerPendingInput` must create an optimistic echo and register a
    /// pending entry for delivery -- same guarantees as `sendChat` for the
    /// non-queued path. This pins that the answer is NOT dropped into the
    /// "Queued Next" queue (which would deadlock), and that the echo appears.
    @Test func answerPendingInputBypassesQueueAndEchoes() {
        let store = SessionStore()
        let sessionID = "test-answer-\(UUID().uuidString)"

        // Seed a pending_input so hasPendingAsk returns true.
        let pendingItem = ConversationItem(
            id: "pi-1", role: "assistant", kind: "pending_input",
            status: "pending", content: "Approve?",
            ts: "2026-06-12T10:00:00Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: ["Yes", "No"],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [pendingItem]

        // Simulate a broker turn_active=true status (the deadlock condition).
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
        #expect(store.isTurnActive(sessionID: sessionID))

        // sendChat must route to answerPendingInput and bypass the queue.
        store.sendChat(sessionID: sessionID, message: "Yes")

        // No optimistic user echo — answered pending-input cards show the
        // answer as a chip on the card itself, not as a separate YOU bubble.
        let log = store.conversationLog[sessionID] ?? []
        let userEcho = log.first(where: { $0.role == "user" })
        #expect(userEcho == nil, "answerPendingInput must not inject a YOU echo")

        // The answer must be in the NORMAL pending queue (not queuedTurn).
        let pending = store.pendingChats.entries(for: sessionID)
        #expect(pending.contains(where: { $0.message == "Yes" }))
        let queuedTurn = store.pendingChats.queuedTurnEntries(for: sessionID)
        #expect(queuedTurn.isEmpty, "elicitation answer must NOT go into the queuedTurn panel")
    }

    // MARK: - Bug B: streaming state survives broker replay on reconnect

    /// A replayed OLD assistant event (ts < active streamingTurnTs) must NOT
    /// clear streamingMessage or turnPhaseBySession. This is the root-cause
    /// scenario: on WS reconnect the broker replays the last 200 settled
    /// messages; each replayed assistant event previously cleared the live
    /// streaming state, making the chat look dead mid-turn.
    @Test func oldReplayedAssistantEventDoesNotClearStreamingState() {
        let store = SessionStore()
        let sessionID = "test-replay-\(UUID().uuidString)"

        // Simulate an active streaming turn: a chat_streaming payload
        // arrives with a known turn_ts.
        let turnTs = "2026-07-01T12:00:01.000Z"
        store.ingestChatStreaming(sessionID, payload: [
            "content": "Partial response so far...",
            "turn_ts": turnTs,
        ])
        store.turnPhaseBySession[sessionID] = "writing"

        // Broker replays an OLDER settled assistant message (ts < turnTs).
        let olderReplay = ChatEvent(
            role: "assistant",
            content: "This is a prior completed reply.",
            ts: "2026-07-01T12:00:00.000Z", // older than turnTs
            files: []
        )
        store.ingestChat(sessionID, olderReplay)

        // The live streaming state must be intact.
        #expect(store.streamingMessage[sessionID] == "Partial response so far...",
            "old replay must not clear in-flight streamingMessage")
        #expect(store.turnPhaseBySession[sessionID] == "writing",
            "old replay must not clear in-flight turnPhaseBySession")
        #expect(store.streamingTurnTs[sessionID] == turnTs,
            "old replay must not clear streamingTurnTs")
    }

    /// The current-turn final assistant event (ts >= streamingTurnTs) DOES
    /// clear streaming state — this is the normal turn-complete path.
    @Test func currentTurnAssistantEventClearsStreamingState() {
        let store = SessionStore()
        let sessionID = "test-current-turn-\(UUID().uuidString)"

        let turnTs = "2026-07-01T12:00:01.000Z"
        store.ingestChatStreaming(sessionID, payload: [
            "content": "Streaming...",
            "turn_ts": turnTs,
        ])
        store.turnPhaseBySession[sessionID] = "writing"

        // The final message arrives with the SAME ts as the streaming turn.
        let finalMsg = ChatEvent(
            role: "assistant",
            content: "Final completed reply.",
            ts: turnTs, // same ts as the streaming turn
            files: []
        )
        store.ingestChat(sessionID, finalMsg)

        // Streaming state must be cleared now that the turn is complete.
        #expect(store.streamingMessage[sessionID] == nil,
            "final turn message must clear streamingMessage")
        #expect(store.turnPhaseBySession[sessionID] == nil,
            "final turn message must clear turnPhaseBySession")
        #expect(store.streamingTurnTs[sessionID] == nil,
            "final turn message must clear streamingTurnTs")
    }

    /// A status frame with turnActive=false clears streaming state
    /// (safety net for cancelled turns / clock skew).
    @Test func statusTurnActiveFalseClearsStreamingState() {
        let store = SessionStore()
        let sessionID = "test-turn-done-\(UUID().uuidString)"

        // Seed active streaming state.
        store.ingestChatStreaming(sessionID, payload: [
            "content": "In progress...",
            "turn_ts": "2026-07-01T12:00:01.000Z",
        ])
        store.turnPhaseBySession[sessionID] = "working"

        // Mark the turn active first so the transition is detected.
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

        // Now turn transitions to idle.
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

        // Safety net must have cleared the streaming state.
        #expect(store.streamingMessage[sessionID] == nil,
            "turnActive=false status must clear streamingMessage")
        #expect(store.turnPhaseBySession[sessionID] == nil,
            "turnActive=false status must clear turnPhaseBySession")
        #expect(store.streamingTurnTs[sessionID] == nil,
            "turnActive=false status must clear streamingTurnTs")
    }
}

/// `restore-chat-on-reattach` — pins the conversation merge that splices a
/// reattached session's restored-from-disk past chat under the live items, so
/// a relaunch shows the prior conversation without doubling messages.
@Suite("SessionStore.mergeConversation — restore past chat on reattach")
struct MergeConversationTests {

    private func item(_ id: String, _ role: String, _ content: String, _ ts: String) -> ConversationItem {
        ConversationItem(
            id: id, role: role, kind: role == "tool" ? "tool" : "message",
            status: "done", content: content, ts: ts, files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [], sourceAgent: nil,
            targetAgent: nil, taskText: nil, resultSummary: nil, planSteps: []
        )
    }

    @Test func pastAndLiveSpliceChronologically() {
        let past = [
            item("saved-0", "user", "hello", "2026-06-05T10:00:00Z"),
            item("saved-1", "assistant", "hi there", "2026-06-05T10:00:05Z"),
        ]
        let live = [item("srv-9", "user", "what next", "2026-06-05T10:05:00Z")]
        let merged = SessionStore.mergeConversation(past: past, live: live, pending: [])
        // Past restored AND the new live turn present, in time order.
        #expect(merged.map(\.content) == ["hello", "hi there", "what next"])
    }

    @Test func liveWinsOverDuplicatePast() {
        // If the live list already represents a message (same role+content),
        // the past copy is dropped — no doubled bubble.
        let past = [item("saved-0", "user", "hello", "2026-06-05T10:00:00Z")]
        let live = [item("srv-1", "user", "hello", "2026-06-05T10:00:01Z")]
        let merged = SessionStore.mergeConversation(past: past, live: live, pending: [])
        #expect(merged.count == 1)
        #expect(merged.first?.id == "srv-1")
    }

    @Test func pendingLocalEchoIsKept() {
        let past = [item("saved-0", "assistant", "done", "2026-06-05T09:00:00Z")]
        let pending = [item("local-1", "user", "typing…", "2026-06-05T11:00:00Z")]
        let merged = SessionStore.mergeConversation(past: past, live: [], pending: pending)
        #expect(merged.map(\.content) == ["done", "typing…"])
    }

    @Test func emptyPastIsUnchangedLiveOrder() {
        let live = [
            item("a", "user", "one", "2026-06-05T10:00:00Z"),
            item("b", "assistant", "two", "2026-06-05T10:00:01Z"),
        ]
        let merged = SessionStore.mergeConversation(past: [], live: live, pending: [])
        #expect(merged.map(\.content) == ["one", "two"])
    }

    @Test func liveWithDuplicateRoleContentCollapsedToOne() {
        // Broker replays a pending AskUserQuestion on reconnect with a fresh ts;
        // apply_chat stores it again (different ts, same role+content) so
        // listConversationItems returns two entries. mergeConversation must keep
        // only the first (earliest-ts) copy so the UI doesn't render a duplicate.
        let live = [
            item("orig", "assistant", "Pick one", "2026-06-05T10:00:00Z"),
            item("replay", "assistant", "Pick one", "2026-06-05T10:00:05Z"),
        ]
        let merged = SessionStore.mergeConversation(past: [], live: live, pending: [])
        #expect(merged.count == 1)
        #expect(merged.first?.id == "orig")
    }

    @Test func resolvedPastWinsOverUnansweredLive() {
        // After close+reopen while a session is active: the live replay carries
        // the unanswered pending_input (broker no longer re-broadcasts the
        // resolved state). The HTTP transcript has the resolved version with
        // [[conduit:resolved]]. resolvedPendingInputIDs is empty on a fresh app
        // start, so the transcript version must win — it's the only source of
        // truth that the card was answered.
        let q = "Pick one\n1. A\n2. B"
        let marker = "[[conduit:resolved]]"
        let unansweredLive = item("live-1", "assistant", q, "2026-06-24T10:00:00Z")
        let resolvedPast = item(
            "saved-1", "assistant",
            "\(marker){\"answered\":true,\"answer\":\"A\"}\n\(q)",
            "2026-06-24T10:00:00Z"
        )
        let merged = SessionStore.mergeConversation(
            past: [resolvedPast], live: [unansweredLive], pending: []
        )
        #expect(merged.count == 1)
        #expect(merged.first?.content.contains(marker) == true)
        #expect(merged.first?.id == "saved-1")
    }
}

@Suite("SessionStore.stripPendingSentinel — HTTP replay matches the live path")
struct StripPendingSentinelTests {
    private let sentinel = "[[conduit:needs-input]]"

    @Test func dropsTheSentinelLine() {
        let raw = "\(sentinel)\nAllow codex to run this command?\n\nls -la\nin /root\n\n1. Approve\n2. Deny"
        let stripped = SessionStore.stripPendingSentinel(raw)
        #expect(!stripped.contains(sentinel))
        #expect(stripped.hasPrefix("Allow codex to run this command?"))
        // The non-sentinel body is preserved verbatim.
        #expect(stripped.contains("1. Approve"))
        #expect(stripped.contains("2. Deny"))
    }

    @Test func noSentinelIsUnchanged() {
        let raw = "just a normal assistant message\nwith two lines"
        #expect(SessionStore.stripPendingSentinel(raw) == raw)
    }

    @Test func strippedFingerprintMatchesLiveCard() {
        // The dup bug: HTTP replay kept the sentinel, so its role+content
        // fingerprint differed from the live (core-stripped) card and survived
        // mergeConversation's dedup. After stripping, the two match and the
        // live pending_input card wins.
        let liveBody = "Allow codex to run this command?\n\nls\nin /root\n\n1. Approve\n2. Deny"
        let pastRaw = "\(sentinel)\n\(liveBody)"
        #expect(SessionStore.stripPendingSentinel(pastRaw) == liveBody)
    }
}

/// Fresh-reload rehydration: a transcript fetched over HTTP (which bypasses
/// the Rust classifier) for a RESOLVED AskUserQuestion must map to a
/// `pending_input` ConversationItem whose `content` STILL carries the
/// resolution marker — so the view's `persistedResolution(event)` decodes
/// `answered=true` + the chosen option with NO local @State seeded. This is
/// the close+reopen scenario: the answered/selected state used to live only
/// in ephemeral SwiftUI @State and was lost on reload.
@Suite("SessionStore.mapRemoteItem — persisted answered pending-input rehydrates from transcript")
struct PendingInputRehydrationTests {
    private let sentinel = "[[conduit:needs-input]]"
    private let marker = "[[conduit:resolved]]"

    private func raw(_ content: String) -> RemoteConversationItem {
        RemoteConversationItem(role: "assistant", content: content, ts: "2026-06-22T12:00:00Z", files: nil)
    }

    @Test func answeredCardRehydratesSelectedOption() {
        let content = "\(sentinel)\n"
            + #"\#(marker){"answered":true,"answer":"Merge now"}"# + "\n"
            + "Proceed with the merge?\n1. Merge now\n2. Hold off"
        let item = SessionStore.mapRemoteItem(
            raw(content), sessionID: "s-1", idPrefix: "saved", index: 0
        )
        // Classified as the answered card (not a plain bubble).
        #expect(item.kind == "pending_input")
        // Marker survives in content for the view to decode; sentinel stripped.
        #expect(!item.content.contains(sentinel))
        #expect(item.content.contains(marker))
        // Exactly what the view's persistedResolution(event) does — no @State:
        // authoritative answered=true + the chosen option, after a fresh reload.
        let res = ConduitUI.ChatViewModel.parsePendingResolution(item.content)
        #expect(res?.answered == true)
        #expect(res?.answer == "Merge now")
        // The card's primary option source (parsePendingQuestions) recovers the
        // numbered options + question prose from the surviving content.
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(item.content)
        #expect(qs.count == 1)
        #expect(qs[0].prompt == "Proceed with the merge?")
        #expect(qs[0].options == ["Merge now", "Hold off"])
    }

    @Test func legacyCardWithoutMarkerRehydratesUnanswered() {
        // Backward-compat: a transcript written before this feature has no
        // resolution marker — it rehydrates as an unanswered pending card.
        let content = "\(sentinel)\nProceed?\n1. Yes\n2. No"
        let item = SessionStore.mapRemoteItem(
            raw(content), sessionID: "s-1", idPrefix: "saved", index: 0
        )
        #expect(item.kind == "pending_input")
        #expect(ConduitUI.ChatViewModel.parsePendingResolution(item.content) == nil)
        let qs = ConduitUI.ChatViewModel.parsePendingQuestions(item.content)
        #expect(qs.first?.options == ["Yes", "No"])
    }
}

/// `session-reconcile-broker-truth` — pins the wire contract for the
/// broker's authoritative live-session list (`GET /api/sessions`,
/// `broker/internal/session.LiveSessionInfo`). A careless rename of a
/// Swift property or a broker JSON tag would silently break reconcile
/// (sessions would never decode → the ACTIVE list would stay empty),
/// so lock the snake_case mapping here.
@Suite("LiveSessionInfo — /api/sessions wire shape")
struct LiveSessionInfoWireTests {

    @Test func decodesBrokerSnakeCaseJSON() throws {
        let json = """
        {
          "sessions": [
            {
              "id": "s-1",
              "assistant": "claude",
              "phase": "running",
              "health": "healthy",
              "running": true,
              "rows": 40,
              "cols": 120,
              "viewers": 1,
              "title": "Greeting And Initial",
              "cwd": "/root",
              "started_at": "2026-06-01T08:57:00Z",
              "last_activity_at": "2026-06-05T02:50:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(LiveSessionsResponse.self, from: json)
        #expect(resp.sessions.count == 1)
        let s = resp.sessions[0]
        #expect(s.id == "s-1")
        #expect(s.running == true)
        #expect(s.rows == 40)
        #expect(s.title == "Greeting And Initial")
        // The snake_case timestamps must map onto the camelCase fields —
        // this is the data that fixes the "wrong time" bug.
        #expect(s.startedAt == "2026-06-01T08:57:00Z")
        #expect(s.lastActivityAt == "2026-06-05T02:50:00Z")
    }

    @Test func decodesWithOptionalFieldsAbsent() throws {
        // Pre-feature / minimal rows omit title/cwd/timestamps — must
        // still decode (optionals → nil) rather than throwing.
        let json = """
        { "sessions": [
          { "id": "s-2", "assistant": "codex", "phase": "stalled",
            "health": "dead", "running": false, "rows": 24, "cols": 80,
            "viewers": 0 }
        ] }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(LiveSessionsResponse.self, from: json)
        let s = try #require(resp.sessions.first)
        #expect(s.running == false)
        #expect(s.title == nil)
        #expect(s.startedAt == nil)
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
            startedAt: nil, lastActivityAt: nil, displayName: nil,
            totalInputTokens: nil, totalOutputTokens: nil, totalCachedTokens: nil,
            totalCostUsd: nil, contextUsedTokens: nil, contextWindowTokens: nil
        )
    }

    private func status(_ id: String, phase: String) -> SessionStatus {
        SessionStatus(
            session: id, assistant: "claude", phase: phase, health: "green",
            rows: 40, cols: 120, yolo: false, preview: nil, sessionName: nil,
            viewers: 1, reasoningEffort: nil, cwd: nil, startedAt: nil,
            lastActivityAt: nil, displayName: nil,
            totalInputTokens: nil, totalOutputTokens: nil, totalCachedTokens: nil,
            totalCostUsd: nil, contextUsedTokens: nil, contextWindowTokens: nil
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
            startedAt: nil, lastActivityAt: nil, displayName: nil,
            totalInputTokens: nil, totalOutputTokens: nil, totalCachedTokens: nil,
            totalCostUsd: nil, contextUsedTokens: nil, contextWindowTokens: nil
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
            displayName: nil,
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalCachedTokens: nil,
            totalCostUsd: nil,
            contextUsedTokens: nil,
            contextWindowTokens: nil
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

    // MARK: - resolvePendingInput ts backfill (answered chip ordering fix)

    /// `resolvePendingInput` must backfill an empty `ts` on the pending_input
    /// card so it sorts before later assistant messages rather than floating
    /// to the bottom of the transcript.
    @Test func resolvePendingInputBackfillsEmptyTs() {
        let store = SessionStore()
        let sessionID = "test-backfill-ts-\(UUID().uuidString)"

        // Seed a pending_input with an empty ts (live card, not yet persisted).
        let pendingItem = ConversationItem(
            id: "pi-backfill", role: "assistant", kind: "pending_input",
            status: "pending", content: "Proceed?",
            ts: "", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: ["Yes", "No"],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        // A prior assistant message with a real ts so anchorEpoch has something to latch to.
        let prior = ConversationItem(
            id: "srv-prior", role: "assistant", kind: "message",
            status: "done", content: "Starting task...",
            ts: "2026-06-01T10:00:00.000Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [prior, pendingItem]

        store.resolvePendingInput(sessionID: sessionID)

        let resolved = store.conversationLog[sessionID] ?? []
        let resolvedCard = resolved.first(where: { $0.id == "pi-backfill" })
        #expect(resolvedCard != nil)
        // ts must now be non-empty and parseable (not greatestFiniteMagnitude).
        let epoch = conduitConversationTsEpoch(resolvedCard?.ts ?? "")
        #expect(epoch < .greatestFiniteMagnitude, "backfilled ts must be parseable")
        #expect(resolvedCard?.ts.isEmpty == false, "backfilled ts must not be empty")
    }

    /// An already-populated `ts` on a pending_input card must NOT be
    /// overwritten by `resolvePendingInput` — only empty/unparseable stamps
    /// are backfilled.
    @Test func resolvePendingInputDoesNotOverwriteRealTs() {
        let store = SessionStore()
        let sessionID = "test-no-overwrite-\(UUID().uuidString)"
        let realTs = "2026-06-01T09:00:00.000Z"
        let pendingItem = ConversationItem(
            id: "pi-real-ts", role: "assistant", kind: "pending_input",
            status: "pending", content: "Proceed?",
            ts: realTs, files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: ["Yes", "No"],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [pendingItem]

        store.resolvePendingInput(sessionID: sessionID)

        let resolved = store.conversationLog[sessionID] ?? []
        let resolvedCard = resolved.first(where: { $0.id == "pi-real-ts" })
        #expect(resolvedCard?.ts == realTs, "real broker ts must not be overwritten")
    }

    /// After `resolvePendingInput`, the answered chip (with backfilled ts)
    /// must sort BEFORE a later assistant message when the list is sorted by
    /// `sortedByConversationTs`. This is the invariant the bug violated.
    @Test func answeredChipSortsBeforeLaterAssistantMessage() {
        let store = SessionStore()
        let sessionID = "test-sort-order-\(UUID().uuidString)"

        let pendingItem = ConversationItem(
            id: "pi-sort", role: "assistant", kind: "pending_input",
            status: "pending", content: "Approve?",
            ts: "", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: ["Yes"],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        let prior = ConversationItem(
            id: "srv-prior", role: "assistant", kind: "message",
            status: "done", content: "Working...",
            ts: "2026-06-01T10:00:00.000Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        store.conversationLog[sessionID] = [prior, pendingItem]

        // Resolve (backfills the empty ts).
        store.resolvePendingInput(sessionID: sessionID)

        // A later assistant reply arrives after the answer.
        let laterReply = ConversationItem(
            id: "srv-later", role: "assistant", kind: "message",
            status: "done", content: "Done!",
            ts: "2026-06-01T10:00:02.000Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        let all = (store.conversationLog[sessionID] ?? []) + [laterReply]
        let sorted = all.sortedByConversationTs { $0.ts }

        let ids = sorted.map(\.id)
        let chipIdx = ids.firstIndex(of: "pi-sort") ?? Int.max
        let laterIdx = ids.firstIndex(of: "srv-later") ?? Int.max
        #expect(chipIdx < laterIdx, "answered chip must sort before the later assistant reply")
    }
}

// MARK: - conduitConversationTsEpoch — nanosecond RFC3339 parsing (bug fix)

/// Pins the nanosecond-RFC3339 parse fix: the broker stamps user-prompt
/// transcript entries with Go's time.RFC3339Nano (1-9 fractional digits,
/// trailing zeros trimmed). Before this fix, iOS ISO8601DateFormatter parsed
/// only exactly-0 or exactly-3 fractional digits; anything else returned nil
/// and sorted as .greatestFiniteMagnitude (newest/bottom), placing the user
/// answer BELOW the agent reply. The fix normalizes to exactly 3 digits first.
@Suite("conduitConversationTsEpoch — nanosecond RFC3339")
struct ConversationTsNanosecondTests {

    // Millisecond-precision reference for "2026-07-02T14:49:00.123Z".
    private let referenceEpoch: Double = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: "2026-07-02T14:49:00.123Z")!.timeIntervalSince1970
    }()

    // 1. Nanosecond ts parses to a FINITE epoch equal (within 1ms) to
    //    the millisecond-truncated form.
    @Test func nanosecondTsIsParseable() {
        let epoch = conduitConversationTsEpoch("2026-07-02T14:49:00.123456789Z")
        #expect(epoch < Double.greatestFiniteMagnitude, "nanosecond ts must parse finite")
        #expect(abs(epoch - referenceEpoch) < 0.001, "must be within 1ms of the ms-precision equivalent")
    }

    // 2a. 1-digit fractional (.5Z) parses finite and equals .500 reference.
    @Test func oneDigitFractionalParses() {
        let ref = conduitConversationTsEpoch("2026-07-02T14:49:00.500Z")
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00.5Z")
        #expect(got < Double.greatestFiniteMagnitude, "1-digit fractional must parse finite")
        #expect(abs(got - ref) < 0.001)
    }

    // 2b. 2-digit fractional (.50Z) parses finite.
    @Test func twoDigitFractionalParses() {
        let ref = conduitConversationTsEpoch("2026-07-02T14:49:00.500Z")
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00.50Z")
        #expect(got < Double.greatestFiniteMagnitude, "2-digit fractional must parse finite")
        #expect(abs(got - ref) < 0.001)
    }

    // 2c. 6-digit fractional parses finite and truncates to ms precision.
    @Test func sixDigitFractionalParses() {
        let ref = conduitConversationTsEpoch("2026-07-02T14:49:00.500Z")
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00.500000Z")
        #expect(got < Double.greatestFiniteMagnitude, "6-digit fractional must parse finite")
        #expect(abs(got - ref) < 0.001)
    }

    // 2d. 9-digit fractional parses finite.
    @Test func nineDigitFractionalParses() {
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00.123456789Z")
        #expect(got < Double.greatestFiniteMagnitude, "9-digit fractional must parse finite")
    }

    // 2e. All fractional lengths order correctly relative to each other.
    @Test func variableFractionalLengthsOrderCorrectly() {
        let t1 = conduitConversationTsEpoch("2026-07-02T14:49:00.1Z")    // 100ms
        let t2 = conduitConversationTsEpoch("2026-07-02T14:49:00.50Z")   // 500ms
        let t3 = conduitConversationTsEpoch("2026-07-02T14:49:00.500000Z") // 500ms
        let t4 = conduitConversationTsEpoch("2026-07-02T14:49:00.999999999Z") // 999ms
        #expect(t1 < t2)
        #expect(abs(t2 - t3) < 0.001, "2-digit and 6-digit same value must be equal")
        #expect(t3 < t4)
    }

    // 2f. Plain (no-fractional) ts still parses correctly.
    @Test func noFractionalTsParses() {
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00Z")
        #expect(got < Double.greatestFiniteMagnitude, "no-fractional ts must parse finite")
        // Must be earlier than the same second with fractional digits.
        let withFrac = conduitConversationTsEpoch("2026-07-02T14:49:00.5Z")
        #expect(got < withFrac)
    }

    // 3. Numeric-offset form parses finite.
    @Test func numericOffsetFractionalParses() {
        let got = conduitConversationTsEpoch("2026-07-02T14:49:00.123456+09:00")
        #expect(got < Double.greatestFiniteMagnitude, "numeric-offset nanosecond ts must parse finite")
    }

    // 4. Empty string still returns .greatestFiniteMagnitude (live-item invariant).
    @Test func emptyStringReturnsGreatestFiniteMagnitude() {
        let epoch = conduitConversationTsEpoch("")
        #expect(epoch == Double.greatestFiniteMagnitude, "empty ts must sort as newest")
    }

    // 5. The actual bug: user message with nanosecond broker ts sorts BEFORE
    //    an agent reply whose ts is 1 second later.
    @Test func userNanosecondTsSortsBeforeAgentReply() {
        // Simulate a broker-stamped user answer (nanosecond precision) and a
        // later agent reply (3-digit fractional, as typical for other paths).
        let userItem = ConversationItem(
            id: "user-ans", role: "user", kind: "message",
            status: "done", content: "My free-text answer",
            ts: "2026-07-02T14:49:00.123456789Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        let agentReply = ConversationItem(
            id: "agent-rep", role: "assistant", kind: "message",
            status: "done", content: "Here is my response",
            ts: "2026-07-02T14:49:01.000Z", files: [],
            toolName: nil, command: nil, exitCode: nil, durationMs: nil,
            diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
        let sorted = [agentReply, userItem].sortedByConversationTs { $0.ts }
        #expect(sorted.map(\.id) == ["user-ans", "agent-rep"],
            "user answer (nanosecond ts) must sort BEFORE the later agent reply")
    }
}
