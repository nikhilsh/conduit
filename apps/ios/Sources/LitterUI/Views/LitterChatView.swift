import SwiftUI

// MARK: - LitterChatView
//
// Litter-faithful chat surface. Mirrors litter's ConversationView:
//   - Full-width assistant messages (no bubble, body weight, mono
//     when the user picks the mono body font)
//   - Right-aligned user messages, flat (no bubble), brand color
//     accent on the role label
//   - Composer pinned to bottom-safe-area: leading "+" attach,
//     central text field, trailing mic button
//
// For now we read messages out of the legacy `ConversationView`
// data source (`SessionStore.conversationLog`). The actual ChatTab
// already lazily renders markdown blocks via `MessageRenderCache`;
// we render plain text here so the LitterUI chat is shippable today
// and tracks a follow-up to swap in the rich markdown renderer.

extension LitterUI {

    struct ChatView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance

        let session: ProjectSession

        @State private var draft: String = ""
        @FocusState private var composerFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                messagesList
                composer
            }
        }

        // MARK: Messages

        private var messages: [LitterUI.ChatMessage] {
            // Pull from the store's conversation log for this session.
            // ConversationItem is a flat UniFFI struct with string
            // role/kind/content fields, so we map them ourselves.
            let log = store.conversationLog[session.id] ?? []
            return log.compactMap { entry -> LitterUI.ChatMessage? in
                let role: LitterUI.ChatMessage.Role
                switch entry.role.lowercased() {
                case "user":      role = .user
                case "assistant": role = .assistant
                case "tool":      role = .tool
                default:          role = .system
                }
                let text = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return LitterUI.ChatMessage(
                    id: entry.id,
                    role: role,
                    text: text,
                    meta: nil
                )
            }
        }

        private var messagesList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { msg in
                            MessageRow(message: msg, appearance: appearance)
                                .id(msg.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .onChange(of: messages.last?.id) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(newID, anchor: .bottom)
                        }
                    }
                }
            }
        }

        // MARK: Composer

        private var composer: some View {
            HStack(spacing: 8) {
                Button {
                    // attach — handled in follow-up. Stays a stub
                    // visually so the layout matches litter.
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(width: 36, height: 36)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")

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

                let snapshot = LitterUI.ChatSnapshot(
                    messages: [],
                    draft: draft,
                    isStreaming: false,
                    voiceTranscript: nil
                )
                if LitterUI.ChatViewModel.canSend(snapshot) {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(LitterUI.Palette.brand.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                } else {
                    Button {
                        // mic — wired in follow-up.
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

        private func send() {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            store.sendChat(sessionID: session.id, message: text)
            draft = ""
        }
    }
}

// MARK: - Single-message row

private struct MessageRow: View {
    let message: LitterUI.ChatMessage
    let appearance: AppearanceStore

    var body: some View {
        let alignment = LitterUI.ChatViewModel.alignment(for: message)
        HStack(spacing: 0) {
            if alignment == .trailing {
                Spacer(minLength: 40)
            }
            VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(roleColor)
                    .textCase(.uppercase)
                Text(message.text)
                    .font(.system(size: 16, design: LitterUI.Typography.bodyDesign(for: appearance.fontFamily)))
                    .foregroundStyle(LitterUI.Palette.textBody.color)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            }
            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "you"
        case .assistant: return "assistant"
        case .system:    return "system"
        case .tool:      return "tool"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:      return LitterUI.Palette.brand.color
        case .assistant: return LitterUI.Palette.textSecondary.color
        case .system:    return LitterUI.Palette.warning.color
        case .tool:      return LitterUI.Palette.accentStrong.color
        }
    }
}
