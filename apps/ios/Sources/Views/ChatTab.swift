import SwiftUI

struct ChatTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    @State private var draft: String = ""
    @State private var autoFollow = true

    var body: some View {
        VStack(spacing: 0) {
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
                    .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.28))
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
            }
            Divider().background(SweKittyTheme.separator)
            composer
                .padding(10)
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
                files: ev.files
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No conversation yet")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Messages, tool activity, diffs, and file references will appear here once the session starts responding.")
                .font(.subheadline)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .glassRect(cornerRadius: 18, tint: SweKittyTheme.accentStrong.opacity(0.16))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "message.badge.waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.accentStrong)
                Text("Reply")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
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
                            .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.24))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SweKittyTheme.surface.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !msg.isEmpty else { return }
                    store.sendChat(sessionID: session.id, message: msg)
                    draft = ""
                    autoFollow = true
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SweKittyTheme.textOnAccent)
                        .frame(width: 42, height: 42)
                        .background(SweKittyTheme.accentStrong)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .glassRoundedRect(cornerRadius: 20)
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
