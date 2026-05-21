import SwiftUI

struct ChatTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    @State private var draft: String = ""
    @State private var autoFollow = true

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

    /// Litter-style composer: single rounded-rect with a leading `+`
    /// button, the message field, and a trailing mic. Send becomes a
    /// dedicated copper circle only when the draft has content (mic
    /// otherwise — same row position, no layout jump). Agent selector
    /// moved to the header dropdown; no per-row pill here.
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

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    // Reserved for the litter `+` affordance — file
                    // attach / quick-snippet / image. Stage 5 wires it.
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SweKittyTheme.accentStrong)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .stroke(SweKittyTheme.accentStrong, lineWidth: 1.4)
                        )
                }
                .buttonStyle(.plain)

                TextField("Message swe-kitty…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InlineVoiceButton { transcript in
                        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draft = trimmed
                        } else {
                            draft += " " + trimmed
                        }
                    }
                } else {
                    Button {
                        let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !msg.isEmpty else { return }
                        store.sendChat(sessionID: session.id, message: msg)
                        draft = ""
                        autoFollow = true
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassRoundedRect(cornerRadius: 24)
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
