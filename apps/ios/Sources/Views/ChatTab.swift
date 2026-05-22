import SwiftUI

struct ChatTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    @State private var draft: String = ""
    @State private var autoFollow = true
    /// Local flag set when the user sends a chat; cleared when a new
    /// assistant ConversationItem arrives. Drives the "Connecting"
    /// pill above the composer.
    @State private var awaitingReply = false
    /// Snapshot of the assistant-event count at send-time, so the
    /// onChange clears `awaitingReply` only after the *next* reply
    /// (not on the local user-echo we append optimistically).
    @State private var assistantCountAtSend: Int = 0
    /// Composer modals triggered from the `+` and expand buttons.
    @State private var showAttachSheet = false
    @State private var showExpandedComposer = false
    /// In-flight attachments captured by ComposerAttachSheet; folded
    /// into the next send via `composeOutgoingMessage`.
    @State private var pendingAttachments: [ComposerAttachment] = []

    private var agentTint: Color {
        SweKittyTheme.accent(forAgent: session.assistant)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if events.isEmpty {
                        emptyState
                    } else {
                        ConversationTimelineView(events: events) { reply in
                            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                draft = reply
                            } else {
                                draft += "\n" + reply
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(Self.keyboardDismissMode)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in autoFollow = false }
            )
            .onChange(of: events.count) { _, _ in
                guard autoFollow else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoFollow && !events.isEmpty {
                    Button {
                        autoFollow = true
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true, tint: agentTint.opacity(0.28))
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
            }
            // Pin the composer as a bottom safe-area inset so iOS always
            // reserves room for it above the keyboard. Previously the
            // composer was a plain VStack sibling and the focused
            // TextField could end up under the keyboard during the
            // animation, especially after rotation.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider().background(SweKittyTheme.separator)
                    composer
                        .padding(10)
                }
                .background(.regularMaterial)
            }
        }
    }

    private var events: [ConversationItem] {
        let typed = store.conversationLog[session.id] ?? []
        if !typed.isEmpty { return typed }
        // Fallback while migrating older in-memory sessions.
        return (store.chatLog[session.id] ?? []).enumerated().map { idx, ev in
            ConversationItem(
                id: "\(ev.ts)-\(idx)",
                role: ev.role,
                kind: ev.role.lowercased() == "tool" ? "tool" : "message",
                status: "done",
                content: ev.content,
                ts: ev.ts,
                files: ev.files,
                toolName: nil,
                command: nil,
                exitCode: nil,
                durationMs: nil,
                diffSummary: nil,
                pendingOptions: []
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No conversation yet")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Send a message to \(session.assistant). Replies appear here as structured turns; the **Terminal** tab still shows the raw TUI if you want to peek at the unparsed stream.")
                .font(.subheadline)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .glassRect(cornerRadius: 18, tint: agentTint.opacity(0.16))
    }

    /// Litter Stage 2 composer — a single rounded-rect glass surface
    /// laid out as `[+]  TextField  [mic | send]`. Quick-reply chips
    /// and the "Connecting" pill stack above it; the agent-switcher
    /// pill that used to live inline here is gone (now redundant with
    /// the header dropdown introduced in this stage).
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !quickReplies.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickReplies, id: \.self) { reply in
                            Button(reply) {
                                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    draft = reply
                                } else {
                                    draft += "\n" + reply
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .glassCapsule(interactive: true, tint: agentTint.opacity(0.24))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Context chips strip — appears above the composer only
            // when at least one context is pinned to this session.
            ContextBarView(contexts: pinnedContexts) { id in
                store.unpinContext(id, from: session.id)
            }

            // Pending attachments preview — same chip shape as
            // context, but lives inline so it dismisses on send.
            if !pendingAttachments.isEmpty {
                pendingAttachmentStrip
            }

            if awaitingReply {
                connectingPill
            }

            HStack(alignment: .bottom, spacing: 10) {
                plusButton
                TextField(Self.placeholder(for: session.assistant),
                          text: $draft,
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                expandButton
                trailingControl
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassRoundedRect(agentTint: agentTint)
        }
        .onChange(of: events.count) { _, _ in
            let assistantNow = events.filter { $0.role.lowercased() == "assistant" }.count
            if awaitingReply && assistantNow > assistantCountAtSend {
                awaitingReply = false
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            ComposerAttachSheet { attachment in
                pendingAttachments.append(attachment)
            }
        }
        .fullScreenCover(isPresented: $showExpandedComposer) {
            ExpandedComposerView(
                draft: $draft,
                placeholder: Self.placeholder(for: session.assistant),
                accentTint: agentTint,
                onSend: dispatchSend
            )
        }
    }

    /// Pinned context list for the current session — empty array if
    /// nothing pinned, which keeps `ContextBarView` rendering an
    /// EmptyView.
    private var pinnedContexts: [PinnedContext] {
        store.pinnedContexts[session.id] ?? []
    }

    /// Inline preview of attachments that have been picked but not
    /// yet sent. Tap the x to drop one before sending.
    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: att.kind.iconName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textSecondary)
                        Text(att.filename)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SweKittyTheme.textBody)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(SweKittyTheme.textSecondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment \(att.filename)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassCapsule(interactive: false, tint: SweKittyTheme.warning.opacity(0.22))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Keyboard dismiss mode for the chat message ScrollView.
    /// `ScrollDismissesKeyboardMode` is a SwiftUI struct that isn't
    /// Equatable, so we expose both the live SwiftUI value (for the
    /// view body) and a string token (for tests). fix-ui-friction-vol2:
    /// the user expects the iOS-native "scroll down to dismiss"
    /// gesture; `.interactively` drags the keyboard with the user's
    /// finger rather than snapping.
    static let keyboardDismissMode: ScrollDismissesKeyboardMode = .interactively
    static let keyboardDismissModeToken: String = "interactively"

    /// Composer placeholder text. Exposed as a static helper so unit
    /// tests can assert the wording (Stage 2 acceptance: reads
    /// "Message <agent>…" using the active SessionStore agent).
    static func placeholder(for assistant: String) -> String {
        let trimmed = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "agent" : trimmed
        return "Message \(name)\u{2026}"
    }

    /// Leading `+` button — opens the attach sheet. Image / file
    /// picks fold into `pendingAttachments`, which the next send
    /// inlines into the outgoing chat message.
    private var plusButton: some View {
        Button {
            showAttachSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
    }

    /// Expand-into-fullscreen-editor button, sits between the text
    /// field and the mic/send. Hidden while awaiting a reply so the
    /// stop button stays the dominant trailing affordance.
    private var expandButton: some View {
        Button {
            showExpandedComposer = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand composer")
    }

    /// Folds the draft text + any pinned contexts into a single
    /// outgoing chat message. Attachments are NO LONGER inlined here
    /// — they ship through the 0x01 binary upload frame
    /// (sweswe-parity #file-upload) and surface in chat as a `tool`
    /// view_event from the broker.
    private func composeOutgoingMessage(_ draft: String) -> String {
        var pieces: [String] = []
        let chips = pinnedContexts
        if !chips.isEmpty {
            let formatted = chips.map { ctx in
                "[pinned \(ctx.kind.rawValue): \(ctx.label)]\n\(ctx.payload)"
            }.joined(separator: "\n\n")
            pieces.append(formatted)
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            pieces.append(trimmed)
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Shared send path used by both the trailing send button and
    /// the expanded composer's "Send" toolbar item.
    private func dispatchSend() {
        // Fire each pending attachment as its own 0x01 binary upload.
        // Order: uploads first so the broker has the files on disk
        // before the chat message that references them lands in the
        // agent's PTY. Dispatch goes through AttachmentDispatcher so
        // the wiring stays unit-testable.
        let attachments = pendingAttachments
        AttachmentDispatcher.dispatchUploads(
            attachments,
            sessionID: session.id
        ) { sessionID, filename, mime, bytes in
            store.sendFile(
                sessionID: sessionID,
                filename: filename,
                mime: mime,
                payload: bytes
            )
        }
        let outgoing = composeOutgoingMessage(draft)
        let trimmed = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending attachments without any text — the uploads
        // alone produce visible tool view_events.
        if !trimmed.isEmpty {
            assistantCountAtSend = events.filter { $0.role.lowercased() == "assistant" }.count
            store.sendChat(sessionID: session.id, message: trimmed)
            awaitingReply = true
        }
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        pendingAttachments.removeAll()
        autoFollow = true
    }

    /// Trailing slot — mic when there's no draft, send (or stop while
    /// awaiting) when there is. Folds into the single rounded-rect.
    /// Attachments queued without any text also flip the slot to a
    /// send button so the user has a way to fire them off.
    @ViewBuilder
    private var trailingControl: some View {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        if awaitingReply || hasDraft || hasAttachments {
            sendOrStopButton
        } else {
            InlineVoiceButton { transcript in
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = trimmed
                } else {
                    draft += " " + trimmed
                }
            }
        }
    }

    private var connectingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .tint(SweKittyTheme.textSecondary)
            Text("Connecting")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SweKittyTheme.border.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if awaitingReply {
            // Stop button — visually distinct so the user knows the
            // agent is still working. Tap is a no-op for now; harness
            // doesn't expose a "cancel turn" yet.
            Button {
                // Future: store.cancelChat(sessionID: session.id)
            } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SweKittyTheme.textPrimary)
                    .frame(width: 18, height: 18)
                    .frame(width: 36, height: 36)
                    .background(SweKittyTheme.surfaceLight)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty {
            // Empty draft, no attachments, not awaiting: the voice
            // button has already claimed this slot in the row above.
            // Render a placeholder so the layout doesn't jump when
            // the user starts typing.
            Color.clear.frame(width: 36, height: 36)
        } else {
            Button(action: dispatchSend) {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SweKittyTheme.textOnAccent)
                    .frame(width: 36, height: 36)
                    .background(agentTint)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var quickReplies: [String] {
        guard let source = events.reversed().first(where: { ev in
            let role = ev.role.lowercased()
            return role == "assistant" || role == "tool"
        })?.content else {
            return []
        }
        return QuickReplyDetector.suggestions(from: source)
    }
}

private enum QuickReplyDetector {
    static func suggestions(from content: String) -> [String] {
        let lower = content.lowercased()
        var chips: [String] = []
        func add(_ text: String) {
            if !chips.contains(text) { chips.append(text) }
        }

        if lower.contains("confirm") || lower.contains("proceed") || lower.contains("continue") {
            add("Proceed")
            add("Hold for review")
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            add("Show full error log")
            add("Retry with diagnostics")
        }
        if lower.contains("test") || lower.contains("ci") {
            add("Run targeted tests first")
            add("Run full suite")
        }
        if lower.contains("choose") || lower.contains("option") || lower.contains("which") {
            add("Pick the recommended option")
            add("Explain trade-offs")
        }
        if chips.isEmpty {
            add("Continue")
            add("Summarize next steps")
        }
        return Array(chips.prefix(4))
    }
}
