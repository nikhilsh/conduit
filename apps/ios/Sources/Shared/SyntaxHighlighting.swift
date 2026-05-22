import SwiftUI
#if canImport(HighlightSwift)
import HighlightSwift
#endif

/// Pure-function language detection used by the code-block and diff
/// renderers in `ConversationView`. Bridges Markdown fence info
/// strings (`” swift" → "swift"`) and file-extension hints
/// (`foo.swift` → "swift") to canonical highlight.js language ids.
///
/// Lives separately from any UI code so `SyntaxHighlightingTests`
/// can exercise it with zero SwiftUI dependencies — and so the
/// rendering integration with HighlightSwift can ship as a follow-up
/// without touching the detector contract.
///
/// Why this is a separate file instead of inline in
/// `ConversationView.swift`: PLAN-2026-05-19 calls out "Code block
/// view with syntax highlighting (HighlightSwift on iOS, Prism4j on
/// Android — same libraries litter uses)" as the v1 conversation
/// parity gap. Shipping the detector first lets the Rust core's
/// classifier reuse the same canonical id set (e.g. `"ts" -> "typescript"`)
/// without anyone having to read the fenced-code branch in
/// `ConversationRenderer.blocks(for:)`.
enum SyntaxLanguage {
    /// Languages we explicitly recognize. Anything else falls back to
    /// monospace plain text in the renderer. The set tracks litter's
    /// `HighlightSwift` configuration: the highlight.js core langs
    /// plus the ones our agent traffic actually carries (Swift / Go /
    /// Kotlin / Rust / Python / TS / JS / Markdown).
    static let supported: Set<String> = [
        "swift", "go", "kotlin", "rust", "python", "typescript",
        "javascript", "markdown", "bash", "shell", "json", "yaml",
        "html", "css", "java", "c", "cpp", "objectivec", "ruby",
        "sql", "toml", "xml", "diff",
    ]

    /// Resolve a Markdown fence info string into a canonical language
    /// id. Returns nil for empty / unrecognized fences (caller falls
    /// back to plain monospace).
    ///
    /// Strips fence-suffix metadata too: GitHub-style
    /// ` ```swift title=Foo.swift` is common in the wild; we keep
    /// only the first whitespace-separated token before normalizing.
    ///
    /// Examples:
    ///   `fromFence("swift")`         → `"swift"`
    ///   `fromFence("TS")`            → `"typescript"`
    ///   `fromFence("ts title=Foo")`  → `"typescript"`
    ///   `fromFence("")`              → `nil`
    ///   `fromFence("brainfuck")`     → `nil`
    static func fromFence(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        return normalize(head)
    }

    /// Pick a language id from a file path's extension. Used by the
    /// diff renderer so `foo.swift` lines pick up Swift highlighting.
    /// Returns nil when there's no extension or the extension isn't
    /// in our supported set.
    ///
    /// Strips leading `a/` / `b/` git-diff prefixes so a path like
    /// `b/apps/ios/Sources/Foo.swift` still resolves to "swift".
    static func fromPath(_ path: String) -> String? {
        let stripped: String
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            stripped = String(path.dropFirst(2))
        } else {
            stripped = path
        }
        guard let dot = stripped.lastIndex(of: ".") else { return nil }
        let ext = String(stripped[stripped.index(after: dot)...]).lowercased()
        return normalize(ext)
    }

    /// Lowercase + alias-collapse to the canonical highlight.js id.
    /// Public so callers can normalize whatever language hint they
    /// already have (e.g. a Rust-side classifier output) without
    /// re-implementing the alias table.
    static func normalize(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let canonical: String
        switch lower {
        case "ts", "tsx":         canonical = "typescript"
        case "js", "jsx", "mjs":  canonical = "javascript"
        case "py":                canonical = "python"
        case "rs":                canonical = "rust"
        case "kt", "kts":         canonical = "kotlin"
        case "md", "markdown":    canonical = "markdown"
        case "sh", "zsh":         canonical = "bash"
        case "yml":               canonical = "yaml"
        case "hpp", "cc", "cxx":  canonical = "cpp"
        case "h":                 canonical = "c"
        case "mm", "m":           canonical = "objectivec"
        case "rb":                canonical = "ruby"
        default:                  canonical = lower
        }
        return supported.contains(canonical) ? canonical : nil
    }
}

#if canImport(HighlightSwift)

/// Code-block fence renderer. When the fence's language resolves to a
/// supported highlight.js id we hand the payload to `CodeText` from
/// HighlightSwift; otherwise we fall through to plain monospaced
/// text so unrecognized fences still render verbatim.
///
/// Theme bridging to `AppearanceStore.themeMode`:
///   1. AppearanceStore feeds `.preferredColorScheme` at the app root
///      (`SweKittyApp.swift`), so `@Environment(\.colorScheme)` here
///      already resolves to the user's choice (system / light / dark).
///   2. HighlightSwift reads `colorScheme` from the environment to
///      pick `.atomOneDark` vs `.atomOneLight` inside the `.atomOne`
///      theme — same automatic-light/dark behavior litter relies on.
///
/// API surface kept narrow (`CodeText(content)` + the two stable
/// modifiers from 1.1+: `.codeTextStyle(.card)` and
/// `.codeTextColors(.theme(.atomOne))`) so a future HighlightSwift
/// rename only breaks this gated branch, not the rest of the app.
struct SyntaxHighlightedCodeBlock: View {
    let language: String?
    let content: String

    var body: some View {
        if SyntaxLanguage.normalize(language ?? "") != nil {
            CodeText(content)
                .codeTextStyle(.card)
                .codeTextColors(.theme(.atomOne))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(content)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One highlighted line inside a diff hunk. The leading `+ `/`- `/`@@`
/// gutter is still owned by the caller (`ConversationDiffBlock`); we
/// only highlight the *payload* — the text after the gutter character
/// — so the additions/deletions still read at a glance via tint, and
/// highlight.js doesn't mistake the leading `+` for an operator.
struct SyntaxHighlightedDiffLine: View {
    let line: String
    let language: String?
    let tint: Color

    var body: some View {
        let (gutter, payload) = Self.split(line)
        HStack(alignment: .top, spacing: 0) {
            if !gutter.isEmpty {
                Text(gutter)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(tint)
            }
            if let lang = language, SyntaxLanguage.normalize(lang) != nil {
                CodeText(payload)
                    .codeTextColors(.theme(.atomOne))
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text(payload)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
    }

    /// Pull the `+ `/`- `/`@@` gutter off the front so the highlighted
    /// payload doesn't carry it (highlight.js would otherwise tokenize
    /// the `+` as an operator and miscolor the rest of the line).
    static func split(_ line: String) -> (gutter: String, payload: String) {
        if line.hasPrefix("@@") {
            return ("@@", String(line.dropFirst(2)))
        }
        if line.hasPrefix("+") || line.hasPrefix("-") {
            return (String(line.prefix(1)), String(line.dropFirst(1)))
        }
        return ("", line)
    }
}

#else

/// Stubs used when HighlightSwift isn't linked into the build — keeps
/// the call sites in `ConversationView` compiling whether or not the
/// SPM package resolves successfully. Renders plain monospaced text
/// identical to the previous (pre-highlight) code path.
///
/// This branch exists because the risk note in `ios-syntax-highlighting`
/// carved out a fallback: if HighlightSwift stalls the SPM resolve or
/// breaks the simulator build, the package line in `apps/ios/project.yml`
/// can be removed and the renderer keeps working — only the visual
/// highlighting goes away.
struct SyntaxHighlightedCodeBlock: View {
    let language: String?
    let content: String

    var body: some View {
        Text(content)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(SweKittyTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SyntaxHighlightedDiffLine: View {
    let line: String
    let language: String?
    let tint: Color

    var body: some View {
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
