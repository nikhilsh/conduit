package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Drives the pure-function language detector that will back the
 * Android code-block (fenced) and diff (per-line) renderers. Mirror
 * of `apps/ios/Tests/SweKittyTests/SyntaxHighlightingTests.swift` --
 * the Prism4j integration ships as a follow-up, but the detector
 * contract is what the renderer reads and what the litter-parity
 * audit calls out as v1 (`docs/PLAN-2026-05-19.md` "Code block view
 * with syntax highlighting").
 *
 * Test surface mirrors the planned call sites:
 *   - [SyntaxLanguage.fromFence]  <- used by the fenced code block
 *   - [SyntaxLanguage.fromPath]   <- used by the diff renderer
 *   - [SyntaxLanguage.normalize]  <- shared alias collapse
 *
 * Uses plain JUnit (no Compose runtime) so it slots into the existing
 * `apps/android/app/src/test/java/.../ui/` JVM suite next to
 * [AgentAccentTest].
 */
class SyntaxHighlightingLanguageTest {

    // MARK: - fromFence

    @Test fun fenceSwiftReturnsCanonical() {
        assertEquals("swift", SyntaxLanguage.fromFence("swift"))
    }

    @Test fun fenceUppercaseNormalizes() {
        assertEquals("swift", SyntaxLanguage.fromFence("Swift"))
        assertEquals("typescript", SyntaxLanguage.fromFence("TS"))
    }

    @Test fun fenceAliasesCollapse() {
        assertEquals("typescript", SyntaxLanguage.fromFence("ts"))
        assertEquals("typescript", SyntaxLanguage.fromFence("tsx"))
        assertEquals("javascript", SyntaxLanguage.fromFence("js"))
        assertEquals("python", SyntaxLanguage.fromFence("py"))
        assertEquals("rust", SyntaxLanguage.fromFence("rs"))
        assertEquals("kotlin", SyntaxLanguage.fromFence("kt"))
        assertEquals("markdown", SyntaxLanguage.fromFence("md"))
        assertEquals("bash", SyntaxLanguage.fromFence("sh"))
        assertEquals("yaml", SyntaxLanguage.fromFence("yml"))
    }

    @Test fun fenceWithTitleSuffixIgnoresMetadata() {
        // GitHub-style ` ```swift title=Foo.swift` -- first token wins.
        assertEquals("swift", SyntaxLanguage.fromFence("swift title=Foo.swift"))
        assertEquals("typescript", SyntaxLanguage.fromFence("ts file=index.ts"))
    }

    @Test fun fenceEmptyReturnsNil() {
        assertNull(SyntaxLanguage.fromFence(""))
        assertNull(SyntaxLanguage.fromFence("   "))
        assertNull(SyntaxLanguage.fromFence(null))
    }

    @Test fun fenceUnknownLanguageReturnsNil() {
        // Caller falls back to plain monospace. Asserting null
        // (rather than "brainfuck") keeps the contract crisp.
        assertNull(SyntaxLanguage.fromFence("brainfuck"))
        assertNull(SyntaxLanguage.fromFence("madeuplang"))
    }

    // MARK: - fromPath

    @Test fun pathSwiftExtension() {
        assertEquals("swift", SyntaxLanguage.fromPath("Foo.swift"))
        assertEquals(
            "swift",
            SyntaxLanguage.fromPath("apps/ios/Sources/Views/ConversationView.swift"),
        )
    }

    @Test fun pathTypescriptAlias() {
        assertEquals("typescript", SyntaxLanguage.fromPath("index.ts"))
        assertEquals("typescript", SyntaxLanguage.fromPath("Component.tsx"))
    }

    @Test fun pathStripsDiffPrefix() {
        // Git diff paths come through as `a/foo.swift` / `b/foo.swift`.
        assertEquals(
            "swift",
            SyntaxLanguage.fromPath("b/apps/ios/Sources/Foo.swift"),
        )
        assertEquals("go", SyntaxLanguage.fromPath("a/cmd/broker/main.go"))
        // Android-flavored diff path -- the moral equivalent of the
        // iOS test, kept here so the Kotlin port doesn't drift if the
        // Kotlin source tree gets renamed.
        assertEquals(
            "kotlin",
            SyntaxLanguage.fromPath("b/apps/android/app/src/main/kotlin/Foo.kt"),
        )
    }

    @Test fun pathCoversWiredExtensions() {
        // Spot-check each extension explicitly called out in the
        // PR description as "wired" -- if any of these flip to null
        // the renderer silently loses color for that file type.
        assertEquals("swift", SyntaxLanguage.fromPath("a.swift"))
        assertEquals("go", SyntaxLanguage.fromPath("a.go"))
        assertEquals("kotlin", SyntaxLanguage.fromPath("a.kt"))
        assertEquals("rust", SyntaxLanguage.fromPath("a.rs"))
        assertEquals("python", SyntaxLanguage.fromPath("a.py"))
        assertEquals("typescript", SyntaxLanguage.fromPath("a.ts"))
        assertEquals("javascript", SyntaxLanguage.fromPath("a.js"))
        assertEquals("markdown", SyntaxLanguage.fromPath("a.md"))
    }

    @Test fun pathNoExtensionReturnsNil() {
        assertNull(SyntaxLanguage.fromPath("Makefile"))
        assertNull(SyntaxLanguage.fromPath("README"))
    }

    @Test fun pathUnknownExtensionReturnsNil() {
        assertNull(SyntaxLanguage.fromPath("data.weird"))
        assertNull(SyntaxLanguage.fromPath("photo.png"))
    }

    // MARK: - normalize

    @Test fun normalizeIsCaseInsensitive() {
        assertEquals("swift", SyntaxLanguage.normalize("SWIFT"))
        assertEquals("swift", SyntaxLanguage.normalize("Swift"))
    }

    @Test fun normalizeReturnsNilForUnknown() {
        assertNull(SyntaxLanguage.normalize("brainfuck"))
        assertNull(SyntaxLanguage.normalize(""))
    }

    @Test fun normalizeMappingsAreStable() {
        // Lock the alias table -- a future "tidy up the canonical
        // set" refactor that drops a mapping would silently strip
        // color from existing fenced blocks. Better to fail loud.
        val cases: List<Pair<String, String?>> = listOf(
            "ts" to "typescript",
            "tsx" to "typescript",
            "js" to "javascript",
            "jsx" to "javascript",
            "mjs" to "javascript",
            "py" to "python",
            "rs" to "rust",
            "kt" to "kotlin",
            "kts" to "kotlin",
            "md" to "markdown",
            "markdown" to "markdown",
            "sh" to "bash",
            "zsh" to "bash",
            "yml" to "yaml",
            "hpp" to "cpp",
            "cc" to "cpp",
            "h" to "c",
            "m" to "objectivec",
            "mm" to "objectivec",
            "rb" to "ruby",
        )
        for ((input, want) in cases) {
            assertEquals("input=$input", want, SyntaxLanguage.normalize(input))
        }
    }
}
