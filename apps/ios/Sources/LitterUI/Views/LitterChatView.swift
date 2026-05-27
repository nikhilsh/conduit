import SwiftUI
import UIKit

// MARK: - LitterChatView
//
// Litter-faithful chat surface. Mirrors litter's ConversationView:
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

extension LitterUI {

    struct ChatView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(StreamingRendererCoordinator.self) private var coordinator

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

        @State private var draft: String = ""
        @State private var showVoiceDictation = false
        // Composer attachments (#240 cross-surface): files picked via the
        // "+" menu sit here as removable chips until send. On send each
        // is uploaded via core `send_file` (0x01 frame → broker writes
        // `uploads/<sessionID>/<filename>`) and a reference line is
        // appended to the outgoing message.
        @State private var pendingAttachments: [LitterUI.ComposerAttachment] = []
        @State private var attachError: String? = nil
        @State private var isUploading = false
        @FocusState private var composerFocused: Bool

        private var isReadOnly: Bool { readOnlyItems != nil || forceReadOnly }

        // Task #39 — streaming auto-scroll that doesn't fight the user.
        // The controller is the pure state machine; the view feeds it
        // drag + bottom-proximity + streaming signals and reads back
        // `shouldFollow…` / `showScrollToBottomButton`.
        @State private var autoScroll = ChatAutoScrollController()

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
                    })
                }
        }

        // MARK: Messages

        private var events: [ConversationItem] {
            // Read-only mode (exited session): render the injected
            // persisted transcript verbatim — nothing in the live store
            // to merge.
            if let readOnlyItems { return readOnlyItems }
            // PR #111 + legacy ChatTab parity: prefer the typed
            // `conversationLog`, but fall back to the broker's raw
            // `chatLog` for events that haven't surfaced through the
            // structured `view_event` stream yet. Without this, codex
            // assistant replies (delivered via `on_chat_event`) showed
            // up in the Terminal tab but never reached the chat tab —
            // the #119 cutover dropped the legacy mapIndexed fallback.
            return LitterUI.ChatViewModel.mergedEvents(
                conversation: store.conversationLog[session.id] ?? [],
                chatLog: store.chatLog[session.id] ?? []
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

        /// Stable id for an invisible spacer pinned at the very end of
        /// the list. Scrolling to *this* (rather than the last event)
        /// guarantees we reach the absolute bottom — below the typing
        /// indicator and any trailing padding — so tap-to-bottom and
        /// stream-follow never land a few pixels short.
        private static let bottomAnchorID = "litter-chat-bottom-anchor"

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

        private var messagesList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            LitterEventRow(event: event, onQuickReply: { reply in
                                store.sendChat(sessionID: session.id, message: reply)
                            })
                            .id(event.id)
                            .padding(.horizontal, 16)
                        }
                        // BUG 3: "agent is typing" indicator lives inside
                        // the scroll content so it follows autoscroll like
                        // any new content while the user is at the bottom.
                        if isStreaming {
                            LitterTypingIndicator()
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
                    .animation(.easeOut(duration: 0.18), value: isStreaming)
                }
                .scrollDismissesKeyboard(.interactively)
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
                                // Device feedback v0.0.47 #4: the composer (and
                                // the safe-area band it pushes above the
                                // keyboard) uses the chat surface color, so
                                // there's no color seam at the composer/keyboard
                                // inset.
                                .background(LitterUI.Palette.surface.color)
                        }
                    }
                }
                // Measure distance from the bottom edge so the controller
                // can decide when the user has scrolled up vs. is pinned
                // to the latest. `contentOffset.y + bounds.height` is the
                // bottom of the visible viewport; subtracting from content
                // height gives the remaining scroll distance.
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height
                        - (geo.contentOffset.y + geo.bounds.height)
                        + geo.contentInsets.bottom
                } action: { _, distance in
                    autoScroll.bottomProximityChanged(distance)
                }
                // A finger-down drag is the user taking manual control —
                // latch `userScrolledUp` so streaming stops yanking them
                // back. The proximity observer above clears the latch once
                // they return near the bottom.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in autoScroll.userDragged() }
                )
                // Follow the stream: re-scroll on each token, but only
                // while the user hasn't scrolled up.
                .onChange(of: streamingContentLength) { _, _ in
                    guard autoScroll.shouldFollowStreaming else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
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
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard autoScroll.shouldFollowStreaming else { return }
                        scrollToTrueBottom(proxy)
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
                }
                .onDisappear { composerFocused = false }
            }
        }

        /// Resign any first responder lingering from another tab so the
        /// chat composer never appears occluded by a stray soft keyboard
        /// on (re-)entry. Mirrors `LitterProjectView.dismissKeyboard`'s
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
                    .foregroundStyle(LitterUI.Palette.brand.color)
                    .frame(width: 40, height: 40)
                    .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
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
        /// options (`LitterPendingInputCard` owns those), so we bail when
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
            return LitterUI.ChatViewModel.suggestedReplies(forLastAssistant: last.content)
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
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(LitterUI.Palette.brand.color)
                                    .litterGlassCapsule(
                                        tint: LitterUI.Palette.brand.color.opacity(0.18),
                                        config: .pill
                                    )
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
                // (each `litterGlassCapsule` is its own translucent blurred
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LitterUI.Palette.danger.color)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                if !pendingAttachments.isEmpty {
                    LitterUI.ComposerAttachmentChips(
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
                        LitterUI.Palette.surface.color.opacity(0),
                        LitterUI.Palette.surface.color.opacity(0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }

        private var composerInputRow: some View {
            HStack(spacing: 8) {
                LitterUI.ComposerAttachButton(
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
                    LitterUI.ChatViewModel.composerPlaceholder(forAgent: session.assistant),
                    text: $draft,
                    axis: .vertical
                )
                .focused($composerFocused)
                .lineLimit(1...4)
                .font(.system(size: 16, design: LitterUI.Typography.bodyDesign(for: appearance.fontFamily)))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .litterGlassCapsule(config: .pill)
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
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(LitterUI.Palette.brand.color)
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
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LitterUI.Palette.textSecondary.color)
                            .frame(width: 36, height: 36)
                            .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
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
            let outgoing = LitterUI.composeOutgoingMessage(
                draft: text,
                pendingAttachments: attachments,
                sessionID: sessionID
            )
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

// MARK: - LitterEventRow
//
// Per-message dispatch — routes `ConversationItem` to the right inline
// card (pending input, handoff, subagent, tool, or chat message).

private struct LitterEventRow: View {
    let event: ConversationItem
    let onQuickReply: (String) -> Void

    var body: some View {
        if event.kind == "pending_input" {
            LitterPendingInputCard(event: event, onQuickReply: onQuickReply)
        } else if event.kind == "handoff" {
            LitterHandoffCard(event: event)
        } else if event.kind == "subagent" {
            LitterSubagentCard(event: event)
        } else if event.role.lowercased() == "tool" {
            LitterToolCard(event: event)
        } else {
            LitterChatMessageRow(event: event)
        }
    }
}

private enum LitterRole {
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

private struct LitterChatMessageRow: View {
    let event: ConversationItem
    @Environment(AppearanceStore.self) private var appearance

    private var role: LitterRole { LitterRole(event.role) }

    var body: some View {
        let alignment: HorizontalAlignment = role == .user ? .trailing : .leading
        VStack(alignment: alignment, spacing: 4) {
            Text(roleLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(roleColor)
                .textCase(.uppercase)
            LitterBlockStack(
                blocks: ConversationRenderer.blocks(for: event.content),
                role: role,
                itemID: event.id
            )
            if !event.files.isEmpty {
                LitterFileStrip(files: event.files)
            }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
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
        case .user:      return LitterUI.Palette.brand.color
        case .assistant: return LitterUI.Palette.textSecondary.color
        case .system:    return LitterUI.Palette.warning.color
        case .tool:      return LitterUI.Palette.accentStrong.color
        }
    }
}

private struct LitterBlockStack: View {
    let blocks: [ConversationBlock]
    let role: LitterRole
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
                    LitterMarkdownBlock(
                        text: text,
                        role: role,
                        itemID: itemID.map { "\($0)#md\(idx)" },
                        streamItemID: idx == 0 ? itemID : nil
                    )
                case .code(let language, let content):
                    LitterCodeBlock(language: language, content: content)
                case .toolSummary(let label, let detail):
                    LitterToolSummaryBlock(label: label, detail: detail)
                }
            }
        }
    }
}

private struct LitterMarkdownBlock: View {
    let text: String
    let role: LitterRole
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
    // split the body into `LitterMarkdownPiece`s and render each with
    // its own vertical rhythm — tables become stacked records, headings
    // get weight + space, lists get bullets + indent.
    @State private var pieces: [LitterMarkdownPiece] = []
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
        LitterStructuredMarkdownView(
            pieces: pieces,
            role: role,
            basePointSize: appearance.bodyPointSize,
            design: SweKittyTypography.design(for: appearance.fontFamily)
        )
        .frame(maxWidth: role == .user ? nil : .infinity, alignment: role == .user ? .trailing : .leading)
        .transition(isStreaming ? .opacity : .identity)
        .animation(isStreaming ? .easeOut(duration: 0.05) : nil, value: pieces)
        // Parse once per key into @State. `.task(id:)` cancels +
        // re-runs when `renderKey` changes; the synchronous seed below
        // covers the very first frame (and recycled rows that already
        // match) so the row never flashes empty at 0px.
        .task(id: renderKey) {
            if renderedKey != renderKey {
                pieces = LitterMarkdownStructure.parse(displayedText)
                renderedKey = renderKey
            }
        }
        .onAppear {
            // First appearance (or recycle into a row whose key differs
            // from the last assignment): seed synchronously so we don't
            // draw an empty row for one frame while the `.task`
            // schedules.
            if renderedKey != renderKey {
                pieces = LitterMarkdownStructure.parse(displayedText)
                renderedKey = renderKey
            }
        }
    }
}

// MARK: - Structured markdown renderer
//
// Renders the typed `LitterMarkdownPiece`s with explicit vertical
// rhythm: headings get weight + space above/below, paragraphs/list
// items/tables get consistent gaps, lists show bullets/numbers + hang
// indent, and GFM tables render as stacked "header: value" records
// (robust on a narrow phone — never the run-on concatenation the device
// bug reported). Inline markdown (bold / code spans / links) inside each
// piece is interpreted per-segment via `AttributedString(markdown:)`,
// looked up through `MessageRenderCache` so a recycled row doesn't
// re-parse.
private struct LitterStructuredMarkdownView: View {
    let pieces: [LitterMarkdownPiece]
    let role: LitterRole
    let basePointSize: CGFloat
    let design: Font.Design

    /// Vertical gap between top-level blocks (BUG 1: blocks were bunched
    /// with no rhythm). 10pt reads as a clear paragraph break without
    /// looking double-spaced.
    private let blockSpacing: CGFloat = 10

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
    private func pieceView(_ piece: LitterMarkdownPiece) -> some View {
        switch piece {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: basePointSize, weight: .regular, design: design))
        case .list(let ordered, let items):
            listView(ordered: ordered, items: items)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    // MARK: Heading

    private func headingView(level: Int, text: String) -> some View {
        let mult = LitterMarkdownHeadingScaler.multiplier(forLevel: level) ?? 1.0
        // Extra space above a heading (but not the very first block)
        // keeps headings from jamming into the preceding text. The
        // outer VStack supplies the gap below.
        return inlineText(text)
            .font(.system(size: basePointSize * mult, weight: .semibold, design: design))
            .padding(.top, level <= 2 ? 6 : 2)
    }

    // MARK: List

    private func listView(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .font(.system(size: basePointSize, weight: .regular, design: design))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    inlineText(item)
                        .font(.system(size: basePointSize, weight: .regular, design: design))
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
                                    .font(.system(size: basePointSize * 0.85, weight: .semibold, design: design))
                                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                            }
                            inlineText(cell)
                                .font(.system(size: basePointSize, weight: .regular, design: design))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LitterUI.Palette.surfaceLight.color.opacity(0.5))
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
        let key = "litter-md-inline:\(raw.hashValue)"
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
        case .user:      return LitterUI.Palette.brand.color
        case .system:    return LitterUI.Palette.textSecondary.color
        default:         return LitterUI.Palette.textBody.color
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
private struct LitterTypingIndicator: View {
    @State private var phase = 0

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("assistant")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(LitterUI.Palette.textSecondary.color)
                .textCase(.uppercase)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(LitterUI.Palette.textSecondary.color)
                        .frame(width: 7, height: 7)
                        .scaleEffect(phase == i ? 1.0 : 0.6)
                        .opacity(phase == i ? 1.0 : 0.4)
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

private struct LitterCodeBlock: View {
    let language: String?
    let content: String

    private var resolvedLanguage: String? { SyntaxLanguage.fromFence(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedCodeBlock(language: resolvedLanguage, content: content)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitterUI.Palette.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LitterUI.Palette.border.color.opacity(0.55), lineWidth: 0.8)
        )
    }
}

private struct LitterToolSummaryBlock: View {
    let label: String
    let detail: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textBody.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Tool card

/// Visual constants for the litter-faithful tool card surface (PLAN-
/// LITTER-VISUAL-PARITY PR 4, audit §A.2.3 / §A.2.8). Extracted so
/// `LitterToolCardSurfaceTests` can pin the rebuild — without that pin
/// the next "tweak this card" PR could quietly restore the glass +
/// status-tint overlay that the audit called out as too prominent.
enum LitterToolCardMetrics {
    /// Leading 6pt status dot replaces the previous wrench glyph.
    static let statusDotSize: CGFloat = 6
    /// Outer corner radius — 14pt matches the new flatter card shape
    /// landed in PR 2 (`litterGlassRoundedRect` default).
    static let surfaceCornerRadius: CGFloat = 14
    /// Surface fill opacity — 0.6 keeps the card legible without the
    /// "card-inside-card" layering the prior glass treatment produced
    /// once a code or diff sub-block landed inside.
    static let surfaceOpacity: Double = 0.6
}

private struct LitterToolCard: View {
    let event: ConversationItem
    // Device feedback v0.0.47 #2: tool/bash cards open COLLAPSED — just
    // the header row (label · status · command one-liner · time + a
    // chevron). Tapping expands to the full COMMAND box + output. State
    // is per-card @State, so it persists for the session (the card stays
    // expanded once tapped) while every fresh card starts collapsed.
    @State private var expanded = false

    private var sections: [ToolSection] { ConversationRenderer.toolSections(for: event) }

    private var summary: String {
        if let command = event.command, !command.isEmpty {
            return String(command.prefix(80))
        }
        let firstLine = event.content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return "Tool activity" }
        return String(firstLine.prefix(80))
    }

    private var headerLabel: String {
        if let toolName = event.toolName, !toolName.isEmpty {
            return toolName.uppercased()
        }
        return event.kind.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 6pt status dot replaces the wrench.and.screwdriver
                // glyph per audit §A.2.8 — litter's tool cards are
                // text-forward (header label + small status indicator)
                // rather than icon-forward.
                Circle()
                    .fill(statusTint)
                    .frame(width: LitterToolCardMetrics.statusDotSize, height: LitterToolCardMetrics.statusDotSize)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(headerLabel)
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        LitterStatusChip(status: event.status)
                        if let diffSummary = event.diffSummary, !diffSummary.isEmpty {
                            Text(diffSummary.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(LitterUI.Palette.textSecondary.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(LitterUI.Palette.surfaceLight.color)
                                .clipShape(Capsule())
                        }
                    }
                    // Device feedback v0.0.47 #1: the command one-liner
                    // is the collapsed card's only command surface. When
                    // expanded the COMMAND box (`LitterCommandBlock`)
                    // shows the full command, so this row would duplicate
                    // it — hide it once expanded to kill the redundant
                    // plain-text "Bash: …" line the device reported.
                    if !expanded {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(LitterUI.Palette.textBody.color)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(.caption2)
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        switch section {
                        case .meta(let meta):
                            LitterToolMetaBlock(meta: meta)
                        case .command(let command):
                            LitterCommandBlock(command: command)
                        case .files(let files):
                            LitterFileStrip(files: files)
                        case .stdout(let text):
                            LitterLabeledOutputBlock(title: "STDOUT", text: text)
                        case .stderr(let text):
                            LitterLabeledOutputBlock(title: "STDERR", text: text)
                        case .text(let text):
                            LitterMarkdownBlock(text: text, role: .tool)
                        case .code(let language, let content):
                            LitterCodeBlock(language: language, content: content)
                        case .diff(let diff):
                            LitterDiffBlock(content: diff)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // PLAN-LITTER-VISUAL-PARITY audit §A.2.3 — drop the glass
        // surface + 0.20-opacity statusTint overlay; tool cards now
        // render as a flat 0.6-opacity surfaceLight rounded rect, with
        // the per-status tint reduced to the leading 6pt dot. This
        // stops the "card inside card inside card" stacking that
        // happens once a tool card carries a code / diff sub-block.
        .background(
            RoundedRectangle(cornerRadius: LitterToolCardMetrics.surfaceCornerRadius, style: .continuous)
                .fill(LitterUI.Palette.surfaceLight.color.opacity(LitterToolCardMetrics.surfaceOpacity))
        )
    }

    private var statusTint: Color {
        switch event.status.lowercased() {
        case "running":
            return LitterUI.Palette.warning.color
        case "pending":
            return LitterUI.Palette.brand.color
        case "failed":
            return LitterUI.Palette.danger.color
        default:
            return LitterUI.Palette.success.color
        }
    }
}

private struct LitterStatusChip: View {
    let status: String

    var body: some View {
        Text(status.isEmpty ? "DONE" : status.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch status.lowercased() {
        case "running": return LitterUI.Palette.warning.color.opacity(0.20)
        case "pending": return LitterUI.Palette.brand.color.opacity(0.20)
        case "failed":  return LitterUI.Palette.danger.color.opacity(0.20)
        default:        return LitterUI.Palette.success.color.opacity(0.20)
        }
    }

    private var foreground: Color {
        switch status.lowercased() {
        case "running": return LitterUI.Palette.warning.color
        case "pending": return LitterUI.Palette.brand.color
        case "failed":  return LitterUI.Palette.danger.color
        default:        return LitterUI.Palette.success.color
        }
    }
}

private struct LitterCommandBlock: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LitterSectionLabel(title: "COMMAND")
            Text(command)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(LitterUI.Palette.textPrimary.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(LitterUI.Palette.codeBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct LitterToolMetaBlock: View {
    let meta: ToolMetadata

    var body: some View {
        HStack(spacing: 8) {
            if let code = meta.exitCode {
                Text("EXIT \(code)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(code == 0 ? LitterUI.Palette.success.color : LitterUI.Palette.danger.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((code == 0 ? LitterUI.Palette.success.color : LitterUI.Palette.danger.color).opacity(0.18))
                    .clipShape(Capsule())
            }
            if let duration = meta.duration, !duration.isEmpty {
                Text("DURATION \(duration)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LitterUI.Palette.surfaceLight.color)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LitterLabeledOutputBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LitterSectionLabel(title: title)
            LitterCodeBlock(language: nil, content: text)
        }
    }
}

private struct LitterSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(LitterUI.Palette.textSecondary.color)
    }
}

private struct LitterFileStrip: View {
    let files: [ViewEventFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LitterSectionLabel(title: "FILES")
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(LitterUI.Palette.brand.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(LitterUI.Palette.textBody.color)
                            .lineLimit(2)
                        if !file.rev.isEmpty {
                            Text("@\(file.rev.prefix(7))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(LitterUI.Palette.surfaceLight.color)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Diff block

private struct LitterDiffBlock: View {
    let content: String
    @State private var expandedFileIDs: Set<String> = []

    var body: some View {
        let files = ConversationDiffParser.files(from: content)
        VStack(alignment: .leading, spacing: 8) {
            LitterSectionLabel(title: "DIFF")
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
                                .foregroundStyle(LitterUI.Palette.textSecondary.color)
                            Text(file.path)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(LitterUI.Palette.textBody.color)
                            Spacer()
                            Text("\(file.lines.count) lines")
                                .font(.caption2)
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedFileIDs.contains(file.id) {
                        let lang = SyntaxLanguage.fromPath(file.path)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                                SyntaxHighlightedDiffLine(
                                    line: line,
                                    language: lang,
                                    tint: color(for: line)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
                .background(LitterUI.Palette.codeBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // PLAN-LITTER-VISUAL-PARITY audit §A.2.9 — drop the
                // 0.8pt border stroke on diff blocks; litter tints
                // diff lines (green/red/warning) against a flat
                // surface without an outer rectangle outline.
            }
        }
        .onAppear {
            if expandedFileIDs.isEmpty {
                expandedFileIDs = Set(files.map(\.id))
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return LitterUI.Palette.success.color }
        if line.hasPrefix("-") { return LitterUI.Palette.danger.color }
        if line.hasPrefix("@@") { return LitterUI.Palette.warning.color }
        return LitterUI.Palette.textBody.color
    }
}

// MARK: - Pending input / handoff / subagent cards

private struct LitterPendingInputCard: View {
    let event: ConversationItem
    let onQuickReply: (String) -> Void

    private var options: [String] {
        if !event.pendingOptions.isEmpty { return event.pendingOptions }
        return ConversationRenderer.extractPendingOptions(from: event.content)
    }

    var body: some View {
        // PLAN-LITTER-VISUAL-PARITY audit §A.2.7 — drop the outer
        // tinted glass card; render as a flat inline row with a
        // leading brand-tint dot. The prior "INPUT NEEDED" card read
        // as an alert (heavy shadow + 18pt tinted glass); litter's
        // `InlineHandoffView` is a much flatter row that the user
        // scans past until the options matter. Quick-reply chips
        // collapse from glass capsules to flat tag-radius (4pt)
        // pills tinted in brand at 0.10 — matches `tagCornerRadius`
        // landed in PR 1.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(LitterUI.Palette.brand.color)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("INPUT NEEDED")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        Spacer()
                        LitterStatusChip(status: event.status)
                    }
                    LitterMarkdownBlock(text: event.content, role: .assistant)
                    if !options.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(options, id: \.self) { option in
                                    Button(option) { onQuickReply(option) }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(LitterUI.Palette.brand.color.opacity(0.10))
                                        )
                                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                                        .font(.footnote.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LitterHandoffCard: View {
    let event: ConversationItem

    var body: some View {
        // Same flat-pill treatment as LitterPendingInputCard above —
        // PLAN-LITTER-VISUAL-PARITY audit §A.2.7. The prior tinted
        // glass card read like an alert; agent handoffs are
        // informative, not actionable, so they should render as a
        // quiet inline row that lives in the transcript flow.
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LitterUI.Palette.brand.color)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("AGENT HANDOFF")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Spacer()
                    if !event.ts.isEmpty {
                        Text(ConversationTimestamp.relative(event.ts))
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                }
                LitterMarkdownBlock(text: event.content, role: .system)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LitterSubagentCard: View {
    let event: ConversationItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.warning.color)
                Text("SUBAGENT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                LitterStatusChip(status: event.status)
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(.caption2)
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }
            if expanded {
                LitterMarkdownBlock(text: event.content, role: .system)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(event.content.split(separator: "\n").first.map(String.init) ?? "Subagent activity")
                    .font(.footnote)
                    .foregroundStyle(LitterUI.Palette.textBody.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litterGlassRoundedRect(cornerRadius: 14, tint: LitterUI.Palette.warning.color.opacity(0.22))
    }
}
