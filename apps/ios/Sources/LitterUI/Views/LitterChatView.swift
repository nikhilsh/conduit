import SwiftUI

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

        let session: ProjectSession

        @State private var draft: String = ""
        @State private var showVoiceDictation = false
        @FocusState private var composerFocused: Bool

        var body: some View {
            // Composer is hosted via `.safeAreaInset(edge: .bottom)` so
            // SwiftUI lifts it above the soft keyboard (and the home
            // indicator at rest) while the messages scroll view shrinks
            // accordingly — the last message stays visible above both
            // the composer and the keyboard. Previously the composer
            // was a sibling VStack child, which on this navigation
            // stack let the keyboard cover it.
            messagesList
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        suggestionBar
                        composer
                    }
                }
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
            // PR #111 + legacy ChatTab parity: prefer the typed
            // `conversationLog`, but fall back to the broker's raw
            // `chatLog` for events that haven't surfaced through the
            // structured `view_event` stream yet. Without this, codex
            // assistant replies (delivered via `on_chat_event`) showed
            // up in the Terminal tab but never reached the chat tab —
            // the #119 cutover dropped the legacy mapIndexed fallback.
            LitterUI.ChatViewModel.mergedEvents(
                conversation: store.conversationLog[session.id] ?? [],
                chatLog: store.chatLog[session.id] ?? []
            )
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
                    }
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: events.last?.id) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(newID, anchor: .bottom)
                        }
                    }
                }
            }
        }

        // MARK: Suggested quick-replies

        /// Up to 3 contextual chips inferred from the agent's latest
        /// message — only when the agent just spoke (it's the user's
        /// turn). Distinct from the agent's explicit pending-input
        /// options (`LitterPendingInputCard` owns those), so we bail
        /// when the last event carries `pendingOptions`.
        private var suggestedReplies: [String] {
            guard let last = events.last,
                  last.role.lowercased() == "assistant",
                  last.pendingOptions.isEmpty else { return [] }
            let kind = last.kind.lowercased()
            guard kind == "message" || kind.isEmpty else { return [] }
            // Don't suggest mid-stream — wait for the turn to settle.
            let status = last.status.lowercased()
            guard !["streaming", "working", "thinking", "pending"].contains(status) else { return [] }
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
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
            }
        }

        // MARK: Composer

        private var composer: some View {
            HStack(spacing: 8) {
                Button {
                    // attach — wired in follow-up.
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

                let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(LitterUI.Palette.brand.color)
                    }
                    .buttonStyle(.plain)
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
                    LitterMarkdownBlock(
                        text: text,
                        role: role,
                        itemID: idx == 0 ? itemID : nil
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
    var itemID: String? = nil

    @Environment(AppearanceStore.self) private var appearance
    @Environment(StreamingRendererCoordinator.self) private var coordinator

    private func revision(for content: String) -> Int {
        // Re-render when the user changes their body-size slider — the
        // attributed cache stores absolute font sizes (PR 4 heading
        // scale) so the cache key has to vary with the size.
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(appearance.bodyPointSize)
        hasher.combine(appearance.fontFamily.rawValue)
        return hasher.finalize()
    }

    private func attributed(for content: String) -> AttributedString {
        if let id = itemID {
            let rev = revision(for: content)
            if let hit = MessageRenderCache.shared.get(itemID: id, revision: rev) {
                return hit
            }
            let parsed = parseAndScale(content)
            MessageRenderCache.shared.set(itemID: id, revision: rev, value: parsed)
            return parsed
        }
        return parseAndScale(content)
    }

    private func parseAndScale(_ content: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(content)
        LitterMarkdownHeadingScaler.apply(
            to: &attr,
            basePointSize: appearance.bodyPointSize,
            design: SweKittyTypography.design(for: appearance.fontFamily)
        )
        return attr
    }

    private var displayedText: String {
        guard let id = itemID else { return text }
        switch coordinator.renderState(for: id) {
        case .streaming(let buffer):
            return buffer
        case .idle, .complete:
            return text
        }
    }

    private var isStreaming: Bool {
        guard let id = itemID else { return false }
        if case .streaming = coordinator.renderState(for: id) {
            return true
        }
        return false
    }

    var body: some View {
        let content = displayedText
        // Outer `.font` now picks up `bodyPointSize` (PR 1 slider) via
        // `SweKittyTypography.body(appearance)`. The attributed string
        // itself carries per-run overrides for headings via
        // `LitterMarkdownHeadingScaler`, so this base only applies to
        // body / paragraph runs and the larger header sizes win.
        return Text(attributed(for: content))
            .font(SweKittyTypography.body(appearance))
            .foregroundStyle(foregroundForRole)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: role == .user ? nil : .infinity, alignment: role == .user ? .trailing : .leading)
            .transition(isStreaming ? .opacity : .identity)
            .animation(isStreaming ? .easeOut(duration: 0.05) : nil, value: content)
    }

    private var foregroundForRole: Color {
        switch role {
        case .user:      return LitterUI.Palette.brand.color
        case .system:    return LitterUI.Palette.textSecondary.color
        default:         return LitterUI.Palette.textBody.color
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
    @State private var expanded = true

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
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(LitterUI.Palette.textBody.color)
                        .lineLimit(1)
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
