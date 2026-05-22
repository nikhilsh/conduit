import Foundation

// MARK: - LitterChatViewModel
//
// Pure-data view-model for the LitterUI chat surface. We deliberately
// keep this independent of the existing `MessageRenderCache` /
// `ConversationView` pipeline so the LitterUI chat can be iterated on
// without entangling with the legacy view tree. Tests construct
// snapshots; the SwiftUI view (`LitterChatView`) is a renderer.

extension LitterUI {

    /// One rendered chat message in litter's layout. Litter renders
    /// assistant messages full-width with no bubble, and user
    /// messages right-aligned, flat (no bubble).
    struct ChatMessage: Equatable, Identifiable {
        enum Role: Equatable { case user, assistant, system, tool }
        var id: String
        var role: Role
        var text: String
        /// Optional timestamp / model meta to render under the message.
        var meta: String?
    }

    struct ChatSnapshot: Equatable {
        var messages: [ChatMessage]
        var draft: String
        var isStreaming: Bool
        /// If non-nil, render an inline "Recording…" indicator above
        /// the composer.
        var voiceTranscript: String?

        static let empty = ChatSnapshot(
            messages: [],
            draft: "",
            isStreaming: false,
            voiceTranscript: nil
        )
    }

    enum ChatViewModel {
        /// True when the composer's send button should be enabled.
        static func canSend(_ snap: ChatSnapshot) -> Bool {
            !snap.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Resolve the events stream the chat surface should render.
        ///
        /// Pre-#119 the legacy `ChatTab` preferred the typed
        /// `conversationLog` (built by `refreshConversation` from the
        /// broker's structured `view_event` stream) and, when empty,
        /// fell back to mapping the raw `chatLog` (the broker's
        /// `on_chat_event` deliveries — PTY-scraped chat events from
        /// `ConversationRenderer`/the Tier-1 adapter) into synthetic
        /// `ConversationItem`s.
        ///
        /// The #119 LitterUI cutover dropped that fallback and only
        /// read from `conversationLog`. For sessions where the broker
        /// emits the assistant reply through `on_chat_event` (codex
        /// today) but the typed `view_event`/`listConversationItems`
        /// surface hasn't caught up, the assistant reply was visible
        /// in the Terminal tab but never reached the chat tab. This
        /// fallback restores the legacy behaviour: every raw chat
        /// event missing from the typed log gets synthesized into a
        /// `ConversationItem` and spliced in by timestamp so the chat
        /// surface stays chronological.
        static func mergedEvents(
            conversation: [ConversationItem],
            chatLog: [ChatEvent]
        ) -> [ConversationItem] {
            // Fast path: nothing raw to fold in.
            guard !chatLog.isEmpty else { return conversation }

            // Same fingerprint shape `refreshConversation` uses to dedupe
            // local echoes against the server's typed log — role+content
            // is the only stable identity we get from `ChatEvent`.
            let typedFingerprints = Set(
                conversation.map { "\($0.role.lowercased())|\($0.content)" }
            )
            let synthetic: [ConversationItem] = chatLog.enumerated().compactMap { idx, ev in
                let key = "\(ev.role.lowercased())|\(ev.content)"
                if typedFingerprints.contains(key) { return nil }
                return ConversationItem(
                    id: "chatlog-\(ev.ts)-\(idx)",
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
            guard !synthetic.isEmpty else { return conversation }
            // Sort by ts (PR #111 contract — typed log is ts-sorted).
            return (conversation + synthetic).sorted { $0.ts < $1.ts }
        }

        /// Placeholder text shown in the composer when the draft is
        /// empty. Mirrors litter's "Message litter…" prompt.
        static func composerPlaceholder(forAgent assistant: String?) -> String {
            if let assistant, !assistant.isEmpty {
                return "Message \(assistant)…"
            }
            return "Message…"
        }

        /// Layout alignment for a message. User messages right-align,
        /// everything else left-aligns.
        static func alignment(for message: ChatMessage) -> ChatMessageAlignment {
            switch message.role {
            case .user: return .trailing
            default:    return .leading
            }
        }
    }

    enum ChatMessageAlignment: Equatable { case leading, trailing }
}
