import Foundation

// MARK: - ConduitChatViewModel
//
// Pure-data view-model for the ConduitUI chat surface. We deliberately
// keep this independent of the existing `MessageRenderCache` /
// `ConversationView` pipeline so the ConduitUI chat can be iterated on
// without entangling with the legacy view tree. Tests construct
// snapshots; the SwiftUI view (`ConduitChatView`) is a renderer.

extension ConduitUI {

    /// One rendered chat message in upstream's layout. Conduit renders
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
        /// The #119 ConduitUI cutover dropped that fallback and only
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
                    pendingOptions: [],
                    sourceAgent: nil,
                    targetAgent: nil,
                    taskText: nil,
                    resultSummary: nil,
                    planSteps: []
                )
            }
            guard !synthetic.isEmpty else { return conversation }
            // Sort by ts (PR #111 contract — typed log is ts-sorted).
            // Epoch-normalized (not raw String): a `+09:00` offset or a
            // fractional-second mismatch would otherwise mis-sort, and an
            // empty live `ts` must stay newest. Mirrors Android
            // `sortedByConversationTs`.
            return (conversation + synthetic).sortedByConversationTs { $0.ts }
        }

        /// Placeholder text shown in the composer when the draft is
        /// empty. Mirrors upstream's "Message upstream…" prompt.
        static func composerPlaceholder(forAgent assistant: String?) -> String {
            if let assistant, !assistant.isEmpty {
                return "Message \(assistant)…"
            }
            return "Message…"
        }

        /// Statuses that mark the trailing assistant turn as still busy
        /// (the pre-token "thinking" phase or an in-flight turn). Kept
        /// alongside the predicate so the iOS view and its test share one
        /// source of truth.
        static let workingStatuses: Set<String> = [
            "thinking", "working", "pending", "streaming", "running",
        ]

        /// Whether the agent is busy producing a reply — either actively
        /// streaming tokens OR in the pre-token "thinking" phase. Pure
        /// decision extracted from `ConduitChatView.isAgentWorking`
        /// (device feedback v0.0.50 #5) so it can be pinned without a
        /// SwiftUI host: streaming wins; otherwise the user's message
        /// being the trailing event (no assistant turn started yet) or a
        /// working/thinking/pending/streaming/running assistant status
        /// both count as busy. `lastRole`/`lastStatus` are nil when the
        /// log is empty.
        static func isAgentWorking(
            lastRole: String?,
            lastStatus: String?,
            lastContentEmpty: Bool,
            isStreaming: Bool
        ) -> Bool {
            if isStreaming { return true }
            guard let lastRole else { return false }
            if lastRole.lowercased() == "user" { return true }
            // The assistant turn is the trailing event. Only treat it as
            // "working" when it hasn't produced any content yet — i.e. the
            // pre-first-token "thinking" window (empty assistant item with a
            // working status). Device feedback v0.0.68: the broker never
            // transitions a turn's status to a terminal value on completion
            // (the phase sticks at "running"/"working"), so once tokens stop
            // `isStreaming` correctly goes false but the stale status string
            // kept the typing indicator on a finished turn that was waiting on
            // the user. Gating on empty content ignores that stale status the
            // moment the agent has actually said something.
            guard lastContentEmpty else { return false }
            return workingStatuses.contains((lastStatus ?? "").lowercased())
        }

        /// Layout alignment for a message. User messages right-align,
        /// everything else left-aligns.
        static func alignment(for message: ChatMessage) -> ChatMessageAlignment {
            switch message.role {
            case .user: return .trailing
            default:    return .leading
            }
        }

        /// Infer up to 3 contextual quick replies from the agent's most
        /// recent message. Returns `[]` when nothing is confident — we'd
        /// rather show no chips than noisy ones.
        ///
        /// This is deliberately distinct from the *pending-input* option
        /// chips (`ConduitPendingInputCard`), which come from the agent's
        /// own explicit options. These are inferred client-side so the
        /// user can keep a fast back-and-forth going by tapping instead
        /// of typing — the highest-signal categories are: a blocked /
        /// error turn, a completed turn, an explicit go-ahead request, a
        /// stated next-step, and a plain trailing question.
        static func suggestedReplies(forLastAssistant text: String) -> [String] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return [] }
            let lower = trimmed.lowercased()
            let asksQuestion = trimmed.hasSuffix("?")

            // Error / blocked → recovery actions.
            if containsAny(lower, ["error", "failed", "couldn't", "could not",
                                   "can't ", "cannot ", "blocked", "permission denied"]) {
                return ["Try again", "Show details", "Skip it"]
            }
            // Completion → move forward. A leading "done" (e.g. "Done.",
            // "Done — …", "Done!") is the most common sign-off, so match
            // the prefix in addition to the inline keywords.
            if lower.hasPrefix("done")
                || containsAny(lower, ["all done", "done.", "done!", "completed",
                                       "finished", "fixed", "all set", "✅"]) {
                return ["What's next?", "Show me", "Thanks"]
            }
            // Explicit request for permission / a go-ahead.
            if containsAny(lower, ["should i", "shall i", "want me to", "do you want",
                                   "would you like", "ok to ", "okay to ",
                                   "proceed?", "go ahead?"]) {
                return ["Yes, go ahead", "No", "Explain"]
            }
            // Agent stated a plan / next step (frequently no question mark).
            if containsAny(lower, ["i'll ", "i will ", "let me ", "next, i",
                                   "i'm going to", "i am going to", "i can "]) {
                return ["Go ahead", "Wait", "Explain"]
            }
            // Generic open question.
            if asksQuestion {
                return ["Yes", "No", "Tell me more"]
            }
            return []
        }

        private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
            needles.contains { haystack.contains($0) }
        }
    }

    enum ChatMessageAlignment: Equatable { case leading, trailing }
}
