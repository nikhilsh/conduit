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
            .scrollDismissesKeyboard(.interactively)
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
                trailingControl
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassRoundedRect()
        }
        .onChange(of: events.count) { _, _ in
            let assistantNow = events.filter { $0.role.lowercased() == "assistant" }.count
            if awaitingReply && assistantNow > assistantCountAtSend {
                awaitingReply = false
            }
        }
    }

    /// Composer placeholder text. Exposed as a static helper so unit
    /// tests can assert the wording (Stage 2 acceptance: reads
    /// "Message <agent>…" using the active SessionStore agent).
    static func placeholder(for assistant: String) -> String {
        let trimmed = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "agent" : trimmed
        return "Message \(name)\u{2026}"
    }

    /// Leading `+` button — no-op for now. The plus affordance maps to
    /// future attach / quick-action behaviour; wiring lands in a
    /// follow-up so this stage is contained to the visual restyle.
    private var plusButton: some View {
        Button {
            // TODO: wire to attach / quick-actions in a follow-up PR.
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.55)
        .accessibilityLabel("Attach")
    }

    /// Trailing slot — mic when there's no draft, send (or stop while
    /// awaiting) when there is. Folds into the single rounded-rect.
    @ViewBuilder
    private var trailingControl: some View {
        if awaitingReply || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty draft and not awaiting: the voice button has already
            // claimed this slot in the row above. Render a placeholder
            // so the layout doesn't jump when the user starts typing.
            Color.clear.frame(width: 36, height: 36)
        } else {
            Button {
                let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !msg.isEmpty else { return }
                assistantCountAtSend = events.filter { $0.role.lowercased() == "assistant" }.count
                store.sendChat(sessionID: session.id, message: msg)
                draft = ""
                autoFollow = true
                awaitingReply = true
            } label: {
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
