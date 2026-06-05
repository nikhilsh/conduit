import Foundation

// MARK: - ConduitDiffReviewModel
//
// Pure-data view model for the Diff review → commit / PR surface
// (handoff §B.6). Everything here is string-in / value-out so it can be
// unit-tested without SwiftUI.
//
// HONEST DATA NOTE — what the core actually exposes for diffs:
//   • `ProjectSession.linesAdded` / `linesRemoved` / `commits` / `prNumber`
//     / `prState` — session-level rollups (UInt32?/String?).
//   • A `ConversationItem` with `kind == "diff"` carries the *raw unified
//     diff text* in `content` (the core's `looks_like_diff` only tags an
//     item "diff" when the text has `@@` / `diff --git` / `+`-lines), plus
//     a pre-computed `diffSummary` like "2 files, +12 -3".
//   • `ConversationItem.files` is `[ViewEventFile]` = `(path, rev)` ONLY —
//     there is **no per-file +/- count field** in the bindings.
//
// So per-file +/- and the inline diff body are recovered by *parsing the
// real `content` patch text* (`parsePatch`), never fabricated. When a
// session has changed lines (`linesAdded`/`linesRemoved`) but no parseable
// `diff` conversation item is present, we render the summary bar + a
// "open in chat for full diff" note rather than inventing hunks.

extension ConduitUI {

    /// One file inside a parsed unified diff.
    struct DiffFile: Equatable, Identifiable {
        var id: String { path }
        var path: String
        var added: Int
        var removed: Int
        /// Inline body lines (hunk headers + context + +/- lines), in order.
        /// Empty when only a per-file header was recovered (no hunk body).
        var lines: [DiffLine]
    }

    /// A single rendered diff line with its kind, for mono +green/−red render.
    struct DiffLine: Equatable, Identifiable {
        enum Kind: Equatable { case added, removed, context, hunk, meta }
        let index: Int
        var id: Int { index }
        var kind: Kind
        var text: String
    }

    /// Summary bar model: `N files · +added −removed` + stacked-bar fractions.
    struct DiffSummary: Equatable {
        var fileCount: Int
        var added: Int
        var removed: Int

        /// Fraction of the add/del bar that is green (additions). 0.5 when
        /// both are zero so the bar renders as a neutral half-split rather
        /// than collapsing. Always in 0...1.
        var addedFraction: Double {
            let total = added + removed
            guard total > 0 else { return 0.5 }
            return Double(added) / Double(total)
        }

        /// `+162 −39` — mono, en-dash minus to match the brand numerals.
        var deltaLabel: String { "+\(added) −\(removed)" }

        /// `4 files` / `1 file`.
        var fileCountLabel: String { "\(fileCount) file\(fileCount == 1 ? "" : "s")" }
    }

    enum DiffReviewModel {

        /// Pull the most recent `kind == "diff"` conversation item and parse
        /// its patch text into per-file groups. Returns `[]` when no diff item
        /// is present (caller then shows the summary-only fallback).
        static func files(from log: [ConversationItem]) -> [DiffFile] {
            guard let latest = log.last(where: { $0.kind == "diff" }) else { return [] }
            return parsePatch(latest.content)
        }

        /// Whether the conversation carries a parseable inline diff at all.
        static func hasInlineDiff(in log: [ConversationItem]) -> Bool {
            log.contains { $0.kind == "diff" }
        }

        /// Build the summary bar. Prefers parsed per-file totals (most precise
        /// — counts the actual +/- lines); falls back to the session-level
        /// `linesAdded` / `linesRemoved` rollup, and the file count to the
        /// distinct file paths seen across diff items.
        static func summary(
            session: ProjectSession,
            files: [DiffFile],
            log: [ConversationItem]
        ) -> DiffSummary {
            if !files.isEmpty {
                return DiffSummary(
                    fileCount: files.count,
                    added: files.reduce(0) { $0 + $1.added },
                    removed: files.reduce(0) { $0 + $1.removed }
                )
            }
            // No parsed body — use the session rollup + distinct file paths.
            let paths = Set(
                log.filter { $0.kind == "diff" }.flatMap { $0.files.map(\.path) }
            )
            return DiffSummary(
                fileCount: paths.count,
                added: Int(session.linesAdded ?? 0),
                removed: Int(session.linesRemoved ?? 0)
            )
        }

        /// Parse unified-diff text into per-file groups. Splits on
        /// `diff --git a/… b/…` headers (git's per-file marker); also handles
        /// bare `+++ b/path` headers when no `diff --git` line is present.
        /// Counts `+`/`-` body lines (excluding `+++`/`---` file markers).
        static func parsePatch(_ patch: String) -> [DiffFile] {
            var files: [DiffFile] = []
            var current: DiffFile?
            var lineIdx = 0

            func flush() {
                if let c = current { files.append(c) }
                current = nil
            }

            for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.hasPrefix("diff --git ") {
                    flush()
                    current = DiffFile(path: pathFromGitHeader(line), added: 0, removed: 0, lines: [])
                    lineIdx = 0
                    continue
                }
                // A `+++ b/path` with no preceding `diff --git` starts a file.
                if line.hasPrefix("+++ ") {
                    if current == nil {
                        current = DiffFile(path: pathFromTripleHeader(line), added: 0, removed: 0, lines: [])
                        lineIdx = 0
                    } else if current?.path.isEmpty == true {
                        current?.path = pathFromTripleHeader(line)
                    }
                    appendLine(&current, kind: .meta, text: line, idx: &lineIdx)
                    continue
                }
                if line.hasPrefix("--- ") {
                    appendLine(&current, kind: .meta, text: line, idx: &lineIdx)
                    continue
                }
                if line.hasPrefix("@@") {
                    appendLine(&current, kind: .hunk, text: line, idx: &lineIdx)
                    continue
                }
                if line.hasPrefix("+") {
                    current?.added += 1
                    appendLine(&current, kind: .added, text: line, idx: &lineIdx)
                    continue
                }
                if line.hasPrefix("-") {
                    current?.removed += 1
                    appendLine(&current, kind: .removed, text: line, idx: &lineIdx)
                    continue
                }
                // index / similarity / mode lines, and plain context.
                if line.hasPrefix("index ") || line.hasPrefix("new file")
                    || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                    || line.hasPrefix("rename ") {
                    appendLine(&current, kind: .meta, text: line, idx: &lineIdx)
                    continue
                }
                appendLine(&current, kind: .context, text: line, idx: &lineIdx)
            }
            flush()
            // Drop a leading empty-path file with no signal (defensive).
            return files.filter { !($0.path.isEmpty && $0.added == 0 && $0.removed == 0 && $0.lines.isEmpty) }
        }

        private static func appendLine(
            _ file: inout DiffFile?,
            kind: DiffLine.Kind,
            text: String,
            idx: inout Int
        ) {
            guard file != nil else { return }
            file?.lines.append(DiffLine(index: idx, kind: kind, text: text))
            idx += 1
        }

        /// `diff --git a/src/x.ts b/src/x.ts` → `src/x.ts` (prefers the b-side).
        static func pathFromGitHeader(_ line: String) -> String {
            let parts = line
                .dropFirst("diff --git ".count)
                .split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return "" }
            return stripABPrefix(String(parts[1]))
        }

        /// `+++ b/src/x.ts` → `src/x.ts`. Trims a trailing tab-timestamp.
        static func pathFromTripleHeader(_ line: String) -> String {
            var rest = String(line.dropFirst("+++ ".count))
            if let tab = rest.firstIndex(of: "\t") { rest = String(rest[..<tab]) }
            return stripABPrefix(rest)
        }

        private static func stripABPrefix(_ s: String) -> String {
            if s.hasPrefix("a/") || s.hasPrefix("b/") { return String(s.dropFirst(2)) }
            return s
        }
    }
}
