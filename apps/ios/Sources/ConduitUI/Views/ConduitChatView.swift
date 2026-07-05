import SwiftUI
import UIKit

// MARK: - Chat A/B arm (chat-shell-v2, handoff §2)
//
// The resolved arm (Breathe / Signature) is injected once at the chat
// shell and read deep in the row tree via this environment value, so the
// per-turn presentation (spine lane vs. label) and tool-row weight branch
// without threading a parameter through every intermediate view. Rows are
// `.equatable()`; the arm is folded into `appearanceRenderRevision` so an
// A↔B switch re-renders every row.

private struct ChatArmKey: EnvironmentKey {
    static let defaultValue: FeatureFlags.ChatArm = .a
}

private struct CommandDetailEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct CommandRunBlockEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var chatArm: FeatureFlags.ChatArm {
        get { self[ChatArmKey.self] }
        set { self[ChatArmKey.self] = newValue }
    }
    var commandDetailEnabled: Bool {
        get { self[CommandDetailEnabledKey.self] }
        set { self[CommandDetailEnabledKey.self] = newValue }
    }
    var commandRunBlockEnabled: Bool {
        get { self[CommandRunBlockEnabledKey.self] }
        set { self[CommandRunBlockEnabledKey.self] = newValue }
    }
}

// MARK: - Foreground-restart helper

extension View {
    /// Run `restart` whenever the app returns to the foreground via
    /// `UIApplication.didBecomeActiveNotification`. Used to re-kick
    /// `withAnimation(.repeatForever)` sites that Core Animation suspends
    /// when the app is backgrounded: they freeze and never resume because
    /// the view stays mounted and `.onAppear` does not re-fire.
    ///
    /// Pattern: reset the animated state variable to its initial value
    /// inside `restart`, then immediately start the repeatForever animation
    /// toward the target value. The momentary reset is invisible (the view
    /// was not animating anyway).
    func restartAnimationOnForeground(restart: @escaping () -> Void) -> some View {
        self.onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            restart()
        }
    }
}

// MARK: - ConduitChatView
//
// Conduit-faithful chat surface. Mirrors upstream's ConversationView:
//   - Full-width assistant messages (no bubble, body weight, mono
//     when the user picks the mono body font)
//   - Right-aligned user messages, flat (no bubble), brand color
//     accent on the role label
//   - Fenced code blocks via `SyntaxHighlightedCodeBlock` (PR #46)
//   - Diff blocks rendered through `ConversationDiffParser`
//   - Tool / pending-input / handoff / subagent cards rendered
//     inline using the same data shape as the deleted ConversationView
//   - Composer pinned to bottom-safe-area: leading "+" attach,
//     central text field, trailing mic / send button
//
// Markdown rendering uses `AttributedString(markdown:)` with the same
// options the legacy `ConversationMarkdownBlock` used (full-syntax
// interpretation, parse-failure fallback to plain `text`). Cached
// through `MessageRenderCache.shared` keyed by `(itemID,
// hashValue)`; streaming buffers come from
// `StreamingRendererCoordinator.shared.renderState(for:)`.

// MARK: - Thinking peek helper

extension ConduitUI {
    /// Extracts the last non-empty, trimmed line of `text` for use as the
    /// working-indicator status override while the agent is in a thinking phase.
    /// Returns nil when text is nil, empty, or contains only whitespace lines.
    /// The result is capped at 80 characters (trailing ellipsis added if needed).
    static func thinkingPeekLine(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let line = text
            .components(separatedBy: "\n")
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        if line.count <= 80 { return line }
        let idx = line.index(line.startIndex, offsetBy: 79)
        return String(line[..<idx]) + "\u{2026}"
    }
}

extension ConduitUI {

    struct ChatView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(FeatureFlags.self) private var flags
        @Environment(StreamingRendererCoordinator.self) private var coordinator
        @Environment(\.neonTheme) private var neon
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        /// On tablet (regular width) the transcript is capped + centered so
        /// lines don't run the full pane width (handoff §6 — "max content
        /// width ~760pt"). Phone (compact) fills the width as before.
        private var chatContentMaxWidth: CGFloat {
            horizontalSizeClass == .regular ? 760 : .infinity
        }

        let session: ProjectSession

        /// When non-nil, the view renders these items read-only (an
        /// exited session's persisted transcript fetched over HTTP) and
        /// hides the composer + quick-reply bar. Live sessions pass nil
        /// and read from the store's `conversationLog` / `chatLog` as
        /// before.
        var readOnlyItems: [ConversationItem]? = nil

        /// Force read-only without injecting a transcript: a live-tracked
        /// session that has EXITED/been archived still has its events in
        /// the store's `conversationLog`/`chatLog`, so we render those (via
        /// the normal `events` path) but suppress the composer + quick-reply
        /// bar. `ProjectView` sets this for exited sessions; `readOnlyItems`
        /// stays the path for never-tracked rows that fetch over HTTP.
        var forceReadOnly: Bool = false

        /// Whether this chat is the visible/active tab. Device feedback
        /// v0.0.50 #3: `ProjectView` keeps the chat view MOUNTED across tab
        /// switches (rather than rebuilding it) so keyboard avoidance stays
        /// warm; this flag lets the view drop composer focus + the keyboard
        /// when it's hidden behind another tab, and never grab the keyboard
        /// while off-screen.
        var isActive: Bool = true

        @State private var draft: String = ""
        @State private var showVoiceDictation = false
        /// §D 401 handling: present the agent login sheet when the user taps
        /// "Sign in on this box" on the agent-auth-failure banner.
        @State private var showAgentLogin = false
        /// Consumed by AgentLoginSheet before OAuth starts so a sheet rebuild
        /// after the browser closes cannot launch the provider a second time.
        @State private var loginAutoStartProvider: OAuthProvider?
        /// How many of the most-recent transcript rows to render. Long chats
        /// were laggy because every row (markdown / tool parse) was laid out
        /// each render; we cap to the tail and let "Load earlier" widen it.
        @State private var visibleRowWindow = ConduitUI.ChatView.rowWindowStep
        /// Initial window size.
        static let rowWindowStep = 80
        /// Rows added per infinite-scroll widen. Half the initial window:
        /// an 80-row burst blocked the main thread long enough to read as
        /// scroll jank (perf investigation, post-v0.0.116); 40 keeps the
        /// eager prefetch comfortably ahead of the finger at half the
        /// per-widen cost.
        static let rowWidenStep = 40
        /// Rows from the top of the window that count as "nearing the
        /// top" — appearing one of these eagerly widens the window so
        /// older history is usually in place before the user hits it.
        static let eagerPrefetchRows = 8
        /// True while an infinite-scroll widen is in flight (spinner
        /// visible, repeated onAppear triggers coalesce).
        @State private var isWideningWindow = false
        /// True while a backward-pagination network fetch is in-flight.
        /// Used to show the "Loading earlier messages" spinner even after
        /// the local window covers all in-memory rows (network is lagging).
        /// Mirrors `store.isLoadingOlderBySession[session.id]` but is a
        /// local `@State` so the view is always on the main thread.
        @State private var isLoadingOlderNetwork = false
        // Composer attachments (#240 cross-surface): files picked via the
        // "+" menu sit here as removable chips until send. On send each
        // is uploaded via core `send_file` (0x01 frame → broker writes
        // `uploads/<sessionID>/<filename>`) and a reference line is
        // appended to the outgoing message.
        @State private var pendingAttachments: [ConduitUI.ComposerAttachment] = []
        @State private var attachError: String? = nil
        @State private var isUploading = false
        @FocusState private var composerFocused: Bool
        /// Global-space bottom Y of the composer row, measured via a backing
        /// GeometryReader. Logged in the keyboard diag so we can tell from
        /// Sentry whether the composer actually sits above the keyboard
        /// (composerMaxY ≤ keyboard top) or behind it — the missing signal that
        /// made the composer-behind-keyboard bug guesswork for many rounds.
        @State private var composerMaxY: CGFloat = 0
        /// Pending-input event ids the user has already answered. Held at
        /// the ChatView level (not in the card's @State) so the locked /
        /// "Sent" state SURVIVES the card being recreated when new events
        /// stream in — otherwise the lock reset and a second tap fired the
        /// option as a brand-new message, confusing the agent (device
        /// feedback, round 4: "I tap a reply, it doesn't seem to send, I
        /// tap another and it sends again").
        @State private var answeredPendingIDs: Set<String> = []

        private var isReadOnly: Bool { readOnlyItems != nil || forceReadOnly }

        // Task #39 — streaming auto-scroll that doesn't fight the user.
        // The controller is the pure state machine; the view feeds it
        // drag + bottom-proximity + streaming signals and reads back
        // `shouldFollow…` / `showScrollToBottomButton`.
        @State private var autoScroll = ChatAutoScrollController()
        /// Non-invalidating holder for the last scroll proximity band (see
        /// the gating in `.onScrollGeometryChange`). A reference type held
        /// in `@State` so mutating its field never re-evaluates the body —
        /// the whole point is to NOT invalidate on every scroll frame.
        @State private var proximityGate = ScrollProximityGate()
        // Opening a session must land on the LATEST message, not the top of
        // the history. The stream/new-message autoscroll observers only fire on
        // *changes*, so a session opened with pre-existing events never got an
        // initial scroll and sat at the top (device: "when I open a session I
        // start at the top, it should be at the bottom"). One-shot per session.
        @State private var didInitialScroll = false

        // Reply haptics (ChatGPT-style start/finish taps). The pure model
        // decides which tap to fire on each busy-state flip; the player is the
        // impure Taptic side. Re-seeded per session in `.onChange(of:
        // session.id)` so a stale busy state doesn't fire on session switch.
        @State private var replyHapticsModel = ReplyHapticsModel()
        @State private var replyHapticsPlayer = ReplyHapticsPlayer()
        /// Delayed-pause task: set on disappear, cancelled on reappear so a quick
        /// navigation-back doesn't needlessly pause+reconnect the WS.
        @State private var wsPauseTask: Task<Void, Never>?

        var body: some View {
            // The composer + suggestion cluster is hosted via
            // `.safeAreaInset(edge: .bottom)` on the messages `ScrollView`
            // (see `messagesList`), so SwiftUI lifts it above the soft
            // keyboard while the scroll content insets to keep the latest
            // message visible. The body just adds the voice sheet.
            messagesList
                // In-chat voice dictation. Mirrors the home-screen mic
                // (device bug #26) — same VoiceDictationSheet — and brings
                // the composer mic to parity with Android, which already
                // wires inline voice. The transcript lands in the draft so
                // the user reviews/edits before sending (we don't auto-fire
                // a half-heard prompt at the agent).
                .sheet(isPresented: $showVoiceDictation) {
                    VoiceDictationSheet(onTranscript: { text in
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty {
                            draft = draft.isEmpty ? t : draft + " " + t
                        }
                        showVoiceDictation = false
                        composerFocused = true
                    }, agent: session.assistant, sessionName: store.displayName(for: session))
                }
                // §D 401 handling: agent sign-in sheet, opened from the
                // agent-auth-failure banner. Preselect the session's provider
                // so the user lands on the right login flow.
                .sheet(isPresented: $showAgentLogin) {
                    ConduitUI.AgentLoginSheet(autoStartProvider: $loginAutoStartProvider)
                }
                // chat-shell-v2 (§2): resolve the arm once at the shell and
                // inject it for the row tree to read. Log the exposure event
                // the first time the chat shell mounts (idempotent).
                .environment(\.chatArm, flags.resolvedChatArm)
                .environment(\.commandDetailEnabled, flags.showCommandDetail)
                .environment(\.commandRunBlockEnabled, flags.commandRunBlock)
                .task { flags.logChatExposureIfNeeded() }
                // WS background throttle: resume when this chat comes into view,
                // park after a 30s grace on disappear so a quick back-then-forward
                // navigation doesn't bounce the connection. Skip read-only sessions
                // (no live WS to manage).
                .onAppear {
                    guard !isReadOnly else { return }
                    wsPauseTask?.cancel()
                    wsPauseTask = nil
                    store.resumeSession(session.id)
                }
                .onDisappear {
                    guard !isReadOnly else { return }
                    let sid = session.id
                    wsPauseTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        store.pauseSession(sid)
                    }
                }
                // Session switch reuses the view — re-arm the WS for the new session.
                .onChange(of: session.id) { old, new in
                    guard !isReadOnly else { return }
                    wsPauseTask?.cancel()
                    wsPauseTask = nil
                    store.resumeSession(new)
                    store.pauseSession(old)
                }
        }

        // MARK: Messages

        /// Reference-typed memo for the transcript pipeline. `events` /
        /// `chatRows` are computed properties, so without this the FULL
        /// merge (fingerprint set + O(N log N) ts-sort) and grouping
        /// (with a per-tool `extractCommand` classification) re-ran on
        /// EVERY body evaluation — i.e. on every keyboard inset change,
        /// autoscroll flip, and every near-top row's `onAppear` guard.
        /// That recompute tax was the top cause of scroll jank (perf
        /// investigation, post-v0.0.116). A class (not @State value) so
        /// refreshing the memo never invalidates the view.
        private final class TranscriptMemo {
            var fingerprint: Int?
            var events: [ConversationItem] = []
            var rows: [ConduitUI.ChatRow] = []
        }
        @State private var transcriptMemo = TranscriptMemo()

        /// Cheap O(N) change detector over the memo's inputs — id /
        /// status / content length per item (no full-content hashing).
        /// Orders of magnitude cheaper than the merge+sort+classify it
        /// guards; any mutation the pipeline could surface (new item,
        /// status flip, exit code, streamed content growth) moves it.
        private static func transcriptFingerprint(
            conversation: [ConversationItem],
            chatLog: [ChatEvent],
            readOnly: Bool,
            chatArm: String = "a",
            showCommandDetail: Bool = false
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(readOnly)
            hasher.combine(conversation.count)
            hasher.combine(chatLog.count)
            // Include the arm so switching A<->B in Labs re-groups rows.
            hasher.combine(chatArm)
            // Include showCommandDetail so toggling the setting invalidates
            // the memo and re-folds rows into the correct grouping.
            hasher.combine(showCommandDetail)
            for item in conversation {
                hasher.combine(item.id)
                hasher.combine(item.status)
                hasher.combine(item.content.count)
                hasher.combine(item.exitCode)
            }
            for ev in chatLog {
                hasher.combine(ev.ts)
                hasher.combine(ev.content.count)
            }
            return hasher.finalize()
        }

        /// Single memoized entry point for the transcript pipeline.
        private var transcript: (events: [ConversationItem], rows: [ConduitUI.ChatRow]) {
            let conversation = readOnlyItems ?? store.conversationLog[session.id] ?? []
            let chatLog = readOnlyItems == nil ? (store.chatLog[session.id] ?? []) : []
            let key = Self.transcriptFingerprint(
                conversation: conversation, chatLog: chatLog, readOnly: readOnlyItems != nil,
                chatArm: flags.resolvedChatArm.rawValue,
                showCommandDetail: flags.showCommandDetail
            )
            if transcriptMemo.fingerprint == key {
                return (transcriptMemo.events, transcriptMemo.rows)
            }
            // Read-only mode (exited session): render the injected
            // persisted transcript verbatim — nothing in the live store
            // to merge.
            //
            // Live mode (PR #111 + legacy ChatTab parity): prefer the
            // typed `conversationLog`, but fall back to the broker's raw
            // `chatLog` for events that haven't surfaced through the
            // structured `view_event` stream yet. Without this, codex
            // assistant replies (delivered via `on_chat_event`) showed
            // up in the Terminal tab but never reached the chat tab —
            // the #119 cutover dropped the legacy mapIndexed fallback.
            let events = readOnlyItems
                ?? ConduitUI.ChatViewModel.mergedEvents(conversation: conversation, chatLog: chatLog)
            // Fold into rows, collapsing contiguous runs of tool cards
            // (commands included -- round-3 §1) into one quiet bundle. A
            // run is "adjacent tool calls with no assistant prose between
            // them": any non-tool event closes the current bundle.
            //
            // When commandRunBlock is ON (§10/§10b flag), always group with
            // minRun:1 so even a single command lands in the Mono block.
            // When showCommandDetail is OFF (the default), collapse ALL tool
            // runs (even singletons, minRun:1) regardless of arm — every
            // contiguous tool sequence becomes a compact footnote. When ON,
            // restore today's arm-specific behaviour: arm B groups runs of 2+,
            // arm A renders every card standalone.
            let hideCommands = !flags.showCommandDetail
            let rows: [ConduitUI.ChatRow]
            let toolFilter: (ConversationItem) -> Bool = { ev in
                ev.role.lowercased() == "tool"
                    && ev.status.lowercased() != "swapping"
                    && !["pending_input", "handoff", "plan", "subagent"].contains(ev.kind)
            }
            if flags.commandRunBlock {
                // §10/§10b: always group every contiguous tool run (minRun:1)
                // so the Mono block handles rendering for runs of any size.
                rows = ConduitUI.ChatViewModel.groupedRows(events, minRun: 1, isGroupableTool: toolFilter)
            } else if hideCommands {
                rows = ConduitUI.ChatViewModel.groupedRows(events, minRun: 1, isGroupableTool: toolFilter)
            } else if flags.resolvedChatArm == .b {
                rows = ConduitUI.ChatViewModel.groupedRows(events, minRun: 2, isGroupableTool: toolFilter)
            } else {
                rows = events.map { ConduitUI.ChatRow.single($0) }
            }
            transcriptMemo.fingerprint = key
            transcriptMemo.events = events
            transcriptMemo.rows = rows
            return (events, rows)
        }

        private var events: [ConversationItem] { transcript.events }

        private var chatRows: [ConduitUI.ChatRow] { transcript.rows }

        /// Continuation = the previous row is a single message of the same
        /// role (used to suppress a repeated sender label). A tool group
        /// always breaks the run.
        private func continuation(in rows: [ConduitUI.ChatRow], at idx: Int, role: String) -> Bool {
            guard idx > 0, case .single(let prev) = rows[idx - 1] else { return false }
            return prev.role.lowercased() == role.lowercased()
        }

        /// Per-row streaming buffer length (0 when the event isn't
        /// streaming). Feeds the row's Equatable digest so a streaming
        /// message rebuilds per token while settled rows are skipped.
        private func streamRevision(for itemID: String) -> Int {
            if case .streaming(let buffer) = coordinator.renderState(for: itemID) {
                return buffer.count
            }
            return 0
        }

        /// Revision over every appearance/theme input that changes how a
        /// row renders (see `ChatViewModel.appearanceRenderRevision`).
        /// Folded into each row's Equatable digest so a theme / font /
        /// glow / palette / collapse / light-dark change re-renders all
        /// rows, while leaving them skippable otherwise.
        private var appearanceRevision: Int {
            ConduitUI.ChatViewModel.appearanceRenderRevision(
                fontFamily: appearance.fontFamily.rawValue,
                bodyPointSize: appearance.bodyPointSize,
                palette: appearance.neonPalette.rawValue,
                glow: appearance.neonGlow,
                dark: neon.dark,
                collapseTurns: appearance.collapseTurns,
                chatArm: flags.resolvedChatArm.rawValue
            )
        }

        /// Total length of all currently-streaming buffers. Changes on
        /// every token while the agent streams, so observing it drives
        /// "follow the stream" without re-reading the whole event list.
        /// Includes the streaming overlay content so overlay growth also
        /// triggers auto-scroll follow.
        private var streamingContentLength: Int {
            let coordLen = events.reduce(0) { acc, event in
                if case .streaming(let buffer) = coordinator.renderState(for: event.id) {
                    return acc + buffer.count
                }
                return acc
            }
            return coordLen + (streamingOverlayContent?.count ?? 0)
        }

        /// `true` while at least one event is mid-stream (either via the
        /// StreamingRendererCoordinator or the streaming overlay).
        private var isStreaming: Bool {
            if streamingOverlayContent?.isEmpty == false { return true }
            return events.contains { event in
                if case .streaming = coordinator.renderState(for: event.id) { return true }
                return false
            }
        }

        /// `true` while the agent is busy producing a reply — either
        /// actively streaming tokens OR in the pre-token "thinking" phase.
        /// Device feedback v0.0.50 #5: the typing indicator gated on
        /// `isStreaming` alone, so nothing showed during the (often
        /// multi-second) think before the first token arrived. We also
        /// treat "the user's message is the last thing in the log" (no
        /// assistant turn has started yet) and a working/thinking/pending
        /// assistant status as busy.
        private var isAgentWorking: Bool {
            let last = events.last
            let contentEmpty = (last?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ConduitUI.ChatViewModel.isAgentWorking(
                lastRole: last?.role,
                lastStatus: last?.status,
                lastContentEmpty: contentEmpty,
                isStreaming: isStreaming,
                // Authoritative broker turn-state: clears a stuck indicator
                // on reconnect / keeps it on when a turn is really running.
                // nil for TUI-scrape sessions or a pre-field broker → the
                // model falls back to log-role inference.
                serverTurnActive: store.statusBySession[session.id]?.turnActive
            )
        }

        /// Broker-reported turn phase for this session. "writing" = streaming
        /// text, "working" = tool calls, "" = thinking/waiting. nil = broker
        /// has not sent a turn_phase event yet (old broker).
        private var turnPhase: String? {
            store.turnPhaseBySession[session.id]
        }

        /// In-progress partial assistant content streamed before the final
        /// on_chat_event commits it to the Rust store. nil when no stream
        /// is active (old broker or between turns).
        private var streamingOverlayContent: String? {
            store.streamingMessage[session.id]
        }

        /// Accumulated thinking/reasoning text for the current turn
        /// (thinking_streaming view_events, Claude only). nil between turns.
        private var thinkingText: String? {
            store.thinkingBySession[session.id]
        }

        /// The last non-empty line of the current thinking text, trimmed and
        /// capped to 80 characters, for use as the indicator peek status.
        /// Returns nil when there is no thinking text or no non-empty lines.
        private var thinkingPeek: String? {
            ConduitUI.thinkingPeekLine(from: thinkingText)
        }

        /// Stable id for an invisible spacer pinned at the very end of
        /// the list. Scrolling to *this* (rather than the last event)
        /// guarantees we reach the absolute bottom — below the typing
        /// indicator and any trailing padding — so tap-to-bottom and
        /// stream-follow never land a few pixels short.
        private static let bottomAnchorID = "conduit-chat-bottom-anchor"

        /// Scroll to the true bottom, then re-scroll on the next runloop.
        /// A single `scrollTo` can land short while content is still
        /// laying out / streaming (the row it targets grows after the
        /// scroll resolves); the deferred second pass settles it onto the
        /// real bottom (BUG 2).
        private func scrollToTrueBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
            func jump() {
                if animated {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            jump()
            DispatchQueue.main.async { jump() }
        }

        /// Widen the visible row window for infinite scroll. Guarded so
        /// (a) the LazyVStack's initial top-down layout pass on open
        /// (before the jump-to-bottom lands) can't trigger a widen — the
        /// user must actually have scrolled up; (b) repeated onAppear
        /// bursts coalesce into one widen. After the new rows land, the
        /// previous top row is pinned back to the viewport top so the
        /// user's place is kept (content inserted above would otherwise
        /// shove the transcript down).
        ///
        /// BACKWARD PAGINATION: once the local window covers ALL in-memory
        /// rows (`chatRows.count <= visibleRowWindow`) AND the store has
        /// signalled more history exists (`store.hasMoreHistory(sessionID)`),
        /// a network fetch is triggered to prepend an older page. The anchor
        /// is re-pinned after the prepend so the viewport does not jump.
        private func widenRowWindow(proxy: ScrollViewProxy, anchorRowID: String?) {
            guard !isWideningWindow else { return }
            guard autoScroll.userScrolledUp else { return }

            // ---- local window widen ----
            if chatRows.count > visibleRowWindow {
                isWideningWindow = true
                // Perf telemetry (CLAUDE.md standing order): long-chat
                // hang/overheat is invisible without a device, so record the
                // scale of each widen — visible-window size + total rows — so
                // a hitch/ANR in Sentry carries the context to explain it.
                Telemetry.breadcrumb("chat_perf", "widen window", data: [
                    "visible": String(visibleRowWindow),
                    "next": String(visibleRowWindow + Self.rowWidenStep),
                    "total_rows": String(chatRows.count),
                    "events": String(events.count),
                ])
                // Brief defer so the spinner paints before the main-thread
                // row parse/layout burst.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    visibleRowWindow += Self.rowWidenStep
                    DispatchQueue.main.async {
                        if let anchorRowID {
                            proxy.scrollTo(anchorRowID, anchor: .top)
                        }
                        isWideningWindow = false
                        // LazyVStack resolves the inserted rows' heights
                        // lazily, so the first pin can land while content
                        // above is still growing; re-pin once more after
                        // layout settles (same trick as scrollToBottomOnOpen).
                        if let anchorRowID {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(anchorRowID, anchor: .top)
                            }
                        }
                    }
                }
                return
            }

            // ---- network backward-pagination ----
            // The local window already covers all in-memory rows. If the
            // store knows there is older history on the broker, kick off a
            // fetch. Guard against overlapping fetches; user gate is already
            // checked above (userScrolledUp).
            let sid = session.id
            guard store.hasMoreHistory(sid) else { return }
            guard !isLoadingOlderNetwork, !store.isLoadingOlderHistory(sid) else { return }
            isLoadingOlderNetwork = true
            Telemetry.breadcrumb("pagination", "trigger older page", data: [
                "session": sid,
                "total_rows": String(chatRows.count),
            ])
            Task { @MainActor in
                await store.fetchOlderConversation(sessionID: sid)
                isLoadingOlderNetwork = false
                // Re-pin the anchor so prepended rows don't shove the
                // viewport down. Two passes to handle lazy height resolution.
                if let anchorRowID {
                    proxy.scrollTo(anchorRowID, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(anchorRowID, anchor: .top)
                    }
                }
            }
        }

        /// On first open of a session, jump straight to the latest message. Not
        /// animated — we want to *start* at the bottom, not show a scroll from
        /// the top. Re-pinned across the first few layout passes because the
        /// `LazyVStack` rows resolve their heights lazily, so a single jump while
        /// history is still measuring lands short.
        private func scrollToBottomOnOpen(_ proxy: ScrollViewProxy) {
            guard !didInitialScroll, !events.isEmpty else { return }
            didInitialScroll = true
            // Record the scale of the transcript on open so a subsequent
            // scroll-hang/overheat event in Sentry shows how big the chat
            // was (the perf problem only bites long chats). Breadcrumb is
            // ring-buffered — one per session open, negligible cost.
            Telemetry.breadcrumb("chat_perf", "open transcript", data: [
                "events": String(events.count),
                "rows": String(chatRows.count),
                "windowed": String(min(chatRows.count, visibleRowWindow)),
            ])
            Task { @MainActor in
                for delayMs: UInt64 in [16, 60, 200, 500] {
                    if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }

        private var messagesList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // Window the transcript to the most recent rows so long
                        // chats stay smooth (parsing/laying out the full history
                        // every render was the lag source). "Load earlier"
                        // widens the window; the bottom anchor + autoscroll are
                        // unaffected since we keep the tail.
                        let allRows = chatRows
                        let rows = allRows.count > visibleRowWindow
                            ? Array(allRows.suffix(visibleRowWindow))
                            : allRows
                        // Infinite scroll (round-3 §6): a spinner sentinel
                        // replaces the old "Load earlier" button. Nearing
                        // the top eagerly widens the window; if the user
                        // outruns the prefetch they land on this spinner,
                        // which widens on appear — then they can keep
                        // scrolling into the loaded history.
                        //
                        // BACKWARD PAGINATION: the spinner also shows while a
                        // network older-page is in-flight (`isLoadingOlderNetwork`)
                        // even after the local window covers all in-memory rows,
                        // so there is no blank moment between the end of local
                        // history and the first broker page arriving. The
                        // `onAppear` handler fires in that case too and calls
                        // `widenRowWindow`, which detects the network path and
                        // starts the fetch.
                        let showSpinner = rows.count < allRows.count
                            || isLoadingOlderNetwork
                            || (rows.count == allRows.count && store.hasMoreHistory(session.id))
                        if showSpinner {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(neon.accent)
                                Text("Loading earlier messages…")
                                    .font(neon.sans(12).weight(.medium))
                                    .foregroundStyle(neon.textDim)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .onAppear {
                                widenRowWindow(proxy: proxy, anchorRowID: rows.first?.id)
                            }
                        }
                        // Credential-source banner: shown when the broker is
                        // using the app-forwarded credential because the box
                        // is not logged in locally.
                        if store.credentialSource[session.id] == "app_forwarded" {
                            HStack(spacing: 6) {
                                Image(systemName: "key.slash")
                                    .foregroundStyle(.orange)
                                Text("Using your app login \u{2014} box credential missing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1))
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            Group {
                                switch row {
                                case .single(let event):
                                    ConduitEventRow(
                                        event: event,
                                        isContinuation: continuation(in: rows, at: idx, role: event.role),
                                        sessionID: session.id,
                                        // Answered state is now AUTHORITATIVE from the
                                        // transcript (persistedResolution): the broker
                                        // records the resolution into the conversation
                                        // log, so a tapped option still shows selected
                                        // after the app is closed+reopened and across
                                        // devices. The ephemeral local @State (the
                                        // answeredPending* sets) stays only as the
                                        // instant on-tap feedback layer, superseded by
                                        // the persisted state on reload.
                                        pendingAnswered: persistedResolution(event)?.answered == true
                                            || answeredPendingIDs.contains(event.id)
                                            || store.isPendingInputAnswered(sessionID: session.id, fingerprint: pendingFingerprint(event))
                                            || store.resolvedPendingInputIDs.contains(event.id),
                                        answeredText: store.answeredTextForPendingInput(sessionID: session.id, fingerprint: pendingFingerprint(event))
                                            ?? persistedResolution(event)?.answer,
                                        streamRevision: streamRevision(for: event.id),
                                        appearanceRevision: appearanceRevision,
                                        onQuickReply: { reply in
                                            store.sendChat(sessionID: session.id, message: reply)
                                        },
                                        onPendingAnswered: { answer in
                                            answeredPendingIDs.insert(event.id)
                                            let fp = pendingFingerprint(event)
                                            store.markPendingInputAnswered(
                                                sessionID: session.id,
                                                fingerprint: fp,
                                                answer: answer ?? ""
                                            )
                                        }
                                    )
                                    // Perf (litter-parity): skip re-rendering a
                                    // row whose render-determining inputs didn't
                                    // change. The digest above keeps streaming +
                                    // theme correct.
                                    .equatable()
                                    .id(event.id)
                                    .padding(.horizontal, 16)
                                case .toolGroup(let items):
                                    ConduitToolBundleCard(items: items, sessionID: session.id)
                                        .id(row.id)
                                        .padding(.horizontal, 16)
                                }
                            }
                            // Eager prefetch: materializing a row near the
                            // window top means the user is approaching it.
                            // Anchor on THIS row (it's entering at the
                            // viewport's top edge) so the restore after the
                            // widen barely moves the user's place.
                            .onAppear {
                                if idx < Self.eagerPrefetchRows, rows.count < allRows.count {
                                    widenRowWindow(proxy: proxy, anchorRowID: row.id)
                                }
                            }
                        }
                        // Streaming spine: Direction C "Flowing conduit" render.
                        // Replaces the legacy ConduitStreamingOverlay. Shows while
                        // chat_streaming view_events deliver partial content.
                        // Old brokers never emit chat_streaming so this stays nil.
                        if let content = streamingOverlayContent, !content.isEmpty, !isReadOnly {
                            ConduitUI.StreamingSpineView(content: content, thinking: thinkingText)
                                .padding(.horizontal, 16)
                                .transition(.opacity)
                                .id("streaming-overlay")
                        }
                        // BUG 3: "agent is typing" indicator lives inside
                        // the scroll content so it follows autoscroll like
                        // any new content while the user is at the bottom.
                        // When streaming overlay is active, only show the
                        // indicator if there is no overlay content yet
                        // (pre-first-token thinking phase).
                        if isAgentWorking && !isReadOnly
                            && (streamingOverlayContent?.isEmpty ?? true) {
                            ConduitTypingIndicator(
                                turnPhase: turnPhase,
                                agent: session.assistant,
                                thinkingPeek: thinkingPeek
                            )
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                        }
                        // Zero-height bottom anchor — the scroll target for
                        // true-bottom jumps (sits below the typing row).
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.vertical, 14)
                    // Cap + center the transcript column on tablet (§6).
                    .frame(maxWidth: chatContentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .animation(.easeOut(duration: 0.18), value: isAgentWorking)
                }
                .scrollDismissesKeyboard(.interactively)
                // Empty conversation: a centered placeholder so a fresh chat
                // reads as "ready" instead of a blank void between the header
                // and the composer (device feedback).
                .overlay {
                    if events.isEmpty && !isReadOnly {
                        ConduitChatEmptyState(agent: session.assistant)
                            .allowsHitTesting(false)
                    }
                }
                // Device feedback v0.0.49 (round 2) #2: the scroll-to-bottom
                // arrow must float just ABOVE the composer, never on top of
                // the send button. It's applied BEFORE `.safeAreaInset(.bottom)`
                // so the inset lays this ScrollView (with the overlay) out in
                // the region above the composer cluster — `.bottomTrailing`
                // then resolves to the TOP edge of the composer, not the screen
                // bottom where Send lives (the prior order pinned it exactly on
                // Send). Zero vertical footprint; rides up with the keyboard.
                .overlay(alignment: .bottomTrailing) {
                    if !isReadOnly {
                        scrollToBottomButton(proxy: proxy)
                            .opacity(autoScroll.showScrollToBottomButton ? 1 : 0)
                            .scaleEffect(autoScroll.showScrollToBottomButton ? 1 : 0.8)
                            .allowsHitTesting(autoScroll.showScrollToBottomButton)
                            .accessibilityHidden(!autoScroll.showScrollToBottomButton)
                            .animation(.easeOut(duration: 0.2), value: autoScroll.showScrollToBottomButton)
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                    }
                }
                // Composer + suggestion bar as a bottom safe-area inset on
                // the ScrollView *itself* (not the ScrollViewReader): this
                // is the keyboard-tracking surface, so the whole cluster
                // rides up with the IME and the scroll content insets so
                // the latest message stays visible above it (device bug
                // #19). Exited sessions are a frozen transcript — no live
                // WS — so the cluster is suppressed in read-only mode.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isReadOnly {
                        VStack(spacing: 0) {
                            // §D 401 handling: when this session's chat surfaced
                            // an agent auth failure, show a clear "sign in on
                            // this box" affordance above the composer instead of
                            // leaving the bare 401 error as the last word. The
                            // store has already best-effort re-propagated any
                            // device credential; this banner covers the case
                            // where the box genuinely needs a sign-in.
                            agentAuthBanner
                            // Device feedback v0.0.49 (round 2) #1: the
                            // quick-reply chips float as translucent glass
                            // capsules over the chat (overlay-style, like the
                            // scroll arrow) — NO opaque strip behind them. Only
                            // the composer carries the solid surface background,
                            // so there is no flat dark "bar" the chips sit on.
                            suggestionBar
                            composer
                                // Diagnostic: record the composer's global
                                // bottom edge so the keyboard diag can prove
                                // whether it's above or behind the keyboard.
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .onAppear { composerMaxY = geo.frame(in: .global).maxY }
                                            .onChange(of: geo.frame(in: .global).maxY) { _, v in
                                                composerMaxY = v
                                            }
                                    }
                                )
                        }
                    }
                }
                // Measure distance from the bottom edge so the controller
                // can decide when the user has scrolled up vs. is pinned
                // to the latest. `contentOffset.y + bounds.height` is the
                // bottom of the visible viewport; subtracting from content
                // height gives the remaining scroll distance.
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    // Distance from the true bottom. When the user is pinned
                    // at the bottom, `contentOffset.y + bounds.height` equals
                    // `contentSize.height + contentInsets.bottom` (the scroll
                    // view scrolls past the content end to expose the inset
                    // band for the composer), yielding ≤ 0 at rest. The prior
                    // version added `contentInsets.bottom` a second time,
                    // making the resting distance equal the composer height
                    // (~200 pt) — keeping the scroll-to-bottom button visible
                    // even when the latest message was fully on screen (#251
                    // follow-up fix).
                    geo.contentSize.height
                        - (geo.contentOffset.y + geo.bounds.height)
                } action: { _, distance in
                    // PERF (long-chat overheat): `.onScrollGeometryChange`
                    // fires 60–120×/sec while scrolling. Writing the
                    // distance into the Equatable `@State autoScroll`
                    // every frame invalidated the WHOLE ChatView body each
                    // frame, which re-ran the O(history) transcript
                    // fingerprint per frame → pegged CPU → overheat/hang.
                    // No auto-scroll decision depends on the exact
                    // distance — only on which of three bands it's in
                    // (near-bottom clears the follow latch; the button's
                    // hysteresis band; far). Forward to the controller
                    // ONLY on a band change, so a scroll gesture costs a
                    // handful of @State writes, not thousands.
                    let band = autoScroll.proximityBand(for: distance)
                    if band == proximityGate.lastBand { return }
                    proximityGate.lastBand = band
                    autoScroll.bottomProximityChanged(distance)
                }
                // A finger-down drag is the user taking manual control —
                // latch `userScrolledUp` so streaming stops yanking them
                // back. The proximity observer above clears the latch once
                // they return near the bottom. Gated: `onChanged` also
                // fires per frame, so only write the latch on the edge
                // (same per-frame-invalidation hazard as the proximity
                // observer above).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            if !autoScroll.userScrolledUp { autoScroll.userDragged() }
                        }
                )
                // Follow the stream: re-scroll on each token, but only
                // while the user hasn't scrolled up.
                .onChange(of: streamingContentLength) { _, _ in
                    guard autoScroll.shouldFollowStreaming else { return }
                    // Follow the stream WITHOUT animating each token: a fresh
                    // `withAnimation` scroll 50×/sec scheduled a CADisplayLink
                    // interpolation per token and was a primary streaming-jank
                    // source. An unanimated jump-to-bottom tracks the growing
                    // content smoothly (the new-message / settle handlers below
                    // still animate their one-off scrolls).
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                // A brand-new message (user send / fresh assistant turn).
                .onChange(of: events.last?.id) { _, _ in
                    guard autoScroll.shouldFollowNewMessage else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                // ~300ms settle after the stream ends: the final layout
                // pass can change the last row's height once code blocks /
                // diffs finish parsing, so re-pin the bottom once things
                // are quiet (unless the user has scrolled away).
                .onChange(of: isStreaming) { wasStreaming, nowStreaming in
                    guard wasStreaming, !nowStreaming else { return }
                    guard autoScroll.shouldFollowStreaming else { return }
                    // Device feedback v0.0.50 #1: when the turn ends, the final
                    // message re-renders from the plain streaming buffer into
                    // the structured-markdown view (code blocks, headings) — a
                    // TALLER layout that lands a single settle-scroll short of
                    // the new bottom, so the scroll-to-bottom arrow lingers even
                    // though the user is visually at the end. Re-settle across
                    // the reflow window, bailing the instant the user takes
                    // manual control, so we reach the true bottom and the arrow
                    // fades out on its own.
                    Task {
                        for delayMs: UInt64 in [120, 350, 700, 1100] {
                            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                            guard autoScroll.shouldFollowStreaming else { return }
                            scrollToTrueBottom(proxy)
                        }
                    }
                }
                // Device feedback v0.0.49 (round 2) #3: returning to Chat from
                // another tab (Terminal → back → Chat) still trapped the
                // composer behind the keyboard. Root cause: leaving the tab
                // only called `endEditing`, never reset the @FocusState, so on
                // re-entry SwiftUI RESTORED the stale `composerFocused = true`
                // → the keyboard popped back up but the `.safeAreaInset`
                // avoidance didn't re-engage, hiding the input. Clearing the
                // focus state on both disappear and appear (not just
                // `endEditing`) keeps the composer at rest and visible; the
                // user re-taps to type and the keyboard then presents cleanly
                // with avoidance working.
                .onAppear {
                    composerFocused = false
                    dismissStrayKeyboard()
                    // Land on the latest message when history is already loaded.
                    scrollToBottomOnOpen(proxy)
                }
                .onDisappear { composerFocused = false }
                // Reply haptics: tap on the busy false→true (turn start) and
                // true→false (turn finish) flips. Suppressed when the chat
                // isn't the active tab/foreground (`isActive`) or the flag is
                // off — the model still tracks the flip so the NEXT real
                // transition is computed correctly, it just doesn't play.
                .onChange(of: isAgentWorking) { _, busy in
                    let event = replyHapticsModel.observe(
                        busy: busy,
                        enabled: flags.replyHaptics && isActive && !isReadOnly,
                        now: Date()
                    )
                    if let event { replyHapticsPlayer.play(event) }
                }
                // History often streams in just after appear (empty → populated);
                // pin the bottom on that first population too.
                .onChange(of: events.count) { old, new in
                    if old == 0 && new > 0 { scrollToBottomOnOpen(proxy) }
                }
                // Switching sessions reuses this view — re-arm for the next one.
                .onChange(of: session.id) { _, _ in
                    didInitialScroll = false
                    // Fresh haptics state: the next session's first observed
                    // busy flip shouldn't inherit this one's last state (which
                    // would fire a spurious start/finish on switch).
                    replyHapticsModel = ReplyHapticsModel()
                }
                // The view stays mounted across tab switches now, so drive
                // keyboard state off the active flag rather than appear/
                // disappear: drop focus + the keyboard when hidden behind
                // another tab, and clear any stray keyboard when shown again.
                .onChange(of: isActive) { _, active in
                    if active {
                        // Double-fire: a single synchronous endEditing loses a
                        // runloop race when the keyboard was left up by the
                        // terminal/browser tab (the foreign first responder may
                        // resign a beat later). Clearing again next runloop
                        // guarantees the stray keyboard is gone before the
                        // composer lays out, so its safeAreaInset avoidance
                        // engages on the user's next tap.
                        dismissStrayKeyboard()
                        DispatchQueue.main.async { dismissStrayKeyboard() }
                    } else {
                        // Leaving Chat (→ Terminal / Browser): drop the composer
                        // focus AND force-resign. Clearing @FocusState alone left
                        // the soft keyboard up over the Browser tab — UIKit had
                        // already shown it and SwiftUI's focus change didn't pull
                        // it back down (device feedback v0.0.81: "when I go
                        // browser the keyboard doesn't dismiss"). Double-fire the
                        // endEditing walk — now and next runloop — so a late
                        // re-present from the focus transition is caught too.
                        composerFocused = false
                        dismissStrayKeyboard()
                        DispatchQueue.main.async { dismissStrayKeyboard() }
                    }
                }
                // Sentry diagnostics for the recurring composer-behind-keyboard
                // bug (device bug #19 / reference_ios_keyboard_inset): log the
                // keyboard geometry + composer focus/active state on show/hide/
                // focus so on-device occurrences are debuggable remotely under
                // `diag=keyboard`. Bounded to ~2-3 events per interaction.
                .onChange(of: composerFocused) { _, focused in
                    logKeyboardDiag(focused ? "composer focused" : "composer blurred")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                    // Native avoidance (iOS 26+, FB13296535 fixed) handles the
                    // composer lift. Keep the scroll-to-bottom so the latest
                    // message stays visible when the keyboard appears, and keep
                    // the breadcrumb for Sentry diagnostics.
                    let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                    if autoScroll.shouldFollowNewMessage {
                        withAnimation(keyboardAnimation(note)) {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                    }
                    logKeyboardDiag("keyboard will show", keyboardFrame: frame)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    logKeyboardDiag("keyboard will hide")
                }
            }
        }

        /// The animation that matches the keyboard's own presentation, read
        /// from the notification. We drive the composer lift with THIS instead
        /// of a guessed `easeOut 0.2` (device feedback: on dismiss the composer
        /// hung in place — a gap opened where the keyboard had been — and only
        /// dropped once the keyboard was fully gone, because the lift ran on a
        /// different duration/curve than the IME). The keyboard uses a private
        /// curve (raw 7); we map the standard curves and fall back to
        /// `easeInOut`, which closely tracks it.
        private func keyboardAnimation(_ note: Notification) -> Animation {
            let info = note.userInfo
            let rawDuration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            let duration = KeyboardAnimationLogic.sanitizedDuration(rawDuration)
            let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
                ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
            switch curveRaw {
            case Int(UIView.AnimationCurve.easeIn.rawValue): return .easeIn(duration: duration)
            case Int(UIView.AnimationCurve.easeOut.rawValue): return .easeOut(duration: duration)
            case Int(UIView.AnimationCurve.linear.rawValue): return .linear(duration: duration)
            case 7: return .spring(response: duration, dampingFraction: 1.0)
            default: return .easeInOut(duration: duration)
            }
        }

        /// Emit a keyboard breadcrumb capturing the keyboard intrusion height,
        /// screen height, window safe-area bottom inset, and the composer
        /// focus/active state — the inputs that determine whether the
        /// `.safeAreaInset(.bottom)` composer is lifted clear of the soft
        /// keyboard or hidden behind it.
        ///
        /// This is a BREADCRUMB (not a Telemetry.debug event) because keyboard
        /// show/hide fires on every interaction — ~1090 useless standalone Sentry
        /// events per quota window. The geometry is still captured and attached
        /// to the next real error, which is exactly what we need to debug the
        /// keyboard-occlusion bug (device bug #19).
        private func logKeyboardDiag(_ reason: String, keyboardFrame: CGRect? = nil) {
            var safeBottom: CGFloat = 0
            var kbHeight: CGFloat = 0
            var kbTop: CGFloat = 0
            if let scene = UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene }) as? UIWindowScene,
               let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                safeBottom = window.safeAreaInsets.bottom
                if let frame = keyboardFrame {
                    kbHeight = max(0, window.bounds.maxY - frame.minY)
                    kbTop = frame.minY
                }
            }
            // overlap > 0 => the composer's bottom edge is BELOW the keyboard top,
            // i.e. hidden behind it. The definitive signal for this bug.
            let overlap = (kbTop > 0) ? max(0, composerMaxY - kbTop) : 0
            Telemetry.breadcrumb("keyboard", reason, data: [
                "composerFocused": "\(composerFocused)",
                "isActive": "\(isActive)",
                "kbHeight": String(format: "%.0f", kbHeight),
                "kbTop": String(format: "%.0f", kbTop),
                "composerMaxY": String(format: "%.0f", composerMaxY),
                "overlap": String(format: "%.0f", overlap),
                "screenH": String(format: "%.0f", UIScreen.main.bounds.height),
                "safeBottom": String(format: "%.0f", safeBottom),
            ])
        }

        /// Resign any first responder lingering from another tab so the
        /// chat composer never appears occluded by a stray soft keyboard
        /// on (re-)entry. Mirrors `ConduitProjectView.dismissKeyboard`'s
        /// `endEditing(true)` walk but scoped to the chat appear path.
        private func dismissStrayKeyboard() {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.endEditing(true)
                }
            }
        }

        /// Scroll-to-latest affordance, faded in when the user has
        /// scrolled a meaningful amount above the bottom. Tapping clears
        /// the latch and jumps to the absolute bottom (BUG 2).
        private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
            Button {
                autoScroll.scrollToBottomRequested()
                scrollToTrueBottom(proxy)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(neon.accent)
                    .frame(width: 40, height: 40)
                    // Glass disc (device feedback) — melds with the chat
                    // instead of a flat surface + neon halo.
                    .conduitGlassCircle()
                    // `conduitGlassCircle` ends in `.clipShape(Circle())` plus
                    // an interactive Liquid Glass effect, which left the button
                    // with no reliable hit region — the arrow showed but a tap
                    // never scrolled (device feedback). Restore an explicit
                    // ≥44pt tap target over the disc, exactly like the back /
                    // info glass buttons in ConduitProjectView.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scroll to latest message")
        }

        // MARK: Pending-input helpers

        /// Content fingerprint for a pending-input event: prompt + sorted
        /// options, joined with "|". Used as a dedupe key that survives broker
        /// re-emission of the same pending card under a fresh `id`. Passed to
        /// the SessionStore answered-fingerprint helpers (persists across view
        /// dismissals within the same app launch).
        private func pendingFingerprint(_ event: ConversationItem) -> String {
            let opts = event.pendingOptions.sorted().joined(separator: ",")
            let prompt = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(prompt)|\(opts)"
        }

        /// Authoritative answered-state for a pending-input event, decoded
        /// from the broker's persisted resolution marker in the transcript.
        /// nil when the event is not a pending-input card or carries no
        /// resolution (unanswered, or a legacy transcript). This is what makes
        /// a tapped option still render selected after the app is closed and
        /// reopened — the state used to live only in ephemeral SwiftUI @State.
        private func persistedResolution(_ event: ConversationItem)
            -> ConduitUI.ChatViewModel.PendingResolution?
        {
            guard event.kind == "pending_input" else { return nil }
            guard let res = ConduitUI.ChatViewModel.parsePendingResolution(event.content),
                  res.answered
            else { return nil }
            return res
        }

        // MARK: Suggested quick-replies

        /// Quick-reply chips shown above the composer when it's the
        /// user's turn. AI-generated chips from the broker
        /// (`view:"quick_replies"`, task #233) are PRIMARY; the legacy
        /// client-side heuristic is only a fallback for sessions where
        /// the broker sends none (feature disabled, codex, generation
        /// failed). Distinct from the agent's explicit pending-input
        /// options (`ConduitPendingInputCard` owns those), so we bail when
        /// the last event carries `pendingOptions`.
        private var suggestedReplies: [String] {
            guard let last = events.last,
                  last.role.lowercased() == "assistant",
                  last.pendingOptions.isEmpty else { return [] }
            let kind = last.kind.lowercased()
            guard kind == "message" || kind.isEmpty else { return [] }
            // Don't suggest mid-stream — wait for the turn to settle.
            let status = last.status.lowercased()
            guard !["streaming", "working", "thinking", "pending"].contains(status) else { return [] }
            // Primary: broker AI replies. They arrive after the turn ends,
            // so they may briefly lag the visible message — the heuristic
            // fills that gap and any non-claude session.
            if let ai = store.quickReplies[session.id], !ai.replies.isEmpty {
                return ai.replies
            }
            return ConduitUI.ChatViewModel.suggestedReplies(forLastAssistant: last.content)
        }

        @ViewBuilder
        private var suggestionBar: some View {
            let suggestions = suggestedReplies
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { reply in
                            Button {
                                store.sendChat(sessionID: session.id, message: reply)
                            } label: {
                                Text(reply)
                                    .font(neon.sans(13).weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(neon.accent)
                                    // Glass capsule — the surface+border+neon
                                    // halo read as a detached glow that didn't
                                    // meld with the chat (device feedback);
                                    // this matches the documented intent below.
                                    .conduitGlassCapsule()
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Send suggested reply")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                // Device feedback v0.0.49 (round 2) #1: NO bar background —
                // the chips float directly over the chat as glass capsules
                // (each `conduitGlassCapsule` is its own translucent blurred
                // surface), matching the floating scroll-to-bottom arrow. The
                // earlier `.ultraThinMaterial` strip still read as a flat,
                // opaque-looking row because the inset cluster painted an
                // opaque surface behind it; that backing now lives on the
                // composer alone.
            }
        }

        /// §D 401 handling: a clear "sign in on this box" affordance shown
        /// above the composer when this session's chat surfaced an agent auth
        /// failure (the store's `agentAuthFailure` flag). Tapping it opens the
        /// AgentLoginSheet preselected to the failing provider. The store has
        /// already best-effort re-pushed any device-stored credential, so a
        /// plain retry may already work — this covers the case where the box
        /// genuinely has no credential.
        @ViewBuilder
        private var agentAuthBanner: some View {
            if let provider = store.agentAuthFailure[session.id] {
                let providerLabel = provider == .anthropic ? "Claude" : "Codex"
                Button {
                    loginAutoStartProvider = provider
                    showAgentLogin = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sign in to \(providerLabel) on this box")
                                .font(neon.sans(13).weight(.semibold))
                            Text("This box rejected the agent credential (401). Tap to sign in.")
                                .font(neon.sans(11))
                                .foregroundStyle(neon.textDim)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(neon.sans(11).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                    }
                    .foregroundStyle(neon.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .conduitGlassCapsule()
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sign in to the agent on this box")
            }
        }

        // MARK: Composer

        // MARK: - Queued Next panel

        /// Entries currently held in the "Queued Next" panel for this session.
        private var queuedTurnEntries: [PendingChat] {
            store.pendingChats.queuedTurnEntries(for: session.id)
        }

        /// True when the agent for this session supports steer injection.
        private var sessionSupportsSteer: Bool {
            store.supportsSteer(sessionID: session.id)
        }

        @ViewBuilder
        private var queuedNextPanel: some View {
            let entries = queuedTurnEntries
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    // Panel header with optional count pill when >1 entry.
                    HStack(spacing: 6) {
                        Text("Queued Next")
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(neon.textDim)
                            .textCase(.uppercase)
                        if entries.count > 1 {
                            Text("\(entries.count)")
                                .font(neon.mono(10).weight(.bold))
                                .foregroundStyle(neon.accentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(neon.accent))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(entries, id: \.localID) { entry in
                        QueuedNextCard(
                            entry: entry,
                            supportsSteer: sessionSupportsSteer,
                            onSteer: {
                                store.steerQueuedEntry(
                                    sessionID: session.id,
                                    localID: entry.localID,
                                    message: entry.message
                                )
                            },
                            onCancel: {
                                store.cancelQueuedEntry(
                                    sessionID: session.id,
                                    localID: entry.localID
                                )
                            }
                        )
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut(duration: 0.18), value: entries.count)
            }
        }

        private var composer: some View {
            VStack(alignment: .leading, spacing: 0) {
                // "Queued Next" panel: sits above the composer text field,
                // below any plan/turn-progress UI, visible only while a turn
                // is active and the user has queued messages.
                queuedNextPanel

                // Picked-file chips + any transient pick/upload error
                // ride ABOVE the text field so they don't crowd the
                // send button, and stay inside the keyboard-tracking
                // inset cluster (#232/#236).
                if let attachError {
                    Text(attachError)
                        .font(neon.sans(12).weight(.medium))
                        .foregroundStyle(neon.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                if !pendingAttachments.isEmpty {
                    ConduitUI.ComposerAttachmentChips(
                        attachments: pendingAttachments,
                        onRemove: { attachment in
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        }
                    )
                }
                composerInputRow
            }
            .background(
                LinearGradient(
                    colors: [
                        neon.surfaceSolid.opacity(0),
                        neon.surfaceSolid.opacity(0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Accent-tinted glow rising up from the composer -- a quiet
            // ambient "you're talking to X" cue without painting the
            // surface. Low alpha + soft radius so it reads as ambient.
            .shadow(
                color: neon.accent.opacity(0.35),
                radius: 14,
                x: 0,
                y: -2
            )
        }

        private var composerInputRow: some View {
            HStack(spacing: 8) {
                ConduitUI.ComposerAttachButton(
                    onAttach: { attachment in
                        withAnimation(.easeOut(duration: 0.18)) {
                            pendingAttachments.append(attachment)
                            attachError = nil
                        }
                    },
                    onError: { message in
                        withAnimation(.easeOut(duration: 0.18)) { attachError = message }
                    }
                )

                TextField(
                    ConduitUI.ChatViewModel.composerPlaceholder(forAgent: session.assistant),
                    text: $draft,
                    axis: .vertical
                )
                .focused($composerFocused)
                .lineLimit(1...4)
                .font(neon.sans(16))
                .foregroundStyle(neon.text)
                .tint(neon.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // A rounded rect (not a Capsule) so multi-line input grows
                // into a tidy box instead of ballooning into a tall oval.
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(neon.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(neon.border, lineWidth: 1)
                )
                .onSubmit { send() }

                // Send is enabled by a non-empty draft OR at least one
                // pending attachment (attachment-only sends are valid --
                // the reference line is the message). Disabled mid-upload
                // so a double-tap can't fire two sends.
                let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let canSend = (hasDraft || !pendingAttachments.isEmpty) && !isUploading
                if hasDraft || !pendingAttachments.isEmpty {
                    Button(action: send) {
                        Group {
                            if isUploading {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 28, height: 28)
                            } else if isAgentWorking && sessionSupportsSteer {
                                // Codex turn active: steer glyph signals the message
                                // will be injected into the running turn.
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(neon.accentText)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(neon.accent))
                                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(neon.accentText)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(neon.accent))
                                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel(isAgentWorking && sessionSupportsSteer ? "Steer" : "Send")
                } else if isAgentWorking {
                    // Empty composer while the agent is producing output: show
                    // mic alongside Stop so the user can dictate their next
                    // message while the turn is still running. A voice transcript
                    // lands in the draft, flipping the trailing button to
                    // Send/Steer (the branch above). Typing does the same.
                    HStack(spacing: 8) {
                        Button {
                            showVoiceDictation = true
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(neon.textDim)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(neon.surface))
                                .overlay(Circle().stroke(neon.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Voice")
                        Button {
                            store.stopTurn(sessionID: session.id)
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(neon.accentText)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(neon.accent))
                                .neonGlowBox(neon.glow ? neon.glowBox : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop")
                    }
                } else {
                    Button {
                        showVoiceDictation = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.textDim)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(neon.surface))
                            .overlay(Circle().stroke(neon.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }

        private func send() {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = pendingAttachments
            guard !text.isEmpty || !attachments.isEmpty else { return }
            guard !isUploading else { return }

            // No attachments: keep the original synchronous send path so
            // the optimistic local echo lands instantly (no upload step).
            if attachments.isEmpty {
                store.sendChat(sessionID: session.id, message: text)
                draft = ""
                autoScroll.scrollToBottomRequested()
                return
            }

            // Attachments present: upload each (0x01 frame → broker
            // lands bytes at uploads/<sessionID>/<filename>) BEFORE the
            // chat message goes out, so the referenced paths exist when
            // the agent reads them. Clear the composer optimistically and
            // surface any upload failure inline.
            let sessionID = session.id
            let outgoing = ConduitUI.composeOutgoingMessage(
                draft: text,
                pendingAttachments: attachments,
                sessionID: sessionID
            )
            // Stash image bytes so the user's bubble can show a thumbnail of
            // what they just sent (the reference line only carries the path).
            for attachment in attachments where attachment.kind == .image {
                AttachmentBytesCache.shared.put(
                    sessionID: sessionID,
                    filename: attachment.filename,
                    bytes: attachment.bytes
                )
            }
            draft = ""
            pendingAttachments = []
            attachError = nil
            isUploading = true
            autoScroll.scrollToBottomRequested()
            Task {
                do {
                    for attachment in attachments {
                        try await store.sendFile(
                            sessionID: sessionID,
                            filename: attachment.filename,
                            mime: attachment.mimeType,
                            bytes: attachment.bytes
                        )
                    }
                    store.sendChat(sessionID: sessionID, message: outgoing)
                } catch {
                    withAnimation(.easeOut(duration: 0.18)) {
                        attachError = "Attachment upload failed. Tap send to retry."
                        // Restore the draft + chips so the user can retry
                        // without re-picking the files.
                        pendingAttachments = attachments
                        draft = text
                    }
                }
                isUploading = false
            }
        }
    }
}

// MARK: - Empty state

/// Centered placeholder shown when a live conversation has no events yet, so a
/// fresh chat doesn't render as a large empty void above the composer.
private struct ConduitChatEmptyState: View {
    let agent: String
    @Environment(\.neonTheme) private var neon

    private var agentName: String {
        let trimmed = agent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "your agent" : trimmed.capitalized
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(neon.accent)
                .neonTextGlow(neon.glow ? neon.textGlow?.tinted(neon.accent) : nil)
            Text("Message \(agentName) to get started")
                .font(neon.sans(15))
                .foregroundStyle(neon.textDim)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - QueuedNextCard
//
// One card in the "Queued Next" panel. Shows a truncated preview, a status
// badge (Queued / Steering / Retrying), an optional Steer button (codex only),
// and a cancel (X) button.

private struct QueuedNextCard: View {
    let entry: PendingChat
    /// True when the agent supports steer (codex app-server).
    let supportsSteer: Bool
    let onSteer: () -> Void
    let onCancel: () -> Void

    @Environment(\.neonTheme) private var neon

    /// Badge label per spec (exact strings).
    private var badgeLabel: String {
        switch entry.kind {
        case .normal:      return "Queued"
        case .queuedTurn:  return "Queued"
        case .steering:    return "Steering"
        case .retrying:    return "Retrying"
        }
    }

    /// Badge tint: Queued = accent, Steering = accentBright (brightest),
    /// Retrying = yellow (warning). Uses existing theme tokens.
    private var badgeColor: Color {
        switch entry.kind {
        case .normal, .queuedTurn: return neon.accent
        case .steering:             return neon.accentBright
        case .retrying:             return neon.yellow
        }
    }

    /// Steer button is enabled only when not already in-flight.
    private var canSteer: Bool {
        supportsSteer && (entry.kind == .queuedTurn || entry.kind == .retrying)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Message preview -- 1-2 lines, truncated.
            Text(entry.message)
                .font(neon.sans(13))
                .foregroundStyle(neon.text)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Status badge.
            Text(badgeLabel)
                .font(neon.mono(10).weight(.bold))
                .foregroundStyle(entry.kind == .steering ? neon.surfaceSolid : badgeColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(entry.kind == .steering ? badgeColor : badgeColor.opacity(0.15))
                )

            // Steer button (codex only, not while in-flight).
            if supportsSteer {
                Button(action: onSteer) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Steer")
                            .font(neon.sans(12).weight(.semibold))
                    }
                    .foregroundStyle(canSteer ? neon.accent : neon.textDim)
                }
                .buttonStyle(.plain)
                .disabled(!canSteer)
                .accessibilityLabel("Steer this message into the running turn")
            }

            // Cancel (X) button.
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(neon.surface))
                    .overlay(Circle().stroke(neon.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel queued message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(neon.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(neon.border, lineWidth: 1)
        )
    }
}

// MARK: - ConduitEventRow
//
// Per-message dispatch -- routes `ConversationItem` to the right inline
// card (pending input, handoff, subagent, tool, or chat message).

/// Holds the last scroll-proximity band across renders WITHOUT being a
/// SwiftUI state dependency — a reference type so mutating `lastBand`
/// never invalidates the view (see the gating in
/// `ConduitChatView.onScrollGeometryChange`).
private final class ScrollProximityGate {
    var lastBand: Int = -1
}

private struct ConduitEventRow: View, Equatable {
    let event: ConversationItem
    /// True when the immediately preceding event had the same role —
    /// used to suppress the redundant sender label on grouped runs.
    var isContinuation: Bool = false
    /// Live session id — threaded so the CommandCard's Re-run action can
    /// resend the command to the right session.
    var sessionID: String = ""
    /// Durable "already answered" flag for a pending-input card, owned by
    /// the ChatView so it survives this row being recreated.
    var pendingAnswered: Bool = false
    /// The previously-chosen answer text for an answered pending-input card,
    /// so a card recreated after reopen still shows the selection. nil when
    /// unanswered or the text wasn't captured.
    var answeredText: String? = nil
    /// Length of this event's live streaming buffer (0 when not
    /// streaming). In the Equatable digest so a streaming row rebuilds on
    /// each token while a settled row is skipped — without it,
    /// EquatableView would freeze a streaming message (its content
    /// arrives via the @Observable coordinator, not `event`).
    var streamRevision: Int = 0
    /// Revision over all appearance/theme inputs (see
    /// `appearanceRenderRevision`). In the digest so a theme/font change
    /// re-renders every row.
    var appearanceRevision: Int = 0
    let onQuickReply: (String) -> Void
    var onPendingAnswered: (String?) -> Void = { _ in }
    @Environment(AppearanceStore.self) private var appearance

    /// Skip re-rendering a row whose render-determining inputs are
    /// unchanged (perf: litter-parity). Closures are intentionally
    /// excluded — behaviorally stable and not Equatable. Every input that
    /// AFFECTS the output is compared: the event, layout flags, the
    /// streaming buffer length, and the appearance revision.
    static func == (lhs: ConduitEventRow, rhs: ConduitEventRow) -> Bool {
        lhs.event == rhs.event
            && lhs.isContinuation == rhs.isContinuation
            && lhs.sessionID == rhs.sessionID
            && lhs.pendingAnswered == rhs.pendingAnswered
            && lhs.answeredText == rhs.answeredText
            && lhs.streamRevision == rhs.streamRevision
            && lhs.appearanceRevision == rhs.appearanceRevision
    }

    var body: some View {
        if event.status.lowercased() == "swapping" {
            // Transient agent-swap marker — render the inline divider
            // instead of a full row (it's a transition, not a message).
            ConduitSwapNotice(from: event.sourceAgent ?? "", to: event.targetAgent ?? "")
        } else if event.kind == "pending_input" {
            ConduitPendingInputCard(
                event: event,
                alreadyAnswered: pendingAnswered,
                answeredText: answeredText,
                onQuickReply: onQuickReply,
                onAnswered: onPendingAnswered
            )
        } else if event.kind == "handoff" {
            ConduitHandoffCard(event: event)
        } else if event.kind == "plan" {
            ConduitPlanCard(event: event)
        } else if event.kind == "subagent" {
            ConduitSubagentCard(event: event)
        } else if event.role.lowercased() == "user", let peer = ConduitPeerMessage.parse(event.content) {
            ConduitPeerMessageCard(event: event, peer: peer)
        } else if event.role.lowercased() == "tool" {
            ConduitToolCard(event: event, sessionID: sessionID, collapseDefault: appearance.collapseTurns)
        } else {
            ConduitChatMessageRow(event: event, isContinuation: isContinuation, sessionID: sessionID)
        }
    }
}

private enum ConduitRole {
    case user, assistant, system, tool

    init(_ raw: String) {
        switch raw.lowercased() {
        case "user":      self = .user
        case "assistant": self = .assistant
        case "tool":      self = .tool
        default:          self = .system
        }
    }
}

// MARK: - Chat message row (user / assistant)

private struct ConduitChatMessageRow: View {
    let event: ConversationItem
    /// When true, the role header is hidden and top spacing is tightened
    /// to visually group consecutive same-sender messages.
    var isContinuation: Bool = false
    /// Live session id — threaded so the user bubble's failed-send retry can
    /// re-deliver to the right session.
    var sessionID: String = ""
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.neonTheme) private var neon
    /// chat-shell-v2 arm (§2). Arm A "Breathe" keeps ASSISTANT/YOU labels;
    /// arm B "Signature" wraps assistant turns in the conduit-spine lane.
    @Environment(\.chatArm) private var arm

    private var role: ConduitRole { ConduitRole(event.role) }

    /// Arm B routes assistant/system turns through the spine lane; the user
    /// bubble is shared by both arms (§2: "both arms share the green user
    /// bubble").
    private var usesSpine: Bool { arm == .b && role != .user }

    var body: some View {
        if usesSpine {
            signatureLane
        } else {
            breatheRow
        }
    }

    // MARK: Arm A — Breathe (today's chat, de-cramped)

    private var breatheRow: some View {
        let alignment: HorizontalAlignment = role == .user ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 4) {
            if !isContinuation {
                Text(roleLabel)
                    // Role labels stay mono (terminal-shaped chrome) +
                    // glow when the label is the accent (user / tool).
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(roleColor)
                    .textCase(.uppercase)
                    .neonTextGlow(roleGlow)
            }
            messageContent
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
        // Continuation rows get tighter top spacing: the LazyVStack's 14pt
        // gap minus 10pt offset makes grouped messages sit closer together.
        .padding(.top, isContinuation ? -10 : 0)
    }

    // MARK: Arm B — Signature (the conduit spine)

    /// Each assistant turn is a lane: the daemon mark at its head and a
    /// cyan→green line running down it (§2, `03-chat`). Continuation rows
    /// keep the line but drop a second mark so a multi-message turn reads as
    /// one lane.
    private var signatureLane: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                if isContinuation {
                    spineLine
                } else {
                    ConduitUI.ConduitMark(size: 18, color: neon.codex, glow: neon.glow)
                    spineLine.padding(.top, 5)
                }
            }
            .frame(width: 18)
            messageContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, isContinuation ? -8 : 0)
    }

    /// The vertical cyan→green spine that runs down an assistant lane.
    private var spineLine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [neon.codex, neon.green],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .opacity(0.55)
    }

    /// The message body, shared by both arms: user → green bubble; everyone
    /// else → flat prose blocks. Files strip underneath when present.
    @ViewBuilder
    private var messageContent: some View {
        if role == .user {
            // The bubble strips its own `[attached …]` reference lines
            // and renders them as chips/thumbnails instead of raw paths.
            ConduitUserBubble(event: event, sessionID: sessionID)
        } else {
            ConduitBlockStack(
                blocks: ConversationRenderer.blocks(for: event.content),
                role: role,
                itemID: event.id
            )
        }
        if !event.files.isEmpty {
            ConduitFileStrip(files: event.files)
        }
    }

    private var roleLabel: String {
        switch role {
        case .user:      return "you"
        case .assistant: return "assistant"
        case .system:    return "system"
        case .tool:      return "tool"
        }
    }

    private var roleColor: Color {
        switch role {
        case .user:      return neon.accent2
        case .assistant: return neon.textDim
        case .system:    return neon.yellow
        case .tool:      return neon.accentBright
        }
    }

    /// Accent-tinted role labels glow; muted ones don't.
    private var roleGlow: NeonTextGlow? {
        switch role {
        case .user, .tool: return neon.textGlow?.tinted(roleColor)
        default:           return nil
        }
    }
}

// MARK: - User bubble + attachments

/// In-memory cache of just-sent attachment bytes, keyed by
/// `sessionID/filename`, so the user's bubble can show a real image
/// thumbnail for what they just sent. Reloaded transcripts (bytes not
/// cached) fall back to a filename chip — fetching upload bytes back from
/// the broker is out of scope.
@MainActor
final class AttachmentBytesCache {
    static let shared = AttachmentBytesCache()
    private var store: [String: Data] = [:]

    private func key(_ sessionID: String, _ filename: String) -> String {
        "\(sessionID)/\(filename)"
    }

    func put(sessionID: String, filename: String, bytes: Data) {
        store[key(sessionID, filename)] = bytes
    }

    func image(sessionID: String, filename: String) -> UIImage? {
        guard let data = store[key(sessionID, filename)] else { return nil }
        return UIImage(data: data)
    }
}

/// User message bubble: renders the prose pill (when any) plus a
/// chip/thumbnail per attachment, with the raw `uploads/…` reference
/// lines stripped from the visible text.
private struct ConduitUserBubble: View {
    let event: ConversationItem
    var sessionID: String = ""
    @Environment(\.neonTheme) private var neon
    @Environment(SessionStore.self) private var store

    /// True while the message is sent-but-not-yet-broker-acked (task K):
    /// `pending` (queued, pre-write) or `sent` (WS write ok, awaiting
    /// chat_ack). Both render faded + dotted; `done` is solid. Reads
    /// `event.status` so a status flip rebuilds the row.
    private var inFlight: Bool {
        let s = event.status.lowercased()
        return s == "pending" || s == "sent"
    }

    var body: some View {
        let parsed = ConduitUI.splitAttachmentReferences(event.content)
        let status = event.status.lowercased()
        let failed = status == "failed"
        // Broker no longer knows this session (restart/redeploy/GC): the send
        // path stopped retrying and marked the echo `expired`. Offer Resume.
        let expired = status == "expired"
        return VStack(alignment: .trailing, spacing: 8) {
            if !parsed.text.isEmpty {
                ConduitBlockStack(
                    blocks: ConversationRenderer.blocks(for: parsed.text),
                    role: .user,
                    itemID: event.id
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Device feedback v0.0.68: fill with primary `accent` (not
                // `accent2`) so `accentText` stays readable in both modes.
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(neon.accent)
                )
                // Task K send-state cue (NO text): a faded bubble with a
                // dotted border while in-flight (sending/awaiting broker ack);
                // solid once the broker acks (status → done). Failed bubbles
                // keep full opacity and surface the retry affordance below.
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            neon.accentText.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .opacity(inFlight ? 1 : 0)
                )
                .opacity(inFlight ? 0.55 : 1)
                .neonGlowBox(neon.glow && !inFlight ? neon.glowBox?.tinted(neon.accent) : nil)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = parsed.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            ForEach(parsed.attachments, id: \.filename) { ref in
                ConduitAttachmentChip(ref: ref)
            }
            if expired {
                sessionExpiredFooter
            } else if failed {
                sendFailedFooter
            }
        }
    }

    /// A "failed — retry" affordance once delivery gives up. The in-flight and
    /// delivered states carry NO text — the bubble's opacity + dotted border
    /// (in `body`) are the only cue. Only the failed terminus keeps a tappable
    /// label so the user can re-arm a give-up. Reads `event.status` so a flip
    /// rebuilds the row (status is part of the row's Equatable digest).
    @ViewBuilder
    private var sendFailedFooter: some View {
        Button {
            store.retryPendingChat(sessionID: sessionID, localID: event.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                Text("failed — tap to retry")
            }
            .font(neon.mono(10).weight(.bold))
            .foregroundStyle(neon.red)
        }
        .buttonStyle(.plain)
    }

    /// The broker forgot this session (restart/redeploy/GC) so the send was
    /// stopped (not retried into a dead session). Surface a clear, tappable
    /// "session expired — Resume to continue" that re-attaches the session via
    /// the existing recoverable-resume flow.
    @ViewBuilder
    private var sessionExpiredFooter: some View {
        Button {
            let assistant = store.sessions.first(where: { $0.id == sessionID })?.assistant ?? "claude"
            store.resumeRecoverableSession(sessionID: sessionID, assistant: assistant)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise.circle")
                Text("session expired — Resume to continue")
            }
            .font(neon.mono(10).weight(.bold))
            .foregroundStyle(neon.red)
        }
        .buttonStyle(.plain)
    }
}

/// A single attachment in a user bubble: an image thumbnail when the
/// bytes are cached from this session's send, else a compact filename
/// chip.
private struct ConduitAttachmentChip: View {
    let ref: ConduitUI.AttachmentRef
    @Environment(\.neonTheme) private var neon

    var body: some View {
        if ref.kind == .image,
           let image = AttachmentBytesCache.shared.image(sessionID: ref.sessionID, filename: ref.filename) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(neon.border, lineWidth: 1)
                )
        } else {
            HStack(spacing: 6) {
                Image(systemName: ref.kind == .image ? "photo" : "doc")
                    .font(.system(size: 12, weight: .semibold))
                Text(ref.filename)
                    .font(neon.sans(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(neon.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(neon.surface))
            .overlay(Capsule().stroke(neon.border, lineWidth: 1))
        }
    }
}

private struct ConduitBlockStack: View {
    let blocks: [ConversationBlock]
    let role: ConduitRole
    let itemID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                switch block {
                case .markdown(let text):
                    // Cache *every* markdown block, not just the first.
                    // Earlier only `idx == 0` carried an itemID, so a
                    // message with an intro + a fenced block + a trailing
                    // paragraph re-parsed the trailing paragraph on every
                    // recycle. Suffix the block index so the blocks share
                    // the item identity but never collide in the cache.
                    ConduitMarkdownBlock(
                        text: text,
                        role: role,
                        itemID: itemID.map { "\($0)#md\(idx)" },
                        streamItemID: idx == 0 ? itemID : nil
                    )
                case .code(let language, let content):
                    ConduitCodeBlock(language: language, content: content)
                case .toolSummary(let label, let detail):
                    ConduitToolSummaryBlock(label: label, detail: detail)
                }
            }
        }
    }
}

private struct ConduitMarkdownBlock: View {
    let text: String
    let role: ConduitRole
    /// Per-block cache key (item id + block index). `nil` for blocks
    /// that shouldn't be cached (e.g. inline cards built from raw text).
    var itemID: String? = nil
    /// Original message id, used only to look up streaming state. Only
    /// the first markdown block of a message streams; later blocks are
    /// stable text once the turn finalises.
    var streamItemID: String? = nil

    @Environment(AppearanceStore.self) private var appearance
    @Environment(StreamingRendererCoordinator.self) private var coordinator

    // Compute-once-into-@State (task #38 / claude-code-ios
    // EnhancedMessageView pattern). Parsing markdown into structured
    // pieces + inline `AttributedString`s is the hot allocator on the
    // chat list; doing it inside `body` re-parsed on every recycle.
    // Instead we parse once in `.task(id:)` and store the result, so a
    // recycled row's `body` renders straight from `@State` with no
    // re-parse. The render key folds content + appearance so the parse
    // re-fires only when something that affects the output changes.
    //
    // BUG 1 fix: a single message body can carry headings, paragraphs,
    // lists AND GFM tables. `AttributedString(markdown:)` interprets
    // *inline* syntax but flattens *block* structure (no inter-block
    // spacing, and tables collapse to concatenated cell text). We now
    // split the body into `ConduitMarkdownPiece`s and render each with
    // its own vertical rhythm — tables become stacked records, headings
    // get weight + space, lists get bullets + indent.
    @State private var pieces: [ConduitMarkdownPiece] = []
    @State private var renderedKey: Int? = nil

    private func revision(for content: String) -> Int {
        // Re-render when the user changes their body-size slider — the
        // rendered runs store absolute font sizes (PR 4 heading scale)
        // so the cache key has to vary with the size.
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(appearance.bodyPointSize)
        hasher.combine(appearance.fontFamily.rawValue)
        return hasher.finalize()
    }

    private var displayedText: String {
        guard let id = streamItemID else { return text }
        switch coordinator.renderState(for: id) {
        case .streaming(let buffer):
            return buffer
        case .idle, .complete:
            return text
        }
    }

    private var isStreaming: Bool {
        guard let id = streamItemID else { return false }
        if case .streaming = coordinator.renderState(for: id) {
            return true
        }
        return false
    }

    /// Identity for the parse `.task`: re-run only when the displayed
    /// text or the appearance-derived revision changes. While streaming
    /// this fires per buffer update (each is a distinct revision); once
    /// the turn settles it stops firing and recycled rows reuse `@State`.
    private var renderKey: Int { revision(for: displayedText) }

    var body: some View {
        ConduitStructuredMarkdownView(
            pieces: visiblePieces,
            role: role,
            basePointSize: appearance.bodyPointSize,
            // Transcript prose renders in the user's chosen Chat font
            // (handoff Part A): System / Space Grotesk / IBM Plex Sans /
            // Newsreader. The renderer resolves the concrete face.
            fontFamily: appearance.fontFamily
        )
        .frame(maxWidth: role == .user ? nil : .infinity, alignment: role == .user ? .trailing : .leading)
        // No per-token layout animation: interpolating piece layout on every
        // streamed token was a major scroll-jank source. Litter rendered
        // streaming text flat and stayed smooth — we match that.
        .animation(nil, value: visiblePieces)
        // Run the EXPENSIVE structured parse (headings/lists/tables) only
        // once the turn settles — never per token. While streaming the id
        // stays nil so this fires once (and no-ops); when the turn ends the
        // id becomes `renderKey` and the full parse runs a single time.
        .task(id: isStreaming ? nil : renderKey) { parseIfSettled() }
        .onAppear { parseIfSettled() }
    }

    /// What actually renders. While streaming, the raw buffer is shown
    /// cheaply as one paragraph (no block parse); once settled, the
    /// structured `pieces` render. Falls back to the raw text until the
    /// settle-parse lands so a just-finished row never flashes empty.
    private var visiblePieces: [ConduitMarkdownPiece] {
        if isStreaming { return [.paragraph(displayedText)] }
        return pieces.isEmpty ? [.paragraph(displayedText)] : pieces
    }

    /// Parse the settled body into structured pieces once. No-op while
    /// streaming (the buffer is rendered raw) and when the key is unchanged
    /// (recycled row already parsed).
    private func parseIfSettled() {
        guard !isStreaming else { return }
        if renderedKey != renderKey {
            pieces = ConduitMarkdownStructure.parse(displayedText)
            renderedKey = renderKey
        }
    }
}

// MARK: - Structured markdown renderer
//
// Renders the typed `ConduitMarkdownPiece`s with explicit vertical
// rhythm: headings get weight + space above/below, paragraphs/list
// items/tables get consistent gaps, lists show bullets/numbers + hang
// indent, and GFM tables render as stacked "header: value" records
// (robust on a narrow phone — never the run-on concatenation the device
// bug reported). Inline markdown (bold / code spans / links) inside each
// piece is interpreted per-segment via `AttributedString(markdown:)`,
// looked up through `MessageRenderCache` so a recycled row doesn't
// re-parse.
private struct ConduitStructuredMarkdownView: View {
    let pieces: [ConduitMarkdownPiece]
    let role: ConduitRole
    let basePointSize: CGFloat
    let fontFamily: AppearanceStore.FontFamily
    @Environment(\.neonTheme) private var neon

    /// Vertical gap between top-level blocks (BUG 1: blocks were bunched
    /// with no rhythm). 10pt reads as a clear paragraph break without
    /// looking double-spaced.
    private let blockSpacing: CGFloat = 10

    /// Prose font for transcript text — the user's selected Chat font.
    /// `FontFamily.font(size:weight:)` resolves the pairing's prose face and
    /// falls back to the system face if a bundled TTF is missing.
    private func proseFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fontFamily.font(size: size, weight: weight)
    }

    /// De-cramp (handoff §1/§7): both chat arms read calmer than today by
    /// lifting prose line-height from ~1.46 toward ~1.7. SwiftUI `lineSpacing`
    /// is added leading on top of the font's intrinsic ~1.2, so ~0.34× the
    /// point size lands the rendered line-height near the 1.7 target.
    private var proseLineSpacing: CGFloat { basePointSize * 0.34 }

    var body: some View {
        VStack(alignment: role == .user ? .trailing : .leading, spacing: blockSpacing) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                pieceView(piece)
                    .frame(maxWidth: role == .user ? nil : .infinity,
                           alignment: role == .user ? .trailing : .leading)
            }
        }
    }

    @ViewBuilder
    private func pieceView(_ piece: ConduitMarkdownPiece) -> some View {
        switch piece {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            inlineText(text)
                .font(proseFont(basePointSize))
                .lineSpacing(proseLineSpacing)
        case .list(let ordered, let items):
            listView(ordered: ordered, items: items)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .code(let language, let content):
            // Streaming-path fenced code (device feedback v0.0.50 #6):
            // render the same styled block the settled message uses, so a
            // mid-stream ``` shows as code rather than raw markers. The
            // turn-end re-render (via `ConversationRenderer.blocks`) lands
            // on the identical view, so there's no raw→pretty flash.
            ConduitCodeBlock(language: language, content: content)
        }
    }

    // MARK: Heading

    private func headingView(level: Int, text: String) -> some View {
        let mult = ConduitMarkdownHeadingScaler.multiplier(forLevel: level) ?? 1.0
        // Extra space above a heading (but not the very first block)
        // keeps headings from jamming into the preceding text. The
        // outer VStack supplies the gap below.
        return inlineText(text)
            .font(proseFont(basePointSize * mult, weight: .semibold))
            .padding(.top, level <= 2 ? 6 : 2)
    }

    // MARK: List

    private func listView(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .font(proseFont(basePointSize))
                        .foregroundStyle(role == .user ? neon.accentText.opacity(0.8) : neon.textDim)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    inlineText(item)
                        .font(proseFont(basePointSize))
                        .lineSpacing(proseLineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Table (stacked records)

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        // Stacked "header: value" records. On a narrow phone a true
        // grid wraps illegibly; stacking each row as a small card of
        // header→value pairs stays readable and never concatenates.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                        let header = col < headers.count ? headers[col] : ""
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !header.isEmpty {
                                Text(header)
                                    .font(proseFont(basePointSize * 0.85, weight: .semibold))
                                    .foregroundStyle(neon.textDim)
                            }
                            inlineText(cell)
                                .font(proseFont(basePointSize))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(neon.surface2)
                )
            }
        }
    }

    // MARK: Inline

    /// Render a single block's text with inline markdown (bold / code
    /// spans / links) interpreted. `interpretedSyntax: .inlineOnly`
    /// keeps block markers (which we've already stripped) from being
    /// re-interpreted, and avoids the block-flattening that caused the
    /// run-on bug. Cached so recycled rows skip the parse.
    private func inlineText(_ raw: String) -> some View {
        let attr = Self.inlineAttributed(raw)
        return Text(attr)
            .foregroundStyle(foregroundForRole)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func inlineAttributed(_ raw: String) -> AttributedString {
        conduitInlineAttributed(raw)
    }

    private var foregroundForRole: Color {
        switch role {
        // §2: user prose sits on the accent pill → accentText for contrast.
        case .user:      return neon.accentText
        case .system:    return neon.textDim
        default:         return neon.text
        }
    }
}

// MARK: - Typing indicator
//
// BUG 3: a lightweight "agent is working" affordance shown at the bottom
// of the message list while any turn is streaming. Shows distinct states:
// three bouncing dots for "writing", a single pulsing dot for "working"
// or "thinking". Falls back to three dots when turnPhase is nil (unknown).
private struct ConduitTypingIndicator: View {
    var turnPhase: String? // "writing" | "working" | "thinking" | nil
    var agent: String = "claude"
    /// Last non-empty thinking line (trimmed, capped 80 chars). When turnPhase
    /// is "thinking" and this is non-nil, it overrides the indicator's canned verb.
    var thinkingPeek: String? = nil
    @State private var phase = 0
    @Environment(\.neonTheme) private var neon

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch turnPhase {
            case "working", "thinking":
                // Pre-output phases: replaced by the new four-style WorkingIndicator.
                // Style driven by the debug toggle (debug.workingIndicatorStyle, default .spine).
                // When phase is "thinking" and we have a live thinking line, pass it as
                // status so ALL styles show the live reasoning line instead of the canned verb.
                ConduitUI.WorkingIndicator(
                    style: ConduitWorkingDebug.current,
                    agent: agent,
                    status: turnPhase == "thinking" ? thinkingPeek : nil
                )
            default:
                // "writing" / nil — three bouncing dots (active streaming, unchanged).
                VStack(alignment: .leading, spacing: 4) {
                    Text("assistant")
                        .font(neon.mono(11).weight(.bold))
                        .foregroundStyle(neon.textDim)
                        .textCase(.uppercase)
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(neon.accent)
                                .frame(width: 7, height: 7)
                                .scaleEffect(phase == i ? 1.0 : 0.6)
                                .opacity(phase == i ? 1.0 : 0.4)
                                .neonGlowBox(phase == i ? neon.glowBox?.tinted(neon.accent) : nil)
                                .animation(.easeInOut(duration: 0.3), value: phase)
                        }
                    }
                }
                .accessibilityLabel("Assistant is typing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Streaming overlay (legacy removed)
//
// ConduitStreamingOverlay has been replaced by ConduitUI.StreamingSpineView
// (Direction C "Flowing conduit" — design handoff streaming_turn/README.md).
// The spine render lives in StreamingSpineView.swift.

private struct ConduitCodeBlock: View {
    let language: String?
    let content: String
    @Environment(\.neonTheme) private var neon

    private var resolvedLanguage: String? { SyntaxLanguage.fromFence(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language, !language.isEmpty {
                // §2: mono-shaped chrome — code language label in mono.
                Text(language.uppercased())
                    .font(neon.mono(10).weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(neon.textDim)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedCodeBlock(language: resolvedLanguage, content: content)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // §2: code renders on the dark neon code surface. Hairline
        // border via the shared card-surface rule (glowBox when on).
        .neonCardSurface(neon, fill: neon.codeBg, cornerRadius: 14)
    }
}

private struct ConduitToolSummaryBlock: View {
    let label: String
    let detail: String
    @State private var expanded = false
    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(neon.textDim)
                    Text(label)
                        .font(neon.sans(13).weight(.medium))
                        .foregroundStyle(neon.textDim)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(detail)
                    .font(neon.mono(12))
                    .foregroundStyle(neon.codeText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Tool card

/// Visual constants for the upstream-faithful tool card surface (PLAN-
/// CONDUIT-VISUAL-PARITY PR 4, audit §A.2.3 / §A.2.8). Extracted so
/// `ConduitToolCardSurfaceTests` can pin the rebuild — without that pin
/// the next "tweak this card" PR could quietly restore the glass +
/// status-tint overlay that the audit called out as too prominent.
enum ConduitToolCardMetrics {
    /// Leading 6pt status dot replaces the previous wrench glyph.
    static let statusDotSize: CGFloat = 6
    /// Outer corner radius — 14pt matches the new flatter card shape
    /// landed in PR 2 (`conduitGlassRoundedRect` default).
    static let surfaceCornerRadius: CGFloat = 14
    /// Surface fill opacity — 0.6 keeps the card legible without the
    /// "card-inside-card" layering the prior glass treatment produced
    /// once a code or diff sub-block landed inside.
    static let surfaceOpacity: Double = 0.6
}

// MARK: - Neon tool/command classification (pure, testable)
//
// Maps a tool name to an SF Symbol + tint role + human label, and
// detects whether a tool call is a shell/exec command (which gets the
// headline CommandCard look, README §4.1) vs a generic tool (the
// compact ToolCard, §4.5). Kept off SwiftUI so `NeonToolCardLogicTests`
// can pin the mapping without a view host.

/// A tint role resolved against the live `NeonTheme` at render time
/// (the theme's colours aren't known at parse time). The view maps the
/// role to a concrete `Color`.
enum NeonToolTint: Equatable {
    case purple, blue, claude, green, accent, red
}

enum NeonToolClassifier {

    /// True when the tool call should render as a shell COMMAND card
    /// (§4.1) — toolName looks like a shell (bash/sh/exec/zsh/shell/
    /// run/command/terminal) OR there's a non-empty `command` present.
    static func isCommand(toolName: String?, command: String?) -> Bool {
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let name = toolName?.lowercased(), !name.isEmpty else { return false }
        let shellNames = ["bash", "sh", "zsh", "shell", "exec", "run", "command", "terminal", "execute"]
        return shellNames.contains { name.contains($0) }
    }

    /// SF Symbol for a tool name (§4.5 icon tile).
    static func icon(forToolName name: String?) -> String {
        switch tintRole(forToolName: name) {
        case .purple: return "magnifyingglass"
        case .blue:   return "doc.text"
        case .claude: return "pencil"
        case .green:  return "terminal"
        case .red:    return "exclamationmark.triangle"
        case .accent: return "wrench.and.screwdriver"
        }
    }

    /// Tint role for a tool name: search→purple, read→blue, edit→claude,
    /// bash/exec→green; otherwise the theme accent.
    static func tintRole(forToolName name: String?) -> NeonToolTint {
        guard let lower = name?.lowercased(), !lower.isEmpty else { return .accent }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find")
            || lower.contains("glob") { return .purple }
        if lower.contains("read") || lower.contains("cat") || lower.contains("view")
            || lower.contains("open") { return .blue }
        if lower.contains("edit") || lower.contains("write") || lower.contains("patch")
            || lower.contains("apply") || lower.contains("create") { return .claude }
        if lower.contains("bash") || lower.contains("sh") || lower.contains("exec")
            || lower.contains("run") || lower.contains("terminal") || lower.contains("command") {
            return .green
        }
        return .accent
    }

    /// Human-readable label for the compact card header (§4.5):
    /// "Searched the codebase", "Read 2 files", etc. Falls back to a
    /// title-cased tool name.
    static func humanLabel(toolName: String?, fileCount: Int) -> String {
        switch tintRole(forToolName: toolName) {
        case .purple: return "Searched the codebase"
        case .blue:
            if fileCount == 1 { return "Read 1 file" }
            if fileCount > 1 { return "Read \(fileCount) files" }
            return "Read files"
        case .claude:
            if fileCount == 1 { return "Edited 1 file" }
            if fileCount > 1 { return "Edited \(fileCount) files" }
            return "Edited files"
        case .green:  return "Ran a command"
        case .red:    return "Tool error"
        case .accent:
            guard let name = toolName, !name.isEmpty else { return "Tool activity" }
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// Parsed `+N −M` counts from a `diffSummary` string (§4.4). Accepts the
/// common shapes the renderer emits — `+12 -3`, `+12/-3`, `12 additions,
/// 3 deletions`, `12 insertions(+), 3 deletions(-)`.
struct NeonDiffStat: Equatable {
    let added: Int?
    let removed: Int?

    static func parse(_ summary: String?) -> NeonDiffStat {
        guard let summary, !summary.isEmpty else { return NeonDiffStat(added: nil, removed: nil) }
        var added: Int?
        var removed: Int?

        // `+N` / `-N` tokens (handles `+12 -3`, `+12/-3`).
        let scanner = summary
        if let r = firstNumber(in: scanner, afterAnyOf: ["+"]) { added = r }
        if let r = firstNumber(in: scanner, afterAnyOf: ["-", "−"]) { removed = r }

        // Word forms: "12 additions", "3 deletions/removals".
        if added == nil { added = numberBefore(["addition", "insertion"], in: scanner) }
        if removed == nil { removed = numberBefore(["deletion", "removal"], in: scanner) }

        return NeonDiffStat(added: added, removed: removed)
    }

    /// First integer immediately following any of `markers` (e.g. "+12").
    private static func firstNumber(in text: String, afterAnyOf markers: [String]) -> Int? {
        let chars = Array(text)
        for marker in markers {
            guard let m = marker.first else { continue }
            var i = 0
            while i < chars.count {
                if chars[i] == m {
                    var j = i + 1
                    var digits = ""
                    while j < chars.count, chars[j].isNumber {
                        digits.append(chars[j]); j += 1
                    }
                    if let n = Int(digits) { return n }
                }
                i += 1
            }
        }
        return nil
    }

    /// Integer that precedes one of `words` (e.g. "12 additions").
    private static func numberBefore(_ words: [String], in text: String) -> Int? {
        let lower = text.lowercased()
        for word in words {
            guard let range = lower.range(of: word) else { continue }
            let prefix = lower[lower.startIndex..<range.lowerBound]
            let trailingDigits = prefix.reversed().prefix { $0.isNumber || $0 == " " }
            let digits = String(trailingDigits).reversed().filter { $0.isNumber }
            if let n = Int(String(digits)) { return n }
        }
        return nil
    }
}

extension NeonTheme {
    /// Resolve a `NeonToolTint` role to a concrete colour from the theme.
    func color(for tint: NeonToolTint) -> Color {
        switch tint {
        case .purple: return purple
        case .blue:   return blue
        case .claude: return claude
        case .green:  return green
        case .accent: return accent
        case .red:    return red
        }
    }
}

// MARK: - Keyboard animation duration guard (testable)

/// Pure-data guard extracted so unit tests can exercise it without a
/// `Notification` / SwiftUI host. iOS can re-fire `keyboardWillShow` as a
/// no-op (observed back-to-back in Sentry breadcrumbs during the foreground
/// reconcile refresh) with `UIKeyboardAnimationDurationUserInfoKey == 0`.
/// `.spring(response: 0, ...)` divides by `response` internally, so a 0 (or
/// otherwise non-finite/negative) duration produced a NaN spring stiffness
/// -> a NaN-origin CALayer bounds on the animated scroll view -> the fatal
/// `CALayerInvalidGeometry` crash. Clamp to the same 0.25 fallback used
/// elsewhere when the userInfo key is absent entirely.
enum KeyboardAnimationLogic {
    static let fallbackDuration: Double = 0.25

    static func sanitizedDuration(_ raw: Double) -> Double {
        (raw.isFinite && raw > 0) ? raw : fallbackDuration
    }
}

// MARK: - Tool bundle card (round-3 §1)

// MARK: - §10 pure logic helpers (testable)

/// Pure-data helpers extracted so unit tests can exercise the
/// collapse-threshold, failed-row surfacing, and ticker-fraction logic
/// without a SwiftUI host. Internal (not private) so `@testable import`
/// reaches them from ConduitTests.
enum CommandRunBlockLogic {

    /// Runs of this size or fewer render as the always-expanded inline block.
    /// Runs of (threshold + 1) or more collapse into the ledger block (§10b).
    /// 1-9 -> inline; >= 10 -> collapse.
    static let collapseThreshold = 9

    /// True when the run is large enough to use the collapse ledger (§10b).
    static func shouldCollapse(count: Int) -> Bool { count > collapseThreshold }

    /// The failed items from a run (status == fail or exitCode != 0).
    static func failedItems(from items: [ConversationItem]) -> [ConversationItem] {
        items.filter { NeonCardState(status: $0.status, exitCode: $0.exitCode) == .fail }
    }

    /// Progress fraction for the running ticker: completed / total.
    /// Returns 0 when total is 0 (unknown), clamped to [0,1].
    static func tickerFraction(completedCount: Int, totalCount: Int) -> Double {
        guard totalCount > 0 else { return 0 }
        return min(Double(completedCount) / Double(totalCount), 1.0)
    }
}

/// The failure tint the round-3 design assigns to bundles containing a
/// non-zero exit (`#FF7847`) — warmer than `neon.red` so a failed sweep
/// reads as "needs a look", not "crash".
private enum ConduitBundleTint {
    static let fail = Color(hex: "#ff7847")
}

/// A consecutive run of tool calls collapsed into ONE quiet row: icon,
/// a human verb ("Explored the codebase"), a mono kind sub-line
/// ("grep · find · 12 more"), and an aggregate status pill ("14 runs" /
/// "1 failed"). Tap to expand → every call is a single line; tap a line
/// to focus it → only then its output + actions appear. A non-zero exit
/// auto-expands the bundle, tints it orange, and floats the failing
/// rows up — failures never hide inside a collapsed bundle.
private struct ConduitToolBundleCard: View {
    let items: [ConversationItem]
    var sessionID: String

    // Derived ONCE at init (perf, post-v0.0.116): these were computed
    // properties, so every body render re-ran `kindWord` —
    // `extractCommand` string-scans included — over the whole run,
    // three times over (dominant kind, verb, subline). A 20-item
    // bundle cost ~40 extract calls per frame while scrolling. The
    // struct re-inits only when the parent's (memoized) rows change,
    // so stored lets make the header render O(1).
    private let displayItems: [ConversationItem]
    private let failCount: Int
    private let anyRunning: Bool
    private let dominantRole: NeonToolTint
    private let iconName: String
    private let verb: String
    private let subline: String

    @State private var expanded: Bool
    @State private var focusedID: String?
    /// Per-message expand state for the ToolLedger (arm B). Starts collapsed (footnote)
    /// once anyRunning is false; failures auto-expand.
    @State private var ledgerExpanded: Bool
    @Environment(\.neonTheme) private var neon
    /// chat-shell-v2 arm (§2). Arm B drops the grouped card and renders each
    /// tool as a recessive one-line spine row.
    @Environment(\.chatArm) private var arm
    /// When false (the default), render the compact footnote instead of the
    /// full card surface. Injected from the chat shell.
    @Environment(\.commandDetailEnabled) private var commandDetailEnabled
    /// When true, render the §10/§10b Mono block instead. Gated off by default.
    @Environment(\.commandRunBlockEnabled) private var commandRunBlockEnabled

    init(items: [ConversationItem], sessionID: String = "") {
        self.items = items
        self.sessionID = sessionID

        // One pass over the run: kind words, failure split, running flag.
        var kindWords: [String] = []
        kindWords.reserveCapacity(items.count)
        var fails: [ConversationItem] = []
        var rest: [ConversationItem] = []
        var running = false
        for item in items {
            kindWords.append(Self.kindWord(for: item))
            switch NeonCardState(status: item.status, exitCode: item.exitCode) {
            case .fail:    fails.append(item)
            case .running: running = true; rest.append(item)
            default:       rest.append(item)
            }
        }
        // Failing rows float to the top so their output is the first
        // thing visible; otherwise chronological.
        self.displayItems = fails.isEmpty ? items : fails + rest
        self.failCount = fails.count
        self.anyRunning = running

        // Most frequent kind drives icon + tint; mixed roles read as
        // exploration.
        var counts: [String: Int] = [:]
        for word in kindWords { counts[word, default: 0] += 1 }
        let dominant = counts.max { $0.value < $1.value }?.key
        self.dominantRole = NeonToolClassifier.tintRole(forToolName: dominant)
        self.iconName = NeonToolClassifier.icon(forToolName: dominant)
        let roles = Set(kindWords.map { NeonToolClassifier.tintRole(forToolName: $0) })
        if roles.count > 1 {
            self.verb = "Explored the codebase"
        } else {
            switch roles.first ?? .accent {
            case .purple: self.verb = "Explored the codebase"
            case .blue:   self.verb = "Read files"
            case .claude: self.verb = "Edited files"
            case .green:  self.verb = "Ran commands"
            case .red:    self.verb = "Tool errors"
            case .accent: self.verb = "Used tools"
            }
        }
        // "grep · find · 12 more" — first two distinct kinds + remainder.
        var seen: [String] = []
        for word in kindWords where !seen.contains(word) {
            seen.append(word)
            if seen.count == 2 { break }
        }
        if items.count > 2 { seen.append("\(items.count - 2) more") }
        self.subline = seen.joined(separator: " · ")

        // Failures auto-surface: open expanded with the first failing
        // row focused. (The row identity includes the item count, so a
        // failure that lands mid-stream re-creates the card and this
        // initial state re-evaluates.)
        _expanded = State(initialValue: !fails.isEmpty)
        _focusedID = State(initialValue: fails.first?.id)
        // ToolLedger (arm B): starts collapsed unless there are failures.
        _ledgerExpanded = State(initialValue: !fails.isEmpty)
    }

    private var tint: Color {
        failCount > 0 ? ConduitBundleTint.fail : neon.color(for: dominantRole)
    }

    /// Short mono word for one item — the command's first token
    /// (`grep`, `find`) or the tool name.
    private static func kindWord(for item: ConversationItem) -> String {
        if let cmd = ConversationRenderer.extractCommand(from: item),
           let first = cmd.split(separator: " ").first, !first.isEmpty {
            // Strip a path prefix so "/usr/bin/grep" reads "grep".
            return String(first.split(separator: "/").last ?? first)
        }
        return (item.toolName ?? "tool").lowercased()
    }

    var body: some View {
        if arm == .b {
            // Arm B (Signature/spine — the permanent default for all non-staff):
            // always render the new typed-step ToolLedger regardless of other flags.
            ToolLedger(
                items: items,
                anyRunning: anyRunning,
                failCount: failCount,
                isExpanded: $ledgerExpanded
            )
        } else if commandRunBlockEnabled {
            monoBlockBody
        } else if !commandDetailEnabled {
            compactBody
        } else {
            breatheBody
        }
    }

    /// Compact mode (showCommandDetail OFF): a single muted footnote line
    /// with a chevron. No border, no card surface. Tapping toggles expanded
    /// to reveal the full ConduitSpineToolRow items. Failures auto-expand
    /// and use fail tint (failures never hide).
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(failCount > 0 ? ConduitBundleTint.fail : neon.textFaint)
                Text(compactLabelText)
                    .font(neon.mono(11.5))
                    .foregroundStyle(failCount > 0 ? ConduitBundleTint.fail : neon.textFaint)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(compactLabelText)
            .accessibilityAddTraits(.isButton)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(displayItems, id: \.id) { item in
                        ConduitSpineToolRow(event: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactLabelText: String {
        let n = items.count
        let word = n == 1 ? "command" : "commands"
        if anyRunning { return "running \(n) \(word)..." }
        if failCount > 0 { return "ran \(n) \(word) \u{00B7} \(failCount) failed" }
        return "ran \(n) \(word)"
    }

    /// Signature arm: collapsible cluster that defaults collapsed.
    /// The header summarises the run ("N commands · all exit 0" / "M failed");
    /// when expanded it renders quiet ConduitSpineToolRow items — preserving the
    /// recessive Signature aesthetic — rather than the louder Breathe bundle rows.
    private var signatureBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            signatureHeader
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(displayItems, id: \.id) { item in
                        ConduitSpineToolRow(event: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                .fill(neon.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                        .stroke(
                            failCount > 0 ? ConduitBundleTint.fail.opacity(0.40) : neon.border.opacity(0.50),
                            lineWidth: 1
                        )
                )
        )
    }

    private var signatureHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: failCount > 0 ? "exclamationmark.triangle" : iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(failCount > 0 ? ConduitBundleTint.fail : tint.opacity(0.80))
            Text(signatureHeaderText)
                .font(neon.mono(11.5))
                .foregroundStyle(failCount > 0 ? ConduitBundleTint.fail : neon.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(neon.textFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(verb), \(items.count) tool runs\(failCount > 0 ? ", \(failCount) failed" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private var signatureHeaderText: String {
        let n = items.count
        let countWord = n == 1 ? "1 command" : "\(n) commands"
        if anyRunning { return "\(countWord) · running" }
        if failCount > 0 { return "\(countWord) · \(failCount) failed" }
        return "\(countWord) · all exit 0"
    }

    @ViewBuilder
    private var breatheBody: some View {
        if !expanded {
            // Collapsed: same compact footnote as flag-off state. Tap → full card.
            compactBody
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(displayItems, id: \.id) { item in
                        ConduitBundleRow(
                            item: item,
                            sessionID: sessionID,
                            focused: focusedID == item.id,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    focusedID = focusedID == item.id ? nil : item.id
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: neon.surface,
                cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius,
                border: failCount > 0 ? ConduitBundleTint.fail.opacity(0.55) : nil,
                glowTint: failCount > 0 ? ConduitBundleTint.fail : nil
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: failCount > 0 ? "exclamationmark.triangle" : iconName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(verb)
                    .font(neon.sans(13.5).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                Text(subline)
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusPill
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(neon.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        // ≥44pt row height + full-width hit area (round-3 §4).
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(verb), \(items.count) tool runs\(failCount > 0 ? ", \(failCount) failed" : "")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var statusPill: some View {
        if failCount > 0 {
            pill("\(failCount) failed", color: ConduitBundleTint.fail)
        } else if anyRunning {
            pill("running", color: neon.accent2)
        } else {
            pill(items.count == 1 ? "1 run" : "\(items.count) runs", color: neon.green)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(neon.mono(10.5).weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }

    // MARK: - §10 Mono block (commandRunBlock flag)

    /// §10 entry point.
    /// While running -> Option-C inline ticker.
    /// Small settled runs (≤ threshold) -> always-expanded inline block (§10 B).
    /// Large settled runs (> threshold) -> collapsible ledger block (§10b).
    @ViewBuilder
    private var monoBlockBody: some View {
        if anyRunning {
            MonoRunningTicker(items: items)
        } else if !CommandRunBlockLogic.shouldCollapse(count: items.count) {
            MonoInlineBlock(items: items, failCount: failCount)
        } else {
            MonoCollapseBlock(items: items, displayItems: displayItems, failCount: failCount)
        }
    }
}

// MARK: - §10 Mono block views (commandRunBlock flag)

// ---------------------------------------------------------------------------
// MonoCommandRow — one row in the settled or expanded ledger.
// $ command (tail-truncated) + trailing check or red exit code.
// Failed rows expand their stderr tail inline beneath.
// ---------------------------------------------------------------------------
private struct MonoCommandRow: View {
    let item: ConversationItem
    /// Row number for the expanded ledger (nil = normal settled block).
    var rowNumber: Int? = nil
    /// Whether to show per-row duration (ledger mode).
    var showDuration: Bool = false

    @Environment(\.neonTheme) private var neon

    private var state: NeonCardState {
        NeonCardState(status: item.status, exitCode: item.exitCode)
    }
    private var command: String {
        ConversationRenderer.extractCommand(from: item)
            ?? NeonToolClassifier.humanLabel(toolName: item.toolName, fileCount: item.files.count)
    }
    private var isFailed: Bool { state == .fail }
    private var stderrTail: String {
        // Use content as stderr output (same as ConduitSpineToolRow).
        let raw = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        // Surface last ~3 lines as the tail.
        let lines = raw.components(separatedBy: "\n")
        let tail = lines.suffix(3).joined(separator: "\n")
        return tail
    }
    private var durationText: String? {
        guard showDuration, let ms = item.durationMs, ms > 0 else { return nil }
        if ms < 1000 { return "\(ms)ms" }
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                if let n = rowNumber {
                    Text(String(format: "%2d.", n))
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(neon.textFaint)
                        .frame(width: 28, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                Text("$")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(neon.textFaint)
                    .padding(.trailing, 6)
                Text(command)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let dur = durationText {
                    Text(dur)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(neon.textFaint)
                        .padding(.trailing, 6)
                }
                if let code = item.exitCode, code != 0 {
                    Text("\(code)")
                        .font(.system(size: 10.5, weight: .medium).monospaced())
                        .foregroundStyle(neon.red)
                } else if !isFailed {
                    Text("\u{2713}")
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(neon.textFaint)
                }
            }
            .padding(.vertical, 3)
            // Failures expand stderr tail inline, always visible.
            if isFailed, !stderrTail.isEmpty {
                Text(stderrTail)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(neon.codeText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(neon.codeBg.opacity(0.6))
                    )
                    .textSelection(.enabled)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MonoInlineBlock — §10 always-expanded flat mono block (B · Mono block).
// Used for small runs (≤ monoCollapseThreshold).
// Header: "run  N commands  exit 0 / N failed". Rows: MonoCommandRow.
// ---------------------------------------------------------------------------
private struct MonoInlineBlock: View {
    let items: [ConversationItem]
    let failCount: Int

    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("run")
                    .font(.system(size: 10, weight: .bold).monospaced())
                    .foregroundStyle(neon.textFaint)
                    .kerning(1.2)
                Text("  \(items.count) command\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(neon.textFaint)
                Spacer(minLength: 8)
                if failCount > 0 {
                    Text("\(failCount) failed")
                        .font(.system(size: 10, weight: .semibold).monospaced())
                        .foregroundStyle(neon.red)
                } else {
                    Text("\u{2713}")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(neon.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider().background(neon.border)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    MonoCommandRow(item: item)
                    if idx < items.count - 1 {
                        Divider().background(neon.border)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                .fill(neon.codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                        .stroke(neon.border, lineWidth: 0.5)
                )
        )
        .onAppear {
            Telemetry.breadcrumb("chat", "mono-block render", data: [
                "count": "\(items.count)",
                "failCount": "\(failCount)",
                "collapsed": "false",
            ])
        }
    }
}

// ---------------------------------------------------------------------------
// MonoCollapseBlock — §10b collapsible block (runs > monoCollapseThreshold).
// Collapsed: one-line summary. On failure: failed rows inline + footer.
// Expand: height-capped scrollable ledger with All/Failed filter.
// ---------------------------------------------------------------------------
private struct MonoCollapseBlock: View {
    let items: [ConversationItem]
    let displayItems: [ConversationItem]
    let failCount: Int

    @State private var expanded = false
    @State private var filterFailed = false

    @Environment(\.neonTheme) private var neon

    private var failedItems: [ConversationItem] {
        CommandRunBlockLogic.failedItems(from: items)
    }
    private var totalDurationText: String {
        let totalMs = items.compactMap { $0.durationMs }.reduce(0, +)
        guard totalMs > 0 else { return "" }
        let s = totalMs / 1000
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapseHeader
            if expanded {
                Divider().background(neon.border)
                expandedLedger
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if failCount > 0 {
                // Stay collapsed but show failed rows inline.
                Divider().background(neon.border)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(failedItems, id: \.id) { item in
                        MonoCommandRow(item: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                // Footer: K ran clean -- show all
                HStack(spacing: 4) {
                    Text("\(items.count - failCount) ran clean")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(neon.textFaint)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expanded = true
                            Telemetry.breadcrumb("chat", "mono-block ledger expand", data: [
                                "count": "\(items.count)", "failCount": "\(failCount)",
                            ])
                        }
                    } label: {
                        Text("show all \u{203A}")
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(neon.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                .fill(neon.codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, style: .continuous)
                        .stroke(neon.border, lineWidth: 0.5)
                )
        )
        .onAppear {
            Telemetry.breadcrumb("chat", "mono-block render", data: [
                "count": "\(items.count)",
                "failCount": "\(failCount)",
                "collapsed": "\(!expanded)",
            ])
        }
    }

    private var collapseHeader: some View {
        HStack(spacing: 0) {
            Text("\(items.count) commands")
                .font(.system(size: 10, weight: .medium).monospaced())
                .foregroundStyle(neon.textFaint)
            let dur = totalDurationText
            if !dur.isEmpty {
                Text(" \u{00B7} \(dur)")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(neon.textFaint)
            }
            Text(" \u{00B7} ")
                .font(.system(size: 10).monospaced())
                .foregroundStyle(neon.textFaint)
            if failCount > 0 {
                Text("\(failCount) failed")
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundStyle(neon.red)
            } else {
                Text("\u{2713} passed")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(neon.textFaint)
            }
            Spacer(minLength: 8)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(neon.textFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded.toggle()
                if expanded {
                    Telemetry.breadcrumb("chat", "mono-block ledger expand", data: [
                        "count": "\(items.count)", "failCount": "\(failCount)",
                    ])
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(items.count) commands\(failCount > 0 ? ", \(failCount) failed" : ", all passed")")
        .accessibilityAddTraits(.isButton)
    }

    private var expandedLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            // All / Failed filter
            if failCount > 0 {
                HStack(spacing: 0) {
                    filterButton("All", selected: !filterFailed) {
                        filterFailed = false
                        Telemetry.breadcrumb("chat", "mono-block filter", data: ["filter": "all"])
                    }
                    Text("  /  ")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(neon.textFaint)
                    filterButton("Failed", selected: filterFailed) {
                        filterFailed = true
                        Telemetry.breadcrumb("chat", "mono-block filter", data: ["filter": "failed"])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            let ledgerItems: [ConversationItem] = filterFailed ? failedItems : items
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ledgerItems.enumerated()), id: \.element.id) { idx, item in
                        MonoCommandRow(item: item, rowNumber: idx + 1, showDuration: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 264)
        }
    }

    private func filterButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular).monospaced())
                .foregroundStyle(selected ? neon.codeText : neon.textFaint)
        }
        .buttonStyle(.plain)
    }
}

// ---------------------------------------------------------------------------
// MonoRunningTicker — §10b Option C, while anyRunning.
// Minimal inline: pulse dot + RUNNING + elapsed + count/total,
// then $ <live command> (tail-truncated), and a determinate progress rule.
// ---------------------------------------------------------------------------
private struct MonoRunningTicker: View {
    let items: [ConversationItem]

    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var sheen: Bool = false
    // FIX 2: Task-based sheen so the loop can be cancelled on disappear.
    @State private var sheenTask: Task<Void, Never>? = nil
    @Environment(\.neonTheme) private var neon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completedCount: Int {
        items.filter { item in
            let s = NeonCardState(status: item.status, exitCode: item.exitCode)
            return s == .ok || s == .fail
        }.count
    }

    private var totalCount: Int { items.count }

    private var progressFraction: Double {
        CommandRunBlockLogic.tickerFraction(completedCount: completedCount, totalCount: totalCount)
    }

    private var liveCommand: String {
        // The last item that is still running, or the last item overall.
        let running = items.last { NeonCardState(status: $0.status, exitCode: $0.exitCode) == .running }
        let item = running ?? items.last
        guard let item else { return "" }
        return ConversationRenderer.extractCommand(from: item)
            ?? NeonToolClassifier.humanLabel(toolName: item.toolName, fileCount: item.files.count)
    }

    private var elapsedText: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Pulse dot (static when reduceMotion).
                Circle()
                    .fill(neon.accent2)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 1.0 : 1.0)   // animation placeholder
                Text("RUNNING")
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(neon.accent2)
                Spacer(minLength: 4)
                Text(elapsedText)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(neon.textFaint)
                Text("\(completedCount) / \(totalCount)")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(neon.textFaint)
            }
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(neon.textFaint)
                Text(liveCommand)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Determinate progress rule with sheen sweep.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(neon.border)
                        .frame(height: 1.5)
                    Rectangle()
                        .fill(neon.accent2)
                        .frame(width: geo.size.width * progressFraction, height: 1.5)
                        .overlay(
                            // Sheen sweep: a narrow gradient that slides left-to-right
                            // over the filled portion of the bar. Skipped when the
                            // system has reduced-motion enabled.
                            Group {
                                if !reduceMotion {
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            neon.accent2.opacity(0.7),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: geo.size.width * 0.35)
                                    // offset: -1.0 = fully left of bar, 1.5 = fully right
                                    .offset(x: (sheen ? 1.5 : -1.0) * geo.size.width)
                                }
                            }
                        )
                        .clipped()
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            Telemetry.breadcrumb("chat", "mono-ticker start", data: [
                "total": "\(totalCount)",
                "completed": "\(completedCount)",
            ])
            let earliest = items.compactMap { item -> Double? in
                let ep = conduitConversationTsEpoch(item.ts)
                return ep < .greatestFiniteMagnitude ? ep : nil
            }.min()
            elapsedSeconds = earliest.map { max(0, Int(Date().timeIntervalSince1970 - $0)) } ?? 0
            timerTask?.cancel()
            timerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled {
                        elapsedSeconds += 1
                    }
                }
            }
            // FIX 2: Task-based sheen loop so it can be cancelled on disappear.
            // Replaces withAnimation(.repeatForever) which continued running as a
            // Core Animation layer animation even after the view left the hierarchy.
            sheenTask?.cancel()
            if !reduceMotion {
                sheenTask = Task { @MainActor in
                    while !Task.isCancelled {
                        sheen = false
                        withAnimation(.linear(duration: 1.5)) { sheen = true }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
            // FIX 2: cancel sheen Task so the loop stops when the view leaves
            // the hierarchy (session switch, scroll-off). The repeatForever CA
            // animation it replaced ran indefinitely after view removal.
            sheenTask?.cancel()
            sheenTask = nil
            Telemetry.breadcrumb("chat", "mono-ticker stop", data: [
                "elapsed": "\(elapsedSeconds)",
                "completed": "\(completedCount)",
                "total": "\(totalCount)",
            ])
        }
    }
}

/// One call inside an expanded bundle: a single mono line (`$ cmd …` or
/// `toolname · file`), a pass/fail dot, and a chevron. Tapping focuses
/// the row — only then its output (clipped short) and the Copy /
/// Re-run / Open-in-terminal actions appear, scoped to this row.
private struct ConduitBundleRow: View {
    let item: ConversationItem
    var sessionID: String
    let focused: Bool
    let onTap: () -> Void

    // Derived once at init (perf, post-v0.0.116): `command`/`line` were
    // computed properties calling `extractCommand` (a content string
    // scan for PTY-scraped items) on every render of every visible row.
    private let state: NeonCardState
    private let command: String?
    private let line: String

    @Environment(\.neonTheme) private var neon
    @Environment(SessionStore.self) private var store
    @Environment(\.openTerminalAction) private var openTerminalAction

    init(item: ConversationItem, sessionID: String, focused: Bool, onTap: @escaping () -> Void) {
        self.item = item
        self.sessionID = sessionID
        self.focused = focused
        self.onTap = onTap
        self.state = NeonCardState(status: item.status, exitCode: item.exitCode)
        let command = ConversationRenderer.extractCommand(from: item)
        self.command = command
        // The single-line body: `$ cmd` for commands, `tool · file` else.
        if let command {
            self.line = command
        } else {
            let label = (item.toolName ?? "tool").lowercased()
            if let file = item.files.first {
                let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
                self.line = "\(label) · \(name)"
            } else {
                self.line = label
            }
        }
    }

    /// Output sections stay lazy — only the focused row pays for them.
    private var sections: [ToolSection] { ConversationRenderer.toolSections(for: item) }

    private var dotColor: Color {
        switch state {
        case .ok:               return neon.green
        case .fail:             return ConduitBundleTint.fail
        case .running, .pending: return neon.accent2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("$")
                    .font(neon.mono(12).weight(.bold))
                    .foregroundStyle(command != nil ? dotColor : neon.textFaint)
                Text(line)
                    .font(neon.mono(12))
                    .foregroundStyle(state == .fail ? ConduitBundleTint.fail : neon.codeText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Image(systemName: focused ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(neon.textFaint)
            }
            .padding(.horizontal, 8)
            // ≥44pt tappable row, single-line visual (round-3 §4).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(line), \(state == .fail ? "failed" : "ok")")
            .accessibilityAddTraits(.isButton)

            if focused {
                focusedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(focused ? neon.codeBg : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focused ? (state == .fail ? ConduitBundleTint.fail.opacity(0.45) : neon.border) : Color.clear,
                        lineWidth: 1)
        )
    }

    // Output (clipped to a few lines) + per-row actions.
    private var focusedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 96, alignment: .topLeading)
            .clipped()
            if let meta = metaLine {
                Text(meta)
                    .font(neon.mono(10.5))
                    .foregroundStyle(state == .fail ? ConduitBundleTint.fail : neon.textFaint)
            }
            actionRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let code = item.exitCode, code != 0 { parts.append("exit \(code)") }
        if let duration = ConversationRenderer.extractMetadata(from: item).duration,
           !duration.isEmpty { parts.append(duration) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func sectionView(_ section: ToolSection) -> some View {
        switch section {
        case .stdout(let text), .text(let text):
            outputText(text, color: neon.codeText)
        case .stderr(let text):
            outputText(text, color: ConduitBundleTint.fail)
        case .code(let language, let content):
            ConduitCodeBlock(language: language, content: content)
        case .diff(let diff):
            ConduitDiffBlock(content: diff, diffSummary: item.diffSummary)
        case .files(let files):
            ConduitFileStrip(files: files)
        case .meta, .command:
            EmptyView()  // command is the row line; meta is the meta line
        }
    }

    private func outputText(_ text: String, color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(neon.mono(11))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Copy · Re-run · Open in terminal — scoped to the focused row.
    // Re-run / terminal only make sense for shell commands.
    private var actionRow: some View {
        HStack(spacing: 8) {
            rowAction("Copy", icon: "doc.on.doc") {
                UIPasteboard.general.string = command ?? item.content
            }
            if let command {
                rowAction("Re-run", icon: "arrow.clockwise", disabled: sessionID.isEmpty) {
                    guard !sessionID.isEmpty else { return }
                    store.sendChat(sessionID: sessionID, message: command)
                }
                rowAction("Open in terminal", icon: "terminal", disabled: openTerminalAction == nil) {
                    openTerminalAction?()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func rowAction(
        _ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(neon.mono(11).weight(.medium))
            }
            .foregroundStyle(neon.textDim)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(neon.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

private struct ConduitToolCard: View {
    let event: ConversationItem
    var sessionID: String = ""
    /// When true (Settings → Collapse Turns), the headline command card
    /// opens collapsed instead of expanded. The compact tool row already
    /// opens collapsed regardless (device feedback v0.0.47 #2).
    var collapseDefault: Bool = false
    /// chat-shell-v2 arm (§2). Arm B recedes tool calls to quiet one-line
    /// rows instead of glowing cards.
    @Environment(\.chatArm) private var arm

    var body: some View {
        if arm == .b {
            ConduitSpineToolRow(event: event)
        } else if NeonToolClassifier.isCommand(toolName: event.toolName, command: ConversationRenderer.extractCommand(from: event)) {
            // §4.1 vs §4.5: shell/exec calls (or anything carrying a
            // command) get the headline CommandCard; everything else gets
            // the compact neon tool row.
            ConduitNeonCommandCard(event: event, sessionID: sessionID, collapseDefault: collapseDefault)
        } else {
            ConduitNeonToolCard(event: event)
        }
    }
}

// MARK: - Signature arm — recessive tool row (§2, `03-chat`)
//
// Arm B "Signature" lets tool output recede: a quiet one-line row
// (`⌁ git status --porcelain=… exit 0 ›`) instead of a glowing card. The
// leading bolt is tinted by run state (running/ok/fail); tapping expands
// the raw output inline. Mono throughout — this is the machine talking.
private struct ConduitSpineToolRow: View {
    let event: ConversationItem
    @State private var expanded = false
    @Environment(\.neonTheme) private var neon

    private var state: NeonCardState { NeonCardState(status: event.status, exitCode: event.exitCode) }
    private var summary: String {
        ConversationRenderer.extractCommand(from: event)
            ?? NeonToolClassifier.humanLabel(toolName: event.toolName, fileCount: event.files.count)
    }
    private var detail: String {
        event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text("\u{2301}")   // ⌁ daemon bolt
                        .font(neon.mono(12).weight(.bold))
                        .foregroundStyle(state.color(neon))
                    Text(summary)
                        .font(neon.mono(12))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let code = event.exitCode {
                        Text("exit \(code)")
                            .font(neon.mono(10.5))
                            .foregroundStyle(code == 0 ? neon.textFaint : neon.red)
                    }
                    if !detail.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detail.isEmpty)

            if expanded, !detail.isEmpty {
                Text(detail)
                    .font(neon.mono(11.5))
                    .foregroundStyle(neon.codeText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(neon.codeBg)
                    )
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Neon status helpers (shared by tool / command cards)

/// One of the four card states the design distinguishes (§4.5).
enum NeonCardState: Equatable {
    case running, ok, fail, pending

    init(status: String, exitCode: Int32?) {
        let s = status.lowercased()
        if s == "running" || s == "streaming" || s == "working" { self = .running; return }
        if s == "pending" || s == "thinking" { self = .pending; return }
        if s == "failed" || s == "error" { self = .fail; return }
        if let code = exitCode, code != 0 { self = .fail; return }
        self = .ok
    }

    func color(_ neon: NeonTheme) -> Color {
        switch self {
        case .running: return neon.accent2
        case .ok:      return neon.green
        case .fail:    return neon.red
        case .pending: return neon.claude
        }
    }
}

// MARK: - Compact tool card (§4.5)

private struct ConduitNeonToolCard: View {
    let event: ConversationItem
    // Device feedback v0.0.47 #2: tool/bash cards open COLLAPSED.
    @State private var expanded = false
    @Environment(\.neonTheme) private var neon

    private var sections: [ToolSection] { ConversationRenderer.toolSections(for: event) }
    private var state: NeonCardState { NeonCardState(status: event.status, exitCode: event.exitCode) }
    private var tint: Color { neon.color(for: NeonToolClassifier.tintRole(forToolName: event.toolName)) }
    private var label: String {
        NeonToolClassifier.humanLabel(toolName: event.toolName, fileCount: event.files.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // 22pt tinted icon tile.
                Image(systemName: NeonToolClassifier.icon(forToolName: event.toolName))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint.opacity(0.16))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        // mono meta + duration (green/red).
                        if let duration = ConversationRenderer.extractMetadata(from: event).duration,
                           !duration.isEmpty {
                            Text(duration)
                                .font(neon.mono(10.5))
                                .foregroundStyle(state == .fail ? neon.red : neon.green)
                        }
                        if let code = event.exitCode {
                            Text("exit \(code)")
                                .font(neon.mono(10.5))
                                .foregroundStyle(code == 0 ? neon.green : neon.red)
                        }
                    }
                }
                Spacer(minLength: 0)
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(neon.textDim)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: ConduitToolCardMetrics.surfaceCornerRadius, glowTint: tint)
    }

    @ViewBuilder
    private func sectionView(_ section: ToolSection) -> some View {
        switch section {
        case .meta(let meta):           ConduitToolMetaBlock(meta: meta)
        case .command(let command):     ConduitCommandBlock(command: command)
        case .files(let files):         ConduitFileStrip(files: files)
        case .stdout(let text):         ConduitLabeledOutputBlock(title: "STDOUT", text: text)
        case .stderr(let text):         ConduitLabeledOutputBlock(title: "STDERR", text: text)
        case .text(let text):           ConduitMarkdownBlock(text: text, role: .tool)
        case .code(let language, let content): ConduitCodeBlock(language: language, content: content)
        case .diff(let diff):           ConduitDiffBlock(content: diff, diffSummary: event.diffSummary)
        }
    }
}

// MARK: - Command card (§4.1 — the headline)

/// Switches the enclosing session to its Terminal tab. Set by
/// `ProjectView` on the live tabbed chat; nil in read-only / tablet
/// chat-only panes (no sibling Terminal tab), which disables the command
/// card's "Open in terminal" action.
private struct OpenTerminalActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openTerminalAction: (() -> Void)? {
        get { self[OpenTerminalActionKey.self] }
        set { self[OpenTerminalActionKey.self] = newValue }
    }
}

private struct ConduitNeonCommandCard: View {
    let event: ConversationItem
    var sessionID: String
    @State private var expanded: Bool
    @State private var blink = false
    @Environment(\.neonTheme) private var neon
    @Environment(SessionStore.self) private var store
    @Environment(\.openTerminalAction) private var openTerminalAction

    init(event: ConversationItem, sessionID: String = "", collapseDefault: Bool = false) {
        self.event = event
        self.sessionID = sessionID
        // "Collapse Turns" (Settings) starts command cards collapsed;
        // otherwise they open expanded as before. A non-zero exit always
        // opens expanded — failures never hide (round-3 §1).
        let failed = NeonCardState(status: event.status, exitCode: event.exitCode) == .fail
        _expanded = State(initialValue: !collapseDefault || failed)
    }

    private var state: NeonCardState { NeonCardState(status: event.status, exitCode: event.exitCode) }
    private var command: String { ConversationRenderer.extractCommand(from: event) ?? event.content }
    private var sections: [ToolSection] { ConversationRenderer.toolSections(for: event) }
    /// Sections that actually draw something in the collapsible body. `.meta`
    /// and `.command` are already rendered in the header / meta strip, so a
    /// command with no captured output would otherwise expand into an empty body
    /// — a dead gap above the action bar (device: "when I expand a tool the
    /// bottom is very empty").
    private var renderableSections: [ToolSection] {
        sections.filter { section in
            switch section {
            case .meta, .command: return false
            default: return true
            }
        }
    }
    /// Only show the collapsible body when there's something to show.
    private var hasBody: Bool { !renderableSections.isEmpty || state == .running }
    private var railColor: Color { state.color(neon) }

    var body: some View {
        HStack(spacing: 0) {
            // Left 3px full-height status rail, glowing.
            Rectangle()
                .fill(railColor)
                .frame(width: 3)
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(railColor) : nil)
                .opacity(state == .running ? (blink ? 1.0 : 0.55) : 1.0)

            VStack(alignment: .leading, spacing: 0) {
                header
                metaStrip
                // Round-3 §1: no permanent action bar — Copy / Re-run /
                // Open-in-terminal appear only when the card is expanded
                // (the standalone-card equivalent of "the focused row").
                // `hasBody` (PR #386): never render an empty output block
                // for an output-less tool card.
                if expanded {
                    if hasBody { output }
                    actionBar
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(
            neon,
            fill: neon.codeBg,
            cornerRadius: 14,
            failed: state == .fail,
            glowTint: state == .fail ? neon.red : railColor
        )
        .onAppear {
            if state == .running {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { blink = true }
            }
        }
        .restartAnimationOnForeground {
            guard state == .running else { return }
            blink = false
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { blink = true }
        }
    }

    // Header: `$` + command (mono, ellipsized) + status chip.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("$")
                .font(neon.mono(13).weight(.bold))
                .foregroundStyle(railColor)
                .neonTextGlow(neon.textGlow?.tinted(railColor))
            Text(command)
                .font(neon.mono(13))
                .foregroundStyle(neon.codeText)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusChip
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(neon.textDim)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusChip: some View {
        switch state {
        case .running, .pending:
            HStack(spacing: 5) {
                Circle()
                    .fill(railColor)
                    .frame(width: 6, height: 6)
                    .opacity(blink ? 1.0 : 0.4)
                Text("running")
                    .font(neon.mono(10.5).weight(.semibold))
                    .foregroundStyle(railColor)
            }
        case .ok, .fail:
            let code = event.exitCode ?? (state == .fail ? 1 : 0)
            Text("exit \(code)")
                .font(neon.mono(10.5).weight(.bold))
                .foregroundStyle(state == .fail ? neon.red : neon.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill((state == .fail ? neon.red : neon.green).opacity(0.18))
                )
        }
    }

    // Meta strip: folder + cwd · host · duration. Each field omitted
    // gracefully when absent.
    @ViewBuilder
    private var metaStrip: some View {
        // `cwd` / `host` are not surfaced on ConversationItem over UniFFI
        // (core's classifier doesn't emit them). Kept as nil so the meta
        // strip degrades to duration-only until core adds the fields;
        // wiring stays ready for that. See README §4.1.
        let cwd: String? = nil
        let host: String? = nil
        let duration = ConversationRenderer.extractMetadata(from: event).duration
        let hasAny = (cwd?.isEmpty == false) || (host?.isEmpty == false) || (duration?.isEmpty == false)
        if hasAny {
            HStack(spacing: 6) {
                if let cwd, !cwd.isEmpty {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(neon.textFaint)
                    Text(cwd)
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let host, !host.isEmpty {
                    Text("·").font(neon.mono(10.5)).foregroundStyle(neon.textFaint)
                    Text(host)
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let duration, !duration.isEmpty {
                    Text(duration)
                        .font(neon.mono(10.5))
                        .foregroundStyle(state == .fail ? neon.red : neon.textDim)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // Output (collapsible): stdout in codeText, stderr in red. Blinking
    // block cursor while running.
    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(renderableSections.enumerated()), id: \.offset) { _, section in
                switch section {
                case .stdout(let text):
                    outputText(text, color: neon.codeText)
                case .stderr(let text):
                    outputText(text, color: neon.red, glow: true)
                case .text(let text):
                    outputText(text, color: neon.codeText)
                case .code(let language, let content):
                    ConduitCodeBlock(language: language, content: content)
                case .diff(let diff):
                    ConduitDiffBlock(content: diff, diffSummary: event.diffSummary)
                case .files(let files):
                    ConduitFileStrip(files: files)
                case .meta, .command:
                    EmptyView()  // already shown in header / meta strip
                }
            }
            if state == .running {
                Text("\u{2588}")
                    .font(neon.mono(11.3))
                    .foregroundStyle(neon.codeText)
                    .opacity(blink ? 1.0 : 0.0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 132, alignment: .topLeading)
        .clipped()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func outputText(_ text: String, color: Color, glow: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(neon.mono(11.3))
                .foregroundStyle(color)
                .neonTextGlow(glow ? neon.textGlow?.tinted(neon.red) : nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Action bar (top-bordered): Copy · Re-run · Open in terminal.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton("Copy", icon: "doc.on.doc") {
                UIPasteboard.general.string = command
            }
            actionDivider
            actionButton("Re-run", icon: "arrow.clockwise") {
                // Wired: resend the command as a chat message (the agent
                // re-executes). SessionStore exposes no direct exec hook,
                // so this is the closest existing seam.
                guard !sessionID.isEmpty else { return }
                store.sendChat(sessionID: sessionID, message: command)
            }
            actionDivider
            actionButton("Open in terminal", icon: "terminal") {
                // Switch the session to its Terminal tab (the tab host
                // provides this via the environment). Disabled when absent
                // (read-only / tablet chat-only pane).
                openTerminalAction?()
            }
            .disabled(openTerminalAction == nil)
            .opacity(openTerminalAction == nil ? 0.4 : 1)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(neon.border).frame(height: 1)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(neon.mono(11).weight(.medium))
            }
            .foregroundStyle(neon.textDim)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actionDivider: some View {
        Rectangle().fill(neon.border).frame(width: 1, height: 20)
    }
}

private struct ConduitStatusChip: View {
    let status: String
    @Environment(\.neonTheme) private var neon

    var body: some View {
        Text(status.isEmpty ? "DONE" : status.uppercased())
            .font(neon.mono(10).weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
    }

    private var tint: Color {
        switch status.lowercased() {
        case "running", "streaming", "working": return neon.accent2
        case "pending", "thinking":             return neon.claude
        case "failed", "error":                 return neon.red
        default:                                return neon.green
        }
    }
}

private struct ConduitCommandBlock: View {
    let command: String
    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConduitSectionLabel(title: "COMMAND")
            Text(command)
                .font(neon.mono(12).weight(.semibold))
                .foregroundStyle(neon.codeText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(neon.codeBg)
                )
        }
    }
}

private struct ConduitToolMetaBlock: View {
    let meta: ToolMetadata
    @Environment(\.neonTheme) private var neon

    var body: some View {
        HStack(spacing: 8) {
            if let code = meta.exitCode {
                Text("EXIT \(code)")
                    .font(neon.mono(10).weight(.bold))
                    .foregroundStyle(code == 0 ? neon.green : neon.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill((code == 0 ? neon.green : neon.red).opacity(0.18)))
            }
            if let duration = meta.duration, !duration.isEmpty {
                Text("DURATION \(duration)")
                    .font(neon.mono(10).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(neon.surface2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConduitLabeledOutputBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConduitSectionLabel(title: title)
            ConduitCodeBlock(language: nil, content: text)
        }
    }
}

private struct ConduitSectionLabel: View {
    let title: String
    @Environment(\.neonTheme) private var neon

    var body: some View {
        Text(title)
            .font(neon.mono(10).weight(.bold))
            .tracking(0.7)
            .foregroundStyle(neon.textDim)
    }
}

private struct ConduitFileStrip: View {
    let files: [ViewEventFile]
    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConduitSectionLabel(title: "FILES")
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(neon.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path)
                            .font(neon.mono(12))
                            .foregroundStyle(neon.text)
                            .lineLimit(2)
                        if !file.rev.isEmpty {
                            Text("@\(file.rev.prefix(7))")
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(neon.surface2)
                )
            }
        }
    }
}

// MARK: - Diff block

private struct ConduitDiffBlock: View {
    let content: String
    /// Optional pre-parsed `+N −M` summary (from `diffSummary`). When nil
    /// the per-file line counts speak for themselves.
    var diffSummary: String? = nil
    @State private var expandedFileIDs: Set<String> = []
    @Environment(\.neonTheme) private var neon

    var body: some View {
        let files = ConversationDiffParser.files(from: content)
        VStack(alignment: .leading, spacing: 8) {
            ConduitSectionLabel(title: "DIFF")
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            if expandedFileIDs.contains(file.id) {
                                expandedFileIDs.remove(file.id)
                            } else {
                                expandedFileIDs.insert(file.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expandedFileIDs.contains(file.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(neon.textDim)
                            // §5: edit icon + filename (mono, ellipsized).
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(neon.claude)
                            Text(file.path)
                                .font(neon.mono(12).weight(.semibold))
                                .foregroundStyle(neon.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            diffStatBadge(for: file)
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedFileIDs.contains(file.id) {
                        let lang = SyntaxLanguage.fromPath(file.path)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                                SyntaxHighlightedDiffLine(
                                    line: line,
                                    language: lang,
                                    tint: color(for: line)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                // §5: tinted gutters — `+` green row bg,
                                // `-` red row bg, context flat.
                                .background(rowBackground(for: line))
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(neon.codeBg))
            }
        }
        .onAppear {
            if expandedFileIDs.isEmpty {
                // PERF: only auto-expand SMALL files. Each visible diff
                // line is its own syntax-highlight pass (highlight.js in a
                // JSContext), so a big diff auto-expanded on appearance lit
                // up hundreds of lines at once — a CPU spike that compounds
                // the long-chat overheat. Large diffs start collapsed; the
                // user taps the file to expand it.
                expandedFileIDs = Set(
                    files.filter { $0.lines.count <= Self.autoExpandLineLimit }.map(\.id)
                )
            }
        }
    }

    /// Files longer than this stay collapsed by default (tap to expand)
    /// so a large diff doesn't syntax-highlight every line at once.
    private static let autoExpandLineLimit = 40

    /// `+N −M` badge — prefers the explicit `diffSummary` over per-file
    /// line counts (§4.4 header).
    @ViewBuilder
    private func diffStatBadge(for file: ConversationDiffFile) -> some View {
        let stat = NeonDiffStat.parse(diffSummary)
        if stat.added != nil || stat.removed != nil {
            HStack(spacing: 6) {
                if let a = stat.added {
                    Text("+\(a)").font(neon.mono(10.5).weight(.bold)).foregroundStyle(neon.green)
                }
                if let r = stat.removed {
                    Text("−\(r)").font(neon.mono(10.5).weight(.bold)).foregroundStyle(neon.red)
                }
            }
        } else {
            Text("\(file.lines.count) lines")
                .font(neon.mono(10))
                .foregroundStyle(neon.textFaint)
        }
    }

    private func rowBackground(for line: String) -> Color {
        if line.hasPrefix("+") { return neon.green.opacity(0.12) }
        if line.hasPrefix("-") { return neon.red.opacity(0.12) }
        return .clear
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return neon.green }
        if line.hasPrefix("-") { return neon.red }
        if line.hasPrefix("@@") { return neon.yellow }
        return neon.textDim
    }
}

// MARK: - Pending input / handoff / subagent cards

private struct ConduitPendingInputCard: View {
    let event: ConversationItem
    /// Durable lock from the ChatView (survives this card being recreated
    /// when new events stream in). Once true the card stays settled and
    /// no further tap can fire — closes the double-send bug.
    var alreadyAnswered: Bool = false
    /// The previously-chosen answer text (from the durable ChatView store) so
    /// a card recreated after reopen still shows the "Sent · <answer>" echo and
    /// the selected-row checkmark. nil when unanswered / not captured.
    var answeredText: String? = nil
    let onQuickReply: (String) -> Void
    /// Called the instant the user submits so the ChatView records this
    /// event as answered, carrying the chosen answer text for persistence.
    var onAnswered: (String?) -> Void = { _ in }
    @Environment(\.neonTheme) private var neon

    /// Chosen option per single-select question index. Drives the
    /// selection highlight and gates the Send button.
    @State private var selections: [Int: String] = [:]
    /// Chosen options per MULTI-select question index (round-4 device
    /// feedback: multiSelect questions previously rendered single-choice).
    @State private var multiSelections: [Int: Set<String>] = [:]
    /// Local submit flag. The card is locked when EITHER this or the
    /// durable `alreadyAnswered` is set.
    @State private var localSubmitted = false
    /// The chosen answer text, kept so the locked card can echo it.
    @State private var sentAnswer: String?

    /// The card is settled once submitted locally OR recorded answered
    /// upstream — the second source is what makes the lock survive a
    /// re-render.
    private var submitted: Bool { localSubmitted || alreadyAnswered }

    /// Per-question groups recovered from the prompt body (#7). Falls back
    /// to the flat `pendingOptions` as a single unlabeled question.
    private var questions: [ConduitUI.PendingQuestion] {
        let parsed = ConduitUI.ChatViewModel.parsePendingQuestions(event.content)
        if !parsed.isEmpty { return parsed }
        let flat = event.pendingOptions.isEmpty
            ? ConversationRenderer.extractPendingOptions(from: event.content)
            : event.pendingOptions
        return [ConduitUI.PendingQuestion(prompt: "", options: flat)]
    }

    var body: some View {
        if submitted {
            answeredChip
        } else {
            unansweredCard
        }
    }

    // Compact inline pill shown once the question is answered.
    private var answeredChip: some View {
        let rawAnswer = (sentAnswer ?? answeredText) ?? "Answered"
        let displayText = rawAnswer
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
            Text(displayText)
                .font(neon.mono(12).weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(neon.green)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(neon.green.opacity(0.10)))
        .overlay(Capsule(style: .continuous).stroke(neon.green.opacity(0.30), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unansweredCard: some View {
        let questions = self.questions
        // The explicit Send appears for multiple questions OR any
        // multi-select question — only a lone single-select question
        // keeps tap-to-send.
        let needsSend = questions.count > 1 || questions.contains { $0.multiSelect }
        return VStack(alignment: .leading, spacing: 12) {
            Text("NEEDS YOUR INPUT")
                .font(neon.mono(11).weight(.bold))
                .tracking(0.8)
                .foregroundStyle(neon.claude)
                .neonTextGlow(neon.textGlow?.tinted(neon.claude))
            ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.prompt.isEmpty {
                        ConduitMarkdownBlock(text: question.prompt, role: .assistant)
                    }
                    if question.multiSelect {
                        Text("select all that apply")
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { oIdx, option in
                        optionRow(
                            question: qIdx, option: option, index: oIdx,
                            needsSend: needsSend, multiSelect: question.multiSelect
                        )
                    }
                }
            }
            if needsSend {
                sendButton(questions: questions)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(neon.claude.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(neon.claude, lineWidth: 1.5)
        )
        .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.claude) : nil)
    }

    @ViewBuilder
    private func optionRow(
        question qIdx: Int, option: String, index oIdx: Int,
        needsSend: Bool, multiSelect: Bool
    ) -> some View {
        let localSelected = multiSelect
            ? (multiSelections[qIdx]?.contains(option) ?? false)
            : selections[qIdx] == option
        // After a reopen the local selection state is gone but the card is
        // still locked (alreadyAnswered). Recover the highlight from the
        // persisted answer text so the chosen row keeps its checkmark.
        let hasLocalSelection = !selections.isEmpty || !multiSelections.isEmpty
        let recovered = submitted && !hasLocalSelection
            && (answeredText.map { answerContains($0, option: option) } ?? false)
        let selected = localSelected || recovered
        let dimmed = submitted && !selected
        Button {
            guard !submitted else { return }
            if multiSelect {
                // Checkbox semantics: toggle membership; Send delivers.
                var set = multiSelections[qIdx] ?? []
                if set.contains(option) { set.remove(option) } else { set.insert(option) }
                multiSelections[qIdx] = set
                return
            }
            selections[qIdx] = option
            // A lone single-select question sends immediately (tap ==
            // answer); anything needing Send waits for the explicit tap.
            if !needsSend {
                submit([option])
            }
        } label: {
            HStack(spacing: 10) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(neon.accentText)
                }
                Text(option)
                    .font(neon.sans(15).weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? neon.accentText : neon.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !selected {
                    Text("\(oIdx + 1)")
                        .font(neon.mono(12).weight(.bold))
                        .foregroundStyle(neon.textFaint)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? neon.claude : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.clear : neon.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitted)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHint(needsSend ? "Select this option" : "Send this reply")
    }

    /// Whether a persisted answer string (newline-joined across questions,
    /// ", "-joined within a multi-select) names this exact option. Matches on
    /// delimited tokens so "Yes" doesn't spuriously match "Yes, all".
    private func answerContains(_ answer: String, option: String) -> Bool {
        let target = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let tokens = answer
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return tokens.contains(target)
    }

    /// One question's answer string: multi-select joins the chosen labels
    /// (in option order) with ", "; single-select is the chosen label.
    private func answer(for qIdx: Int, question: ConduitUI.PendingQuestion) -> String? {
        if question.multiSelect {
            guard let set = multiSelections[qIdx], !set.isEmpty else { return nil }
            return question.options.filter { set.contains($0) }.joined(separator: ", ")
        }
        return selections[qIdx]
    }

    @ViewBuilder
    private func sendButton(questions: [ConduitUI.PendingQuestion]) -> some View {
        // Only questions that actually offer options need an answer.
        let answerable = questions.enumerated().filter { !$0.element.options.isEmpty }
        let answers = answerable.compactMap { answer(for: $0.offset, question: $0.element) }
        let allAnswered = answers.count == answerable.count
        Button {
            guard allAnswered else { return }
            submit(answers)
        } label: {
            Text("Send")
                .font(neon.sans(15).weight(.semibold))
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(neon.claude)
                )
        }
        .buttonStyle(.plain)
        .disabled(!allAnswered)
        .opacity(allAnswered ? 1 : 0.5)
    }

    /// Lock the card and send the chosen answer(s). Multiple answers are
    /// newline-joined into one chat message. Guarded against a double
    /// submit (the bug): once locked, further taps are ignored, and the
    /// lock is recorded upstream so it survives a card re-render.
    private func submit(_ answers: [String]) {
        guard !submitted else { return }
        let joined = answers.joined(separator: "\n")
        // Lock OPTIMISTICALLY and immediately — before the send — so the
        // card visibly settles the instant the user taps.
        localSubmitted = true
        sentAnswer = joined
        onAnswered(joined)
        onQuickReply(joined)
    }
}

private struct ConduitHandoffCard: View {
    let event: ConversationItem
    @Environment(\.neonTheme) private var neon

    /// Resolve an agent name to a neon brand colour (claude/codex/accent).
    private func agentColor(_ name: String?) -> Color {
        guard let lower = name?.lowercased(), !lower.isEmpty else { return neon.accent }
        if lower.contains("claude") { return neon.claude }
        if lower.contains("codex") || lower.contains("gpt") || lower.contains("openai") { return neon.codex }
        return neon.accent
    }

    // Structured handoff fields are now surfaced on ConversationItem over
    // UniFFI (core Tier-1 classifier, see docs/NEON-CORE-FIELDS.md): the
    // from→to agents, the delegated TASK, and the result summary. Status
    // drives working/done. See README §4.2.
    private var target: String { event.targetAgent ?? "" }
    private var source: String { event.sourceAgent ?? "" }
    private var done: Bool { event.status.lowercased() == "done" }

    /// Delegated instruction (TASK block) — nil when absent/blank.
    private var taskText: String? {
        let t = event.taskText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    /// Parsed result summary (result block) — nil when absent/blank.
    private var resultSummary: String? {
        let r = event.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r?.isEmpty == false) ? r : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two agent avatars + chevron (from→to).
            HStack(spacing: 8) {
                agentAvatar(source)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(neon.textDim)
                agentAvatar(target)
                titleRow
                Spacer(minLength: 0)
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }
            }
            // TASK block (dark inset) — the delegated instruction.
            if let taskText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TASK")
                        .font(neon.mono(9).weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(neon.textFaint)
                    Text(taskText)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.codeText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(neon.codeBg))
            }
            // Body content (markdown) when present.
            if !event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ConduitMarkdownBlock(text: event.content, role: .system)
            }
            // Result block (top-bordered, faint green wash) — parsed
            // HANDOFF-OUT summary.
            if let resultSummary {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(neon.green)
                        Text("RESULT")
                            .font(neon.mono(9).weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(neon.textFaint)
                    }
                    Text(resultSummary)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(neon.green.opacity(0.08)))
                .overlay(alignment: .top) { Rectangle().fill(neon.green.opacity(0.4)).frame(height: 1) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 15, border: agentColor(target).opacity(0.55), glowTint: agentColor(target))
    }

    private var titleRow: some View {
        HStack(spacing: 4) {
            if !source.isEmpty {
                Text(source)
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(agentColor(source))
            }
            if !source.isEmpty && !target.isEmpty {
                Text("→").font(neon.mono(12)).foregroundStyle(neon.textDim)
            }
            if !target.isEmpty {
                Text(target)
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(agentColor(target))
                    .neonTextGlow(neon.textGlow?.tinted(agentColor(target)))
            }
            if source.isEmpty && target.isEmpty {
                Text("Handoff")
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.text)
            }
        }
    }

    private func agentAvatar(_ name: String) -> some View {
        let color = agentColor(name.isEmpty ? nil : name)
        return Text(name.isEmpty ? "?" : String(name.prefix(1)).uppercased())
            .font(neon.mono(12).weight(.bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(color.opacity(0.16)))
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

/// §4.2 SwapNotice — an inline divider shown when an agent swap is
/// transitioning (swapping → running). The current event model has no
/// reliable "swapping" phase distinct from a handoff, so this is a small
/// reusable view that is NOT wired into the dispatch yet. Reported as a
/// gap; renders correctly if a future phase surfaces it.
struct ConduitSwapNotice: View {
    let from: String
    let to: String
    @Environment(\.neonTheme) private var neon

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(neon.border).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .bold))
                Text("\(from) → \(to)")
                    .font(neon.mono(10.5).weight(.semibold))
            }
            .foregroundStyle(neon.accent2)
            .neonTextGlow(neon.textGlow?.tinted(neon.accent2))
            Rectangle().fill(neon.border).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConduitSubagentCard: View {
    let event: ConversationItem
    @State private var expanded = false
    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(neon.purple)
                Text("SUBAGENT")
                    .font(neon.mono(10).weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(neon.textDim)
                ConduitStatusChip(status: event.status)
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(neon.textDim)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }
            if expanded {
                ConduitMarkdownBlock(text: event.content, role: .system)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(event.content.split(separator: "\n").first.map(String.init) ?? "Subagent activity")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14, glowTint: neon.purple)
    }
}

/// Renders a peer-session message (broker `SendPeerChat` /
/// `framePeerMessage`) as a distinct inbound card instead of the "YOU"
/// user bubble -- the raw framed envelope was showing up as a giant user
/// message with no indication it came from another agent session, not the
/// human. Header is tappable to jump to the sender session when it's one
/// this device already knows about (via `SessionStore.sessions`); otherwise
/// the tap is a no-op (no session id, or an id we can't resolve).
private struct ConduitPeerMessageCard: View {
    let event: ConversationItem
    let peer: ConduitPeerMessage.Parsed
    @Environment(\.neonTheme) private var neon
    @Environment(SessionStore.self) private var store

    private var knownSession: ProjectSession? {
        guard let id = peer.fromSessionID else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !peer.body.isEmpty {
                ConduitMarkdownBlock(text: peer.body, role: .system)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14, glowTint: neon.blue)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(neon.blue)
            Text("PEER MESSAGE")
                .font(neon.mono(10).weight(.bold))
                .tracking(0.7)
                .foregroundStyle(neon.textDim)
            Text(ConduitPeerMessage.displayLabel(peer))
                .font(neon.sans(13).weight(.semibold))
                .foregroundStyle(neon.blue)
                .lineLimit(1)
            Spacer()
            if knownSession != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(neon.textFaint)
            }
            if !event.ts.isEmpty {
                Text(ConversationTimestamp.relative(event.ts))
                    .font(neon.mono(10))
                    .foregroundStyle(neon.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let session = knownSession else { return }
            store.switchTo(sessionID: session.id)
        }
    }
}

// MARK: - Plan card (§4.3)
//
// "PLAN" with step bullets: done = filled accent/green + check (glowing),
// active = ring + dot + "running…", todo = faint ring; done labels are
// struck through in textDim. Wired into `ConduitEventRow` on
// kind=="plan"; driven by `event.planSteps` (core Tier-3 classifier, see
// docs/NEON-CORE-FIELDS.md).
struct ConduitPlanCard: View {
    let event: ConversationItem
    @Environment(\.neonTheme) private var neon

    var body: some View {
        if event.planSteps.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("PLAN")
                    .font(neon.mono(11).weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(neon.accent)
                    .neonTextGlow(neon.textGlow?.tinted(neon.accent))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(event.planSteps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }
    }

    @ViewBuilder
    private func stepRow(_ step: PlanStep) -> some View {
        let state = step.state.lowercased()
        let isDone = state == "done"
        let isActive = state == "active"
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            bullet(isDone: isDone, isActive: isActive)
            Text(step.text)
                .font(neon.sans(14))
                .strikethrough(isDone, color: neon.textDim)
                .foregroundStyle(isDone ? neon.textDim : (isActive ? neon.text : neon.textDim))
            if isActive {
                Text("running…")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.accent2)
            }
        }
    }

    @ViewBuilder
    private func bullet(isDone: Bool, isActive: Bool) -> some View {
        if isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(neon.green)
                .neonTextGlow(neon.textGlow?.tinted(neon.green))
        } else if isActive {
            Circle()
                .stroke(neon.accent2, lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .overlay(Circle().fill(neon.accent2).frame(width: 6, height: 6))
        } else {
            Circle()
                .stroke(neon.border, lineWidth: 1.5)
                .frame(width: 16, height: 16)
        }
    }
}

// MARK: - Shared inline markdown helper

/// Parse `raw` as inline-only markdown and return an `AttributedString`.
/// Uses `.inlineOnlyPreservingWhitespace` so block markers are left
/// literal and unclosed spans (partial streams) appear as plain text
/// rather than mangling the output. Result is cached in
/// `MessageRenderCache.shared` so repeated calls with the same content
/// (streaming ticks, recycled rows) are free after the first parse.
///
/// Accessible to `StreamingSpineView` and any other ConduitUI view that
/// needs the same settled inline-markdown look.
@MainActor
func conduitInlineAttributed(_ raw: String) -> AttributedString {
    let key = "conduit-md-inline:\(raw.hashValue)"
    if let hit = MessageRenderCache.shared.get(itemID: key, revision: 0) {
        return hit
    }
    let attr = (try? AttributedString(
        markdown: raw,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(raw)
    MessageRenderCache.shared.set(itemID: key, revision: 0, value: attr)
    return attr
}
