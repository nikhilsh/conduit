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
        @FocusState private var composerFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                messagesList
                composer
            }
        }

        // MARK: Messages

        private var events: [ConversationItem] {
            store.conversationLog[session.id] ?? []
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
                .onChange(of: events.last?.id) { _, newID in
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

    private func revision(for content: String) -> Int { content.hashValue }

    private func attributed(for content: String) -> AttributedString {
        if let id = itemID {
            let rev = revision(for: content)
            if let hit = MessageRenderCache.shared.get(itemID: id, revision: rev) {
                return hit
            }
            let parsed = (try? AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )) ?? AttributedString(content)
            MessageRenderCache.shared.set(itemID: id, revision: rev, value: parsed)
            return parsed
        }
        return (try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(content)
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
        return Text(attributed(for: content))
            .font(appearance.bodyFont())
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
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
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
        .litterGlassRoundedRect(cornerRadius: 14, tint: statusTint.opacity(0.20))
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
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(LitterUI.Palette.border.color.opacity(0.55), lineWidth: 0.8)
                )
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.brand.color)
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
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { onQuickReply(option) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .litterGlassCapsule(tint: LitterUI.Palette.brand.color.opacity(0.24), config: .pill)
                                .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litterGlassRoundedRect(cornerRadius: 14, tint: LitterUI.Palette.brand.color.opacity(0.20))
    }
}

private struct LitterHandoffCard: View {
    let event: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.brand.color)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litterGlassRoundedRect(cornerRadius: 14, tint: LitterUI.Palette.brand.color.opacity(0.22))
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
