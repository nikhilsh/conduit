import SwiftUI
import UIKit

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

extension ConduitUI {

    struct ChatView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(StreamingRendererCoordinator.self) private var coordinator
        @Environment(\.neonTheme) private var neon

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
        /// Points the composer cluster is manually lifted by. We drive keyboard
        /// avoidance EXPLICITLY off the keyboard frame instead of relying on
        /// SwiftUI's implicit avoidance, which — inside the phone tab ZStack —
        /// intermittently settled the composer ~48pt short on first focus / when
        /// the predictive bar resized the keyboard (proven via the keyboard diag:
        /// overlap flipped between 0 and 48 across taps). With the view ignoring
        /// the `.keyboard` safe area, this inset is the single source of truth,
        /// so the composer lands exactly on the keyboard top every time.
        @State private var keyboardInset: CGFloat = 0
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

        var body: some View {
            // The composer + suggestion cluster is hosted via
            // `.safeAreaInset(edge: .bottom)` on the messages `ScrollView`
            // (see `messagesList`), so SwiftUI lifts it above the soft
            // keyboard while the scroll content insets to keep the latest
            // message visible. The body just adds the voice sheet.
            messagesList
                // Opt out of SwiftUI's implicit keyboard avoidance — we lift
                // the composer manually via `keyboardInset` (see the state
                // doc). The implicit path was unreliable inside the phone tab
                // ZStack (intermittent 48pt undershoot).
                .ignoresSafeArea(.keyboard, edges: .bottom)
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
            readOnly: Bool
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(readOnly)
            hasher.combine(conversation.count)
            hasher.combine(chatLog.count)
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
                conversation: conversation, chatLog: chatLog, readOnly: readOnlyItems != nil
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
            // (commands included — round-3 §1) into one quiet bundle. A
            // run is "adjacent tool calls with no assistant prose between
            // them": any non-tool event closes the current bundle.
            let rows = ConduitUI.ChatViewModel.groupedRows(events, minRun: 2) { ev in
                ev.role.lowercased() == "tool"
                    && ev.status.lowercased() != "swapping"
                    && !["pending_input", "handoff", "plan", "subagent"].contains(ev.kind)
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
                collapseTurns: appearance.collapseTurns
            )
        }

        /// Total length of all currently-streaming buffers. Changes on
        /// every token while the agent streams, so observing it drives
        /// "follow the stream" without re-reading the whole event list.
        private var streamingContentLength: Int {
            events.reduce(0) { acc, event in
                if case .streaming(let buffer) = coordinator.renderState(for: event.id) {
                    return acc + buffer.count
                }
                return acc
            }
        }

        /// `true` while at least one event is mid-stream.
        private var isStreaming: Bool {
            events.contains { event in
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
                isStreaming: isStreaming
            )
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
        private func widenRowWindow(proxy: ScrollViewProxy, anchorRowID: String?) {
            guard !isWideningWindow else { return }
            guard autoScroll.userScrolledUp else { return }
            guard chatRows.count > visibleRowWindow else { return }
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
                for delayMs: UInt64 in [0, 60, 200, 500] {
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
                        if rows.count < allRows.count {
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
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            Group {
                                switch row {
                                case .single(let event):
                                    ConduitEventRow(
                                        event: event,
                                        isContinuation: continuation(in: rows, at: idx, role: event.role),
                                        sessionID: session.id,
                                        pendingAnswered: answeredPendingIDs.contains(event.id),
                                        streamRevision: streamRevision(for: event.id),
                                        appearanceRevision: appearanceRevision,
                                        onQuickReply: { reply in
                                            store.sendChat(sessionID: session.id, message: reply)
                                        },
                                        onPendingAnswered: {
                                            answeredPendingIDs.insert(event.id)
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
                        // BUG 3: "agent is typing" indicator lives inside
                        // the scroll content so it follows autoscroll like
                        // any new content while the user is at the bottom.
                        if isAgentWorking && !isReadOnly {
                            ConduitTypingIndicator()
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
                                // Manual keyboard lift (see `keyboardInset`): the
                                // view ignores the .keyboard safe area, so this
                                // padding raises the composer to the keyboard top.
                                .padding(.bottom, keyboardInset)
                                // Fill ONLY the lifted band — the strip sitting
                                // behind the keyboard's rounded top corners — with
                                // the composer surface colour, bottom-aligned so it
                                // covers the corner gap WITHOUT painting a hard
                                // opaque rectangle over the composer's faded-in top
                                // edge. The previous full-cluster `.background`
                                // drew that flat seam across the chat ("the
                                // rounded-corner fix doesn't look good" — device
                                // feedback v0.0.81). The +24pt underlaps the
                                // composer's own opaque bottom so there's no sliver
                                // where the two meet; zero height when the keyboard
                                // is down (keyboardInset == 0).
                                .background(alignment: .bottom) {
                                    if keyboardInset > 0 {
                                        neon.surfaceSolid
                                            .frame(maxWidth: .infinity)
                                            .frame(height: keyboardInset + 24)
                                            .allowsHitTesting(false)
                                    }
                                }
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
                // History often streams in just after appear (empty → populated);
                // pin the bottom on that first population too.
                .onChange(of: events.count) { old, new in
                    if old == 0 && new > 0 { scrollToBottomOnOpen(proxy) }
                }
                // Switching sessions reuses this view — re-arm for the next one.
                .onChange(of: session.id) { _, _ in didInitialScroll = false }
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
                        keyboardInset = 0
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
                    let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                    applyKeyboardInset(frame)
                    logKeyboardDiag("keyboard will show", keyboardFrame: frame)
                }
                // willChangeFrame catches the predictive/QuickType bar resizing
                // the keyboard AFTER willShow — the source of the intermittent
                // 48pt undershoot. Re-lift to the new frame each time.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                    applyKeyboardInset(frame)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { keyboardInset = 0 }
                    logKeyboardDiag("keyboard will hide")
                }
            }
        }

        /// The key window for geometry math (keyboard frame is in window space).
        private func keyWindow() -> UIWindow? {
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return nil }
            return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        }

        /// Lift the composer cluster to sit exactly on the keyboard top. The
        /// keyboard frame is in window space; the amount above the bottom safe
        /// area (home indicator) is what the `.safeAreaInset(.bottom)` cluster
        /// must rise by. Animated so it tracks the IME presentation.
        private func applyKeyboardInset(_ frame: CGRect?) {
            guard let frame, let window = keyWindow() else { return }
            let inset = max(0, window.bounds.maxY - frame.minY - window.safeAreaInsets.bottom)
            withAnimation(.easeOut(duration: 0.2)) { keyboardInset = inset }
        }

        /// Emit a `diag=keyboard` Sentry breadcrumb capturing the keyboard
        /// intrusion height, screen height, window safe-area bottom inset, and
        /// the composer focus/active state — the inputs that determine whether
        /// the `.safeAreaInset(.bottom)` composer is lifted clear of the soft
        /// keyboard or hidden behind it.
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
            // overlap > 0 ⇒ the composer's bottom edge is BELOW the keyboard top,
            // i.e. hidden behind it. The definitive signal for this bug.
            let overlap = (kbTop > 0) ? max(0, composerMaxY - kbTop) : 0
            Telemetry.debug("keyboard", reason, data: [
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

        // MARK: Composer

        private var composer: some View {
            VStack(alignment: .leading, spacing: 0) {
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
            // Accent-tinted glow rising up from the composer — a quiet
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
                // pending attachment (attachment-only sends are valid —
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
                    .accessibilityLabel("Send")
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

// MARK: - ConduitEventRow
//
// Per-message dispatch — routes `ConversationItem` to the right inline
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
    var onPendingAnswered: () -> Void = {}
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
                onQuickReply: onQuickReply,
                onAnswered: onPendingAnswered
            )
        } else if event.kind == "handoff" {
            ConduitHandoffCard(event: event)
        } else if event.kind == "plan" {
            ConduitPlanCard(event: event)
        } else if event.kind == "subagent" {
            ConduitSubagentCard(event: event)
        } else if event.role.lowercased() == "tool" {
            ConduitToolCard(event: event, sessionID: sessionID, collapseDefault: appearance.collapseTurns)
        } else {
            ConduitChatMessageRow(event: event, isContinuation: isContinuation)
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
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.neonTheme) private var neon

    private var role: ConduitRole { ConduitRole(event.role) }

    var body: some View {
        let alignment: HorizontalAlignment = role == .user ? .trailing : .leading
        VStack(alignment: alignment, spacing: 4) {
            if !isContinuation {
                Text(roleLabel)
                    // Role labels stay mono (terminal-shaped chrome) +
                    // glow when the label is the accent (user / tool).
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(roleColor)
                    .textCase(.uppercase)
                    .neonTextGlow(roleGlow)
            }
            // §2: user messages render in a right-aligned accent pill;
            // the assistant/system prose renders flat on the canvas (no
            // heavy bubble), styled inside ConduitBlockStack.
            if role == .user {
                // The bubble strips its own `[attached …]` reference lines
                // and renders them as chips/thumbnails instead of raw paths.
                ConduitUserBubble(event: event)
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
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
        // Continuation rows get tighter top spacing: the LazyVStack's 14pt
        // gap minus 10pt offset makes grouped messages sit closer together.
        .padding(.top, isContinuation ? -10 : 0)
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
    @Environment(\.neonTheme) private var neon

    var body: some View {
        let parsed = ConduitUI.splitAttachmentReferences(event.content)
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
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
            }
            ForEach(parsed.attachments, id: \.filename) { ref in
                ConduitAttachmentChip(ref: ref)
            }
        }
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

    /// Prose font for transcript text — the user's selected Chat font
    /// (handoff Part A). `FontFamily.font(size:weight:)` resolves the
    /// concrete face (System / Space Grotesk / IBM Plex Sans / Newsreader)
    /// and falls back to the system face if a bundled TTF is missing.
    private func proseFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fontFamily.font(size: size, weight: weight)
    }

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
// of the message list while any turn is streaming. Three dots pulse in a
// staggered loop (scale + opacity) so the user can tell the agent is
// still generating. Matches the assistant role label styling so it reads
// as the agent's in-progress turn.
private struct ConduitTypingIndicator: View {
    @State private var phase = 0
    @Environment(\.neonTheme) private var neon

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Assistant is typing")
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

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

// MARK: - Tool bundle card (round-3 §1)

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
    @Environment(\.neonTheme) private var neon

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
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

    var body: some View {
        // §4.1 vs §4.5: shell/exec calls (or anything carrying a
        // command) get the headline CommandCard; everything else gets
        // the compact neon tool row.
        if NeonToolClassifier.isCommand(toolName: event.toolName, command: ConversationRenderer.extractCommand(from: event)) {
            ConduitNeonCommandCard(event: event, sessionID: sessionID, collapseDefault: collapseDefault)
        } else {
            ConduitNeonToolCard(event: event)
        }
    }
}

// MARK: - Neon status helpers (shared by tool / command cards)

/// One of the four card states the design distinguishes (§4.5).
private enum NeonCardState: Equatable {
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
    let onQuickReply: (String) -> Void
    /// Called the instant the user submits so the ChatView records this
    /// event as answered.
    var onAnswered: () -> Void = {}
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
            if needsSend && !submitted {
                sendButton(questions: questions)
            }
            if submitted {
                // Round-4 device feedback: a tap had no visible "delivered"
                // affordance, so a sent answer read as nothing happening
                // and the user tapped again. Echo the chosen answer next to
                // a "Sent" check so the tap is unmistakably registered.
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(sentAnswer.map { "Sent · \($0)" } ?? "Sent")
                        .font(neon.mono(11).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(neon.green)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(neon.claude.opacity(0.10))
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
        let selected = multiSelect
            ? (multiSelections[qIdx]?.contains(option) ?? false)
            : selections[qIdx] == option
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
        onAnswered()
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
