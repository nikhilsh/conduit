import Foundation

// MARK: - LitterConversationRenderer
//
// Block-level tokenizer for assistant/tool message bodies. Splits
// fenced code blocks out of markdown, collapses runs of command-shaped
// lines into a "Ran N steps" chevron, and exposes a typed
// `ToolSection` enum for the tool-card composer.
//
// Extracted verbatim from the legacy `Views/ConversationView.swift`
// (PR #69) so the LitterChatView can drive the same markdown layout
// without dragging the legacy SwiftUI surface along. Behaviour pinned
// by `ConversationRendererTests`.

enum ConversationBlock: Equatable {
    case markdown(String)
    case code(language: String?, content: String)
    /// Collapsed tool-activity row: chevron + summary label, expands to
    /// the original tool lines. Detected from the assistant's scraped
    /// content by `ConversationRenderer.blocks` when a run of
    /// command-shaped lines appears between two prose paragraphs.
    case toolSummary(label: String, detail: String)
}

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

struct ToolMetadata: Equatable {
    let exitCode: Int?
    let duration: String?
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
            if isToolOutputContinuation(line, hasOpenTool: !tool.isEmpty) {
                tool.append(line)
            } else if isToolLine(line) {
                if !prose.isEmpty { flushProse() }
                tool.append(line)
                toolCount += 1
            } else {
                if !tool.isEmpty { flushTool() }
                prose.append(line)
            }
        }
        flushTool()
        flushProse()
        if result.isEmpty {
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
                let tail = trimmed.dropFirst(v.count)
                let words = tail.split(whereSeparator: { $0.isWhitespace }).count
                if words <= 3 && !tail.contains(". ") {
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

// MARK: - Diff parser

struct ConversationDiffFile: Identifiable {
    let id: String
    let path: String
    let lines: [String]
}

enum ConversationDiffParser {
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

// MARK: - Timestamp helpers

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
