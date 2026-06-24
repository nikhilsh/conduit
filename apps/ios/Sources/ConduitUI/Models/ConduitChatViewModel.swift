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

    /// One question inside a pending-input prompt: its text plus its own
    /// options. AskUserQuestion can carry several of these; the broker
    /// flattens them into `"<q1>\n1.a\n2.b\n\n<q2>\n1.c\n2.d"` and core
    /// flattens the options into one array, so we recover the grouping
    /// from `content` (#7).
    struct PendingQuestion: Equatable {
        let prompt: String
        let options: [String]
        /// True when the broker marked this question multi-select (the
        /// " (select all that apply)" marker the card strips from the
        /// prompt). Multi-select questions render checkboxes + Send
        /// instead of tap-to-send.
        var multiSelect: Bool = false
    }

    /// A renderable row in the transcript: either a standalone event or a
    /// collapsed run of consecutive tool cards (#4 — keeps long
    /// read/grep/edit sequences from flooding the screen).
    enum ChatRow: Identifiable {
        case single(ConversationItem)
        case toolGroup([ConversationItem])

        var id: String {
            switch self {
            case .single(let item): return item.id
            case .toolGroup(let items): return "toolgroup-\(items.first?.id ?? "")"
            }
        }
    }

    enum ChatViewModel {
        /// True when the composer's send button should be enabled.
        static func canSend(_ snap: ChatSnapshot) -> Bool {
            !snap.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// A stable revision over every APPEARANCE input that changes how
        /// a chat row renders. Fed into the per-row Equatable digest so a
        /// theme / font / glow / palette / collapse-turns / light-dark
        /// change re-renders ALL rows (the digest differs), while leaving
        /// rows untouched when only scroll position or an unrelated row
        /// changes. Rare-to-change, so recomputing it per parent body is
        /// free. Pure + unit-tested. Must be EXHAUSTIVE over
        /// render-affecting appearance state — a missed input would
        /// stale-out equatable rows when that input changes.
        static func appearanceRenderRevision(
            fontFamily: String,
            bodyPointSize: CGFloat,
            palette: String,
            glow: Bool,
            dark: Bool,
            collapseTurns: Bool,
            chatArm: String = "a"
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(fontFamily)
            hasher.combine(bodyPointSize)
            hasher.combine(palette)
            hasher.combine(glow)
            hasher.combine(dark)
            hasher.combine(collapseTurns)
            // chat-shell-v2 arm (§2): switching A↔B must re-render every row.
            hasher.combine(chatArm)
            return hasher.finalize()
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
        /// A client-synthesized "uploaded …" tool card the broker emits on
        /// each file upload. The user already sees the attachment as a chip
        /// in their own bubble, so the duplicate activity card is dropped
        /// from the chat transcript.
        static func isUploadToolEvent(_ item: ConversationItem) -> Bool {
            if (item.toolName ?? "").lowercased() == "file_upload" { return true }
            // PTY-scraped chatlog fallback carries no toolName.
            return item.role.lowercased() == "tool"
                && item.content.hasPrefix("uploaded ")
        }

        /// The exact marker the broker's `askUserQuestionContent` appends
        /// to a multi-select question's prompt line. Carried inside the
        /// text so no broker → core → app schema change was needed.
        static let multiSelectMarker = " (select all that apply)"

        /// The deterministic pending-input sentinel the broker prepends to
        /// a genuine AskUserQuestion. Core normally strips it before the
        /// item reaches us; this defensive strip covers the raw-chatLog
        /// fallback path. Byte-identical to the broker constant.
        static let pendingInputSentinel = "[[conduit:needs-input]]"

        /// The leading token of the resolution-marker line the broker
        /// inserts into a PERSISTED, already-answered pending-input card
        /// (the line right after the sentinel), carrying a JSON tail like
        /// `[[conduit:resolved]]{"answered":true,"answer":"Merge now"}`.
        /// Byte-identical to the broker's `pendingResolvedMarker`. The card
        /// rehydrates its answered/selected state from this on reopen — that
        /// state used to live only in ephemeral SwiftUI @State and was lost
        /// on reload. The marker line is filtered out of the visible question
        /// text by `parsePendingQuestions`.
        static let pendingResolvedMarker = "[[conduit:resolved]]"

        /// The resolution carried by a persisted pending-input card.
        struct PendingResolution: Equatable {
            /// True when the user actually answered (a tap / typed text);
            /// false when the ask timed out or was resolved without input.
            let answered: Bool
            /// The chosen option text (nil for a timed-out / no-answer
            /// resolution). Drives "Sent · <answer>" + the selected-row
            /// highlight after reopen.
            let answer: String?
        }

        /// Strip the control lines (`pendingInputSentinel` and any
        /// `pendingResolvedMarker`-prefixed line) from a pending-input card's
        /// content, then trim whitespace. The result is a normalized key that
        /// is identical for the original (marker-free) and the resolved
        /// (marker-carrying) versions of the same card, so dedup can collapse
        /// them to one logical prompt.
        static func pendingInputStrippedKey(_ content: String) -> String {
            content
                .components(separatedBy: "\n")
                .filter {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return t != pendingInputSentinel && !t.hasPrefix(pendingResolvedMarker)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Decode the resolution from a persisted pending-input card's
        /// content by scanning for the `pendingResolvedMarker` line. Returns
        /// nil when no marker is present — an unanswered card, or a legacy
        /// transcript written before this feature (backward-compatible: such
        /// a card renders unanswered exactly as before). Mirrors the broker's
        /// `parsePendingResolution`.
        static func parsePendingResolution(_ content: String) -> PendingResolution? {
            for rawLine in content.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(pendingResolvedMarker) else { continue }
                let json = String(line.dropFirst(pendingResolvedMarker.count))
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                let answered = (obj["answered"] as? Bool) ?? false
                let answer = (obj["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return PendingResolution(answered: answered, answer: answer)
            }
            return nil
        }

        /// Recover per-question groups from a pending-input `content` body.
        /// Blocks are separated by blank lines; within a block the leading
        /// prose is the question and the numbered/bulleted lines are its
        /// options. A trailing multi-select marker on the prompt is
        /// stripped into `multiSelect`. Pure + unit-tested.
        static func parsePendingQuestions(_ content: String) -> [PendingQuestion] {
            // Defensively drop the broker sentinel line AND the resolution
            // marker line if either survived to the client (core strips both
            // on the typed/live path; the HTTP-rehydration path keeps the
            // marker so the card's answered state can be recovered — but the
            // marker must never render as visible question prose).
            let content = content
                .components(separatedBy: "\n")
                .filter {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return t != pendingInputSentinel && !t.hasPrefix(pendingResolvedMarker)
                }
                .joined(separator: "\n")
            var result: [PendingQuestion] = []
            for block in content.components(separatedBy: "\n\n") {
                var prompt: [String] = []
                var options: [String] = []
                for rawLine in block.components(separatedBy: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }
                    if let opt = optionText(line) {
                        options.append(opt)
                    } else if options.isEmpty {
                        prompt.append(line)
                    }
                    // Stray prose AFTER options started is dropped — the
                    // broker never emits it for AskUserQuestion.
                }
                var promptText = prompt.joined(separator: "\n")
                var multi = false
                if promptText.hasSuffix(Self.multiSelectMarker) {
                    multi = true
                    promptText = String(promptText.dropLast(Self.multiSelectMarker.count))
                        .trimmingCharacters(in: .whitespaces)
                }
                if !options.isEmpty || !promptText.isEmpty {
                    result.append(PendingQuestion(
                        prompt: promptText, options: options, multiSelect: multi
                    ))
                }
            }
            return result
        }

        /// Strip a numbered (`1.`/`1)`) or bulleted (`-`/`*`) option marker,
        /// returning the option text, or nil when the line isn't an option.
        private static func optionText(_ line: String) -> String? {
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            var idx = line.startIndex
            var sawDigit = false
            while idx < line.endIndex, line[idx].isNumber {
                sawDigit = true
                idx = line.index(after: idx)
            }
            guard sawDigit, idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return nil }
            let after = line.index(after: idx)
            guard after < line.endIndex, line[after] == " " else { return nil }
            let text = String(line[after...]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }

        /// Drop a plain message echo of a pending-input question — the
        /// interactive card already shows it, so the duplicate is noise
        /// (#5). Conservative: only drops a non-pending item whose content
        /// equals, or is fully contained in, a pending-input body. The
        /// length floor avoids matching trivial strings.
        static func dropPendingInputEchoes(_ items: [ConversationItem]) -> [ConversationItem] {
            // First collapse duplicate pending_input cards (#R4-4): the same
            // AskUserQuestion can arrive twice (typed log + raw chatLog, or a
            // re-emit) and render as two identical "NEEDS YOUR INPUT" cards.
            // Two pending_input items with the same prompt text AND the same
            // options are one logical prompt; keep the first, drop the rest.
            // Different prompt text or different options stays distinct so two
            // legitimately different questions are never merged.
            let deduped = dedupePendingInputCards(items)
            // Build the body set using STRIPPED keys so a resolved-marker card
            // and its plain echo both match the same normalized body, preventing
            // the raw marker text from surviving as a visible plain bubble.
            let pending = deduped
                .filter { $0.kind == "pending_input" }
                .map { pendingInputStrippedKey($0.content) }
                .filter { $0.count >= 8 }
            // Build the set of all individual options from pending_input cards so
            // short answers like "Yes" / "1" are also suppressed (the 8-char floor
            // below would let them through as bare echoes of the broker's appendUser).
            let pendingOptionSet = Set(deduped
                .filter { $0.kind == "pending_input" }
                .flatMap { $0.pendingOptions }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
            guard !pending.isEmpty || !pendingOptionSet.isEmpty else { return deduped }
            return deduped.filter { item in
                if item.kind == "pending_input" { return true }
                let c = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Exact option match: drop regardless of length floor (covers short
                // answers like "Yes", "No", "1" that appendUser writes to conversation.jsonl).
                if item.role.lowercased() == "user" && pendingOptionSet.contains(c) { return false }
                guard c.count >= 8 else { return true }
                return !pending.contains { $0 == c || $0.contains(c) }
            }
        }

        /// Collapse consecutive-or-not duplicate `pending_input` items that
        /// share the same stripped prompt + options to a single card. Order is
        /// preserved (the survivor occupies the FIRST occurrence's position).
        /// Among duplicates the RESOLVED card (one whose content carries a
        /// `parsePendingResolution` result) wins over the raw/unanswered
        /// original, so the answered state is never lost. When no duplicate
        /// exists the lone card is kept as-is. Distinct prompts (different
        /// stripped content or different options) are never merged.
        static func dedupePendingInputCards(_ items: [ConversationItem]) -> [ConversationItem] {
            // Two-pass: first find the winning item per key, then rebuild the
            // list in order, emitting the winner at the first position seen.
            var winner: [String: ConversationItem] = [:]  // key -> surviving item

            for item in items {
                guard item.kind == "pending_input" else { continue }
                let key = pendingInputStrippedKey(item.content)
                    + "\u{1f}"
                    + item.pendingOptions.sorted().joined(separator: "\u{1f}")
                if winner[key] == nil {
                    winner[key] = item
                } else if parsePendingResolution(item.content) != nil
                           && parsePendingResolution(winner[key]!.content) == nil {
                    // Upgrade: the resolved card beats the unanswered original.
                    winner[key] = item
                }
            }

            var emittedKeys: Set<String> = []
            var collapsed = 0
            let result = items.compactMap { item -> ConversationItem? in
                guard item.kind == "pending_input" else { return item }
                let key = pendingInputStrippedKey(item.content)
                    + "\u{1f}"
                    + item.pendingOptions.sorted().joined(separator: "\u{1f}")
                if emittedKeys.contains(key) {
                    collapsed += 1
                    return nil
                }
                emittedKeys.insert(key)
                return winner[key]
            }
            if collapsed > 0 {
                Telemetry.breadcrumb(
                    "chat", "pending_input dedup collapsed",
                    data: ["count": "\(collapsed)"]
                )
            }
            return result
        }

        static func mergedEvents(
            conversation: [ConversationItem],
            chatLog: [ChatEvent]
        ) -> [ConversationItem] {
            let conversation = conversation.filter { !isUploadToolEvent($0) }
            // Fast path: nothing raw to fold in.
            guard !chatLog.isEmpty else { return dropPendingInputEchoes(conversation) }

            // Same fingerprint shape `refreshConversation` uses to dedupe
            // local echoes against the server's typed log — role+content
            // is the only stable identity we get from `ChatEvent`.
            let typedFingerprints = Set(
                conversation.map { "\($0.role.lowercased())|\($0.content)" }
            )
            // Track keys seen within the chatLog itself to deduplicate
            // repeated replays of the same resolved entry (each WS reconnect
            // replays the transcript, appending another copy).
            var seenChatLogKeys = Set<String>()
            let synthetic: [ConversationItem] = chatLog.enumerated().compactMap { idx, ev in
                // Strip only the needs-input sentinel from content (for display),
                // but use pendingInputStrippedKey (strips BOTH sentinel AND
                // resolved marker) for the dedup fingerprint. This makes a
                // resolved chatLog entry ("[[conduit:needs-input]]\n[[conduit:resolved]]{...}\ntext")
                // match the typed conversationLog item ("text") that core has
                // already double-stripped, preventing a raw resolved-marker
                // bubble from appearing on each WS reconnect.
                let strippedContent = SessionStore.stripPendingSentinel(ev.content)
                let key = "\(ev.role.lowercased())|\(ChatViewModel.pendingInputStrippedKey(ev.content))"
                if typedFingerprints.contains(key) { return nil }
                guard seenChatLogKeys.insert(key).inserted else { return nil }
                let isPendingInput = ev.content.contains(ChatViewModel.pendingInputSentinel)
                return ConversationItem(
                    id: "chatlog-\(ev.ts)-\(idx)",
                    role: ev.role,
                    kind: ev.role.lowercased() == "tool" ? "tool" : (isPendingInput ? "pending_input" : "message"),
                    status: "done",
                    content: strippedContent,
                    ts: ev.ts,
                    files: ev.files,
                    toolName: nil,
                    command: nil,
                    exitCode: nil,
                    durationMs: nil,
                    diffSummary: nil,
                    pendingOptions: isPendingInput ? ConversationRenderer.extractPendingOptions(from: strippedContent) : [],
                    sourceAgent: nil,
                    targetAgent: nil,
                    taskText: nil,
                    resultSummary: nil,
                    planSteps: []
                )
            }
            .filter { !isUploadToolEvent($0) }
            guard !synthetic.isEmpty else { return dropPendingInputEchoes(conversation) }
            // Sort by ts (PR #111 contract — typed log is ts-sorted).
            // Epoch-normalized (not raw String): a `+09:00` offset or a
            // fractional-second mismatch would otherwise mis-sort, and an
            // empty live `ts` must stay newest. Mirrors Android
            // `sortedByConversationTs`.
            return dropPendingInputEchoes(
                (conversation + synthetic).sortedByConversationTs { $0.ts }
            )
        }

        /// Fold an event list into rows, collapsing a contiguous run of
        /// `minRun`+ groupable tool events into one `.toolGroup`. Runs are
        /// broken by any non-groupable event, preserving interleaving. Pure
        /// (the "is this a groupable tool?" decision is injected) so it's
        /// unit-testable without the SwiftUI tool classifier.
        static func groupedRows(
            _ events: [ConversationItem],
            minRun: Int = 3,
            isGroupableTool: (ConversationItem) -> Bool
        ) -> [ChatRow] {
            var rows: [ChatRow] = []
            var run: [ConversationItem] = []

            func flush() {
                if run.count >= minRun {
                    rows.append(.toolGroup(run))
                } else {
                    rows.append(contentsOf: run.map { .single($0) })
                }
                run.removeAll(keepingCapacity: true)
            }

            for event in events {
                if isGroupableTool(event) {
                    run.append(event)
                } else {
                    flush()
                    rows.append(.single(event))
                }
            }
            flush()
            return rows
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
            isStreaming: Bool,
            serverTurnActive: Bool? = nil
        ) -> Bool {
            if isStreaming { return true }
            // Authoritative broker signal (status frame `turn_active`): for a
            // structured-chat session the broker tells us exactly whether a
            // turn is in flight, so trust it over the log-role heuristic
            // below. This is what clears a stuck indicator on reconnect when
            // the trailing log item is still the user's prompt (the turn
            // finished while the app was backgrounded), and what keeps it on
            // when a turn really is running. `nil` = legacy TUI-scrape session
            // or a pre-field broker → fall through to the inference.
            // (`isStreaming` already won above as the lower-latency signal.)
            if let serverTurnActive { return serverTurnActive }
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
