package sh.nikhil.swekitty.ui

/**
 * Pure-function language detection mirroring
 * `apps/ios/Sources/Views/SyntaxHighlighting.swift`. Bridges Markdown
 * fence info strings (`"swift"` -> `"swift"`) and file-extension hints
 * (`"foo.swift"` -> `"swift"`) to a canonical highlight.js / Prism4j
 * language id.
 *
 * Lives separately from any UI code so [SyntaxHighlightingLanguageTest]
 * can exercise it with zero Compose dependencies -- and so the
 * rendering integration with Prism4j can ship as a follow-up without
 * touching the detector contract.
 *
 * Why this is a separate file instead of inline in [ChatPage]:
 * PLAN-2026-05-19 calls out "Code block view with syntax highlighting
 * (HighlightSwift on iOS, Prism4j on Android -- same libraries litter
 * uses)" as the v1 conversation parity gap. Shipping the detector
 * first lets the Rust core's classifier reuse the same canonical id
 * set (e.g. `"ts" -> "typescript"`) without anyone having to read the
 * fenced-code branch in the renderer.
 *
 * Prism4j as a Gradle dep adds significant resolve time and risks CI
 * breakage; the actual highlighting integration is deferred. This
 * detector + a Compose-friendly fallback stub ship now so the call
 * sites have a stable contract to wire against when the dep lands.
 */
object SyntaxLanguage {

    /**
     * Languages we explicitly recognize. Anything else falls back to
     * monospace plain text in the renderer. The set tracks litter's
     * Prism4j configuration: the highlight.js / Prism core langs plus
     * the ones our agent traffic actually carries (Swift / Go /
     * Kotlin / Rust / Python / TS / JS / Markdown).
     */
    val supported: Set<String> = setOf(
        "swift", "go", "kotlin", "rust", "python", "typescript",
        "javascript", "markdown", "bash", "shell", "json", "yaml",
        "html", "css", "java", "c", "cpp", "objectivec", "ruby",
        "sql", "toml", "xml", "diff",
    )

    /**
     * Resolve a Markdown fence info string into a canonical language
     * id. Returns null for empty / unrecognized fences (caller falls
     * back to plain monospace).
     *
     * Strips fence-suffix metadata too: GitHub-style
     * ` ```swift title=Foo.swift` is common in the wild; we keep only
     * the first whitespace-separated token before normalizing.
     *
     * Examples:
     *   `fromFence("swift")`         -> `"swift"`
     *   `fromFence("TS")`            -> `"typescript"`
     *   `fromFence("ts title=Foo")`  -> `"typescript"`
     *   `fromFence("")`              -> `null`
     *   `fromFence("brainfuck")`     -> `null`
     */
    fun fromFence(raw: String?): String? {
        if (raw == null) return null
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val head = trimmed.split(Regex("\\s+")).first()
        return normalize(head)
    }

    /**
     * Pick a language id from a file path's extension. Used by the
     * diff renderer so `foo.swift` lines pick up Swift highlighting.
     * Returns null when there's no extension or the extension isn't
     * in our supported set.
     *
     * Strips leading `a/` / `b/` git-diff prefixes so a path like
     * `b/apps/android/app/src/main/kotlin/Foo.kt` still resolves to
     * `"kotlin"`.
     */
    fun fromPath(path: String): String? {
        val stripped = if (path.startsWith("a/") || path.startsWith("b/")) {
            path.substring(2)
        } else {
            path
        }
        val dot = stripped.lastIndexOf('.')
        if (dot < 0) return null
        val ext = stripped.substring(dot + 1).lowercase()
        return normalize(ext)
    }

    /**
     * Lowercase + alias-collapse to the canonical highlight.js id.
     * Public so callers can normalize whatever language hint they
     * already have (e.g. a Rust-side classifier output) without
     * re-implementing the alias table.
     */
    fun normalize(raw: String): String? {
        val lower = raw.lowercase()
        val canonical = when (lower) {
            "ts", "tsx" -> "typescript"
            "js", "jsx", "mjs" -> "javascript"
            "py" -> "python"
            "rs" -> "rust"
            "kt", "kts" -> "kotlin"
            "md", "markdown" -> "markdown"
            "sh", "zsh" -> "bash"
            "yml" -> "yaml"
            "hpp", "cc", "cxx" -> "cpp"
            "h" -> "c"
            "mm", "m" -> "objectivec"
            "rb" -> "ruby"
            else -> lower
        }
        return if (supported.contains(canonical)) canonical else null
    }
}
