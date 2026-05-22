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
