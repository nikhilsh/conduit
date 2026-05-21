import SwiftUI

/// Renders ISO-8601 timestamps in the conversation bubbles as
/// human-friendly relative strings ("just now", "5m ago") instead
/// of the raw `2026-05-20T14:03:03Z` shape. Falls back to the raw
/// text when the format isn't parseable.
enum ConversationTimestamp {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ rawTimestamp: String) -> String {
        let trimmed = rawTimestamp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard let date = iso.date(from: trimmed) ?? isoNoFrac.date(from: trimmed) else {
            return trimmed
        }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }
}

private enum ConversationRole: Equatable {
    case user
    case assistant
    case tool
    case system

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "user":
            self = .user
        case "assistant":
            self = .assistant
        case "tool":
            self = .tool
        default:
            self = .system
        }
    }

    var icon: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver.fill"
        case .system: return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        case .system: return "System"
        }
    }

    var accent: Color {
        switch self {
        case .user: return SweKittyTheme.accentStrong
        case .assistant: return SweKittyTheme.success
        case .tool: return SweKittyTheme.warning
        case .system: return SweKittyTheme.textSecondary
        }
    }
}

// `ConversationBlock` and `ConversationRenderer` are intentionally
// internal (not `private`) so `apps/ios/Tests/SweKittyTests/...` can
// drive them as pure functions via `@testable import SweKitty`. The
// rest of the file is still file-private; only the parser surface
// area is exposed.

enum ConversationBlock: Equatable {
    case markdown(String)
    case code(language: String?, content: String)
    /// Collapsed tool-activity row: chevron + summary label, expands to
    /// the original tool lines. Detected from the assistant's scraped
    /// content by `ConversationRenderer.blocks` when a run of
    /// command-shaped lines appears between two prose paragraphs.
    case toolSummary(label: String, detail: String)
}

struct ConversationRenderer {
    static func blocks(for content: String) -> [ConversationBlock] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [ConversationBlock] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushMarkdown() {
            let text = markdownLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.markdown(text))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let text = codeLines.joined(separator: "\n")
            if !text.isEmpty {
                blocks.append(.code(language: codeLanguage, content: text))
            }
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                let fence = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushMarkdown()
                    codeLanguage = fence.isEmpty ? nil : fence
                    inCode = true
                }
                continue
            }

            if inCode {
                codeLines.append(line)
            } else {
                markdownLines.append(line)
            }
        }

        if inCode {
            flushCode()
        } else {
            flushMarkdown()
        }

        if blocks.isEmpty {
            blocks = [.markdown(content)]
        }

        return collapseToolRuns(blocks)
    }

    /// Walks an already-tokenized markdown/code stream and groups
    /// consecutive command-shaped lines inside each `.markdown` block
    /// into a single `.toolSummary`. Detection is conservative — we
    /// only collapse when a line clearly matches a tool-call shape so
    /// regular prose with the occasional `$variable` doesn't disappear.
    static func collapseToolRuns(_ blocks: [ConversationBlock]) -> [ConversationBlock] {
        var out: [ConversationBlock] = []
        for block in blocks {
            switch block {
            case .markdown(let text):
                out.append(contentsOf: splitToolRuns(in: text))
            default:
                out.append(block)
            }
        }
        return out
    }

    private static func splitToolRuns(in text: String) -> [ConversationBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [ConversationBlock] = []
        var prose: [String] = []
        var tool: [String] = []
        var toolCount = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.markdown(joined))
            }
            prose.removeAll(keepingCapacity: true)
        }
        func flushTool() {
            guard !tool.isEmpty else { return }
            let detail = tool.joined(separator: "\n")
            let label = toolSummaryLabel(forCount: toolCount)
            result.append(.toolSummary(label: label, detail: detail))
            tool.removeAll(keepingCapacity: true)
            toolCount = 0
        }

        for line in lines {
            if isToolLine(line) {
                if !prose.isEmpty { flushProse() }
                tool.append(line)
                toolCount += 1
            } else if isToolOutputContinuation(line, hasOpenTool: !tool.isEmpty) {
                // Indented output following a tool line — keep it
                // grouped with the same summary instead of breaking
                // out into prose.
                tool.append(line)
            } else {
                if !tool.isEmpty { flushTool() }
                prose.append(line)
            }
        }
        flushTool()
        flushProse()
        if result.isEmpty {
            // No tool lines detected; preserve the original block so
            // we don't lose blank-line spacing the caller may rely on.
            result.append(.markdown(text))
        }
        return result
    }

    /// One-shot heuristic: a line is "tool-shaped" if it starts with a
    /// shell prompt, a recognized verb, or a path-like edit marker.
    private static func isToolLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("$ ") { return true }
        let lower = trimmed.lowercased()
        let verbs = [
            "running ", "ran ", "executing ", "reading ", "read ",
            "writing ", "wrote ", "editing ", "edited ", "listing ",
            "searching ", "checking ", "building ", "testing ",
        ]
        for v in verbs {
            if lower.hasPrefix(v) {
                // Avoid eating mid-sentence prose like "Reading the
                // docs..." — require a path-ish or short follow-up.
                let tail = trimmed.dropFirst(v.count)
                if tail.count < 80 && !tail.contains(". ") {
                    return true
                }
            }
        }
        return false
    }

    /// Lines indented under a tool block (4+ spaces or a tab) are
    /// treated as captured output and stay in the collapsed summary.
    private static func isToolOutputContinuation(_ line: String, hasOpenTool: Bool) -> Bool {
        guard hasOpenTool else { return false }
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return true }
        return false
    }

    private static func toolSummaryLabel(forCount n: Int) -> String {
        // Claude-style chevron label. Count is the number of tool-shaped
        // lines collapsed, not a perfect semantic count — close enough
        // for "skim the activity" reads.
        switch n {
        case 1: return "Ran 1 step"
        default: return "Ran \(n) steps"
        }
    }

    static func toolSections(for event: ConversationItem) -> [ToolSection] {
        var sections: [ToolSection] = []
        let meta = extractMetadata(from: event)
        if meta.exitCode != nil || meta.duration != nil {
            sections.append(.meta(meta))
        }
        if let command = extractCommand(from: event) {
            sections.append(.command(command))
        }

        if !event.files.isEmpty {
            sections.append(.files(event.files))
        }

        let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return sections
        }

        let blocks = blocks(for: trimmed)
        var currentStream: String?
        for block in blocks {
            switch block {
            case .markdown(let text):
                let lower = text.lowercased()
                if lower == "stdout:" || lower == "stdout" {
                    currentStream = "stdout"
                    continue
                }
                if lower == "stderr:" || lower == "stderr" {
                    currentStream = "stderr"
                    continue
                }
                if currentStream == "stdout" {
                    sections.append(.stdout(text))
                    currentStream = nil
                    continue
                }
                if currentStream == "stderr" {
                    sections.append(.stderr(text))
                    currentStream = nil
                    continue
                }
                if looksLikeDiff(text) {
                    sections.append(.diff(text))
                } else {
                    sections.append(.text(text))
                }
            case .code(let language, let content):
                if language == "diff" || looksLikeDiff(content) {
                    sections.append(.diff(content))
                } else {
                    sections.append(.code(language: language, content: content))
                }
            case .toolSummary(_, let detail):
                // Tool-role events already render as a ToolCard with
                // command/stdout/stderr/files; nested tool summaries
                // would just nest a chevron inside that card. Render
                // the expanded detail directly as plain text so the
                // tool card still shows the full context.
                sections.append(.text(detail))
            }
        }
        return sections
    }

    /// Prefer the Rust classifier output where present; fall back to parsing.
    /// Keeps the iOS renderer thin per the Rust-first rule in PLAN-2026-05-19.
    static func extractMetadata(from event: ConversationItem) -> ToolMetadata {
        let fromRust = ToolMetadata(
            exitCode: event.exitCode.map { Int($0) },
            duration: event.durationMs.map { Self.formatDuration($0) }
        )
        if fromRust.exitCode != nil || fromRust.duration != nil {
            return fromRust
        }
        return extractMetadata(from: event.content)
    }

    static func extractCommand(from event: ConversationItem) -> String? {
        if let typed = event.command, !typed.isEmpty {
            return typed
        }
        return extractCommand(from: event.content)
    }

    static func formatDuration(_ ms: UInt64) -> String {
        if ms < 1_000 {
            return "\(ms)ms"
        }
        let seconds = Double(ms) / 1_000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = seconds / 60.0
        return String(format: "%.1fmin", mins)
    }

    static func extractMetadata(from text: String) -> ToolMetadata {
        var exitCode: Int?
        var duration: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("exit code:"),
               let code = Int(line.dropFirst("exit code:".count).trimmingCharacters(in: .whitespaces)) {
                exitCode = code
            } else if lower.hasPrefix("exit="),
                      let code = Int(line.dropFirst("exit=".count).trimmingCharacters(in: .whitespaces)) {
                exitCode = code
            } else if lower.hasPrefix("duration:") {
                duration = String(line.dropFirst("duration:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("took ") {
                duration = String(line.dropFirst("took ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ToolMetadata(exitCode: exitCode, duration: duration)
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return false }
        return lines.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@") })
    }

    static func extractCommand(from text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("$ ") {
                return String(line.dropFirst(2))
            }
            if line.lowercased().hasPrefix("running ") {
                return String(line.dropFirst("running ".count))
            }
            if line.lowercased().hasPrefix("cmd:") {
                return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func extractPendingOptions(from text: String) -> [String] {
        var opts: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !opts.contains(value) { opts.append(value) }
                continue
            }
            if line.lowercased().hasPrefix("option:") {
                let value = String(line.dropFirst("option:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !opts.contains(value) { opts.append(value) }
            }
        }
        return Array(opts.prefix(4))
    }
}

// Promoted from `private` to internal because `ConversationRenderer`
// is now internal (was private — exposed for tests) and its
// `toolSections(...)` returns `[ToolSection]`; Swift requires the
// return type be at least as visible as the method.
enum ToolSection: Equatable {
    case meta(ToolMetadata)
    case command(String)
    case files([ViewEventFile])
    case stdout(String)
    case stderr(String)
    case text(String)
    case code(language: String?, content: String)
    case diff(String)
}

// Same visibility-promotion rationale as `ToolSection` above —
// `ConversationRenderer.extractMetadata(...)` returns this type.
struct ToolMetadata: Equatable {
    let exitCode: Int?
    let duration: String?
}

struct ConversationTimelineView: View {
    let events: [ConversationItem]
    let onQuickReply: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                ConversationEventRow(event: event, onQuickReply: onQuickReply)
                    .id(idx)
            }
        }
    }
}

private struct ConversationEventRow: View {
    let event: ConversationItem
    let onQuickReply: (String) -> Void

    private var role: ConversationRole { ConversationRole(rawValue: event.role) }

    var body: some View {
        if event.kind == "pending_input" {
            ConversationPendingInputCard(event: event, onQuickReply: onQuickReply)
        } else if event.kind == "handoff" {
            ConversationHandoffCard(event: event)
        } else if event.kind == "subagent" {
            ConversationSubagentCard(event: event)
        } else {
            switch role {
            case .user:
                ConversationBubbleContainer(role: role, timestamp: event.ts, alignTrailing: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ConversationBlockStack(blocks: ConversationRenderer.blocks(for: event.content), role: role)
                        if !event.files.isEmpty {
                            ConversationFileStrip(files: event.files)
                        }
                    }
                }
            case .assistant:
                ConversationBubbleContainer(role: role, timestamp: event.ts, alignTrailing: false) {
                    ConversationBlockStack(blocks: ConversationRenderer.blocks(for: event.content), role: role)
                }
            case .tool:
                ConversationToolCard(event: event)
            case .system:
                // System messages aren't conversation — they're
                // metadata (exit codes, link drops, switches). Render
                // as a centered subtle line instead of a bubble.
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                    Text(event.content)
                        .font(.caption.weight(.regular))
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ConversationHandoffCard: View {
    let event: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.accentStrong)
                Text("AGENT HANDOFF")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
            ConversationMarkdownBlock(text: event.content, role: .system)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRect(cornerRadius: 18, tint: SweKittyTheme.accentStrong.opacity(0.22))
    }
}

private struct ConversationSubagentCard: View {
    let event: ConversationItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.warning)
                Text("SUBAGENT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(SweKittyTheme.textSecondary)
                ConversationStatusChip(status: event.status)
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            }
            if expanded {
                ConversationMarkdownBlock(text: event.content, role: .system)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(event.content.split(separator: "\n").first.map(String.init) ?? "Subagent activity")
                    .font(.subheadline)
                    .foregroundStyle(SweKittyTheme.textBody)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRect(cornerRadius: 18, tint: SweKittyTheme.warning.opacity(0.22))
    }
}

private struct ConversationPendingInputCard: View {
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
                    .foregroundStyle(SweKittyTheme.accentStrong)
                Text("INPUT NEEDED")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Spacer()
                ConversationStatusChip(status: event.status)
            }
            ConversationMarkdownBlock(text: event.content, role: .assistant)
            if !options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { onQuickReply(option) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.24))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRect(cornerRadius: 18, tint: SweKittyTheme.accentStrong.opacity(0.20))
    }
}

private struct ConversationBubbleContainer<Content: View>: View {
    let role: ConversationRole
    let timestamp: String
    let alignTrailing: Bool  // ignored — role decides layout now
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Litter's actual conversation pattern (from the generative-UI
        // screenshot): user messages get a SUBTLE light-gray rounded
        // rect right-aligned; assistant messages flow as plain text,
        // full width, no role label, no container. No avatars, no
        // big timestamps — just the text itself. Body uses a
        // monospaced font (codex aesthetic).
        switch role {
        case .user:
            // Claude's iOS chat pattern: a small dark-gray pill, right-
            // aligned, capped near 78% width via a leading gutter. The
            // previous copper-tinted bubble drew the eye too much for
            // what's typically a short prompt; muting it keeps the
            // assistant's flow as the focal point of the transcript.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SweKittyTheme.surfaceLight)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
        case .assistant:
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool, .system:
            // These are rendered by dedicated branches; this fallback
            // shouldn't normally hit, but stays safe.
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConversationBlockStack: View {
    let blocks: [ConversationBlock]
    let role: ConversationRole

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    ConversationMarkdownBlock(text: text, role: role)
                case .code(let language, let content):
                    ConversationCodeBlock(language: language, content: content)
                case .toolSummary(let label, let detail):
                    ConversationToolSummaryBlock(label: label, detail: detail)
                }
            }
        }
    }
}

/// Claude-style collapsed chevron row that hides a chunk of tool
/// activity behind a single tap. Tap reveals the raw lines verbatim;
/// no extra formatting (the scraper has already stripped ANSI).
private struct ConversationToolSummaryBlock: View {
    let label: String
    let detail: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textSecondary)
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SweKittyTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(SweKittyTheme.textBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ConversationMarkdownBlock: View {
    let text: String
    let role: ConversationRole
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        // Body font picked from AppearanceStore — defaults to monospaced
        // (litter / codex aesthetic) but the user can flip to system in
        // Settings → Font.
        .font(appearance.bodyFont())
        .foregroundStyle(foregroundForRole)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: role == .user ? nil : .infinity, alignment: .leading)
    }

    private var foregroundForRole: Color {
        switch role {
        case .user: return SweKittyTheme.textPrimary
        case .system: return SweKittyTheme.textSecondary
        default: return SweKittyTheme.textBody
        }
    }
}

private struct ConversationCodeBlock: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SweKittyTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SweKittyTheme.border.opacity(0.55), lineWidth: 0.8)
        )
    }
}

private struct ConversationToolCard: View {
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
                            .foregroundStyle(SweKittyTheme.textSecondary)
                        ConversationStatusChip(status: event.status)
                        if let diffSummary = event.diffSummary, !diffSummary.isEmpty {
                            Text(diffSummary.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(SweKittyTheme.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(SweKittyTheme.surface.opacity(0.65))
                                .clipShape(Capsule())
                        }
                    }
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(SweKittyTheme.textBody)
                        .lineLimit(1)
                }
                Spacer()
                if !event.ts.isEmpty {
                    Text(ConversationTimestamp.relative(event.ts))
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        switch section {
                        case .meta(let meta):
                            ConversationToolMetaBlock(meta: meta)
                        case .command(let command):
                            ConversationCommandBlock(command: command)
                        case .files(let files):
                            ConversationFileStrip(files: files)
                        case .stdout(let text):
                            ConversationLabeledOutputBlock(title: "STDOUT", text: text)
                        case .stderr(let text):
                            ConversationLabeledOutputBlock(title: "STDERR", text: text)
                        case .text(let text):
                            ConversationMarkdownBlock(text: text, role: .tool)
                        case .code(let language, let content):
                            ConversationCodeBlock(language: language, content: content)
                        case .diff(let diff):
                            ConversationDiffBlock(content: diff)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRect(cornerRadius: 18, tint: statusTint.opacity(0.24))
    }

    private var statusTint: Color {
        switch event.status.lowercased() {
        case "running":
            return SweKittyTheme.warning
        case "pending":
            return SweKittyTheme.accentStrong
        case "failed":
            return SweKittyTheme.danger
        default:
            return SweKittyTheme.success
        }
    }
}

private struct ConversationCommandBlock: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationSectionLabel(title: "COMMAND")
            Text(command)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(SweKittyTheme.surface.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct ConversationToolMetaBlock: View {
    let meta: ToolMetadata

    var body: some View {
        HStack(spacing: 8) {
            if let code = meta.exitCode {
                Text("EXIT \(code)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(code == 0 ? SweKittyTheme.success : SweKittyTheme.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((code == 0 ? SweKittyTheme.success : SweKittyTheme.danger).opacity(0.18))
                    .clipShape(Capsule())
            }
            if let duration = meta.duration, !duration.isEmpty {
                Text("DURATION \(duration)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SweKittyTheme.surface.opacity(0.65))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConversationLabeledOutputBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationSectionLabel(title: title)
            ConversationCodeBlock(language: nil, content: text)
        }
    }
}

private struct ConversationStatusChip: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
    }

    private var label: String { status.isEmpty ? "DONE" : status.uppercased() }

    private var background: Color {
        switch status.lowercased() {
        case "running":
            return SweKittyTheme.warning.opacity(0.20)
        case "pending":
            return SweKittyTheme.accentStrong.opacity(0.20)
        case "failed":
            return SweKittyTheme.danger.opacity(0.20)
        default:
            return SweKittyTheme.success.opacity(0.20)
        }
    }

    private var foreground: Color {
        switch status.lowercased() {
        case "running":
            return SweKittyTheme.warning
        case "pending":
            return SweKittyTheme.accentStrong
        case "failed":
            return SweKittyTheme.danger
        default:
            return SweKittyTheme.success
        }
    }
}

private struct ConversationSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(SweKittyTheme.textSecondary)
    }
}

private struct ConversationFileStrip: View {
    let files: [ViewEventFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationSectionLabel(title: "FILES")
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.accentStrong)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(SweKittyTheme.textBody)
                            .lineLimit(2)
                        if !file.rev.isEmpty {
                            Text("@\(file.rev.prefix(7))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(SweKittyTheme.textMuted)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(SweKittyTheme.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

private struct ConversationDiffBlock: View {
    let content: String
    @State private var expandedFileIDs: Set<String> = []

    var body: some View {
        let files = ConversationDiffParser.files(from: content)
        VStack(alignment: .leading, spacing: 8) {
            ConversationSectionLabel(title: "DIFF")
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
                                .foregroundStyle(SweKittyTheme.textSecondary)
                            Text(file.path)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textBody)
                            Spacer()
                            Text("\(file.lines.count) lines")
                                .font(.caption2)
                                .foregroundStyle(SweKittyTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedFileIDs.contains(file.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
                .background(SweKittyTheme.surface.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SweKittyTheme.border.opacity(0.55), lineWidth: 0.8)
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
        if line.hasPrefix("+") {
            return SweKittyTheme.success
        }
        if line.hasPrefix("-") {
            return SweKittyTheme.danger
        }
        if line.hasPrefix("@@") {
            return SweKittyTheme.warning
        }
        return SweKittyTheme.textBody
    }
}

private struct ConversationDiffFile: Identifiable {
    let id: String
    let path: String
    let lines: [String]
}

private enum ConversationDiffParser {
    static func files(from content: String) -> [ConversationDiffFile] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [ConversationDiffFile] = []
        var currentPath = "patch.diff"
        var bucket: [String] = []

        func flush() {
            if !bucket.isEmpty {
                files.append(ConversationDiffFile(id: "\(currentPath)-\(files.count)", path: currentPath, lines: bucket))
                bucket.removeAll(keepingCapacity: true)
            }
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = parsePath(from: line)
                bucket.append(line)
                continue
            }
            bucket.append(line)
        }
        flush()
        return files.isEmpty ? [ConversationDiffFile(id: "patch", path: "patch.diff", lines: lines)] : files
    }

    private static func parsePath(from diffLine: String) -> String {
        let parts = diffLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return "patch.diff" }
        let raw = String(parts[3])
        if raw.hasPrefix("b/") {
            return String(raw.dropFirst(2))
        }
        return raw
    }
}
