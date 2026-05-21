import Testing
@testable import SweKitty

/// Drives the pure-function language detector that backs
/// `ConversationCodeBlock` (fenced code) and `ConversationDiffBlock`
/// (per-line highlight). Kept SwiftUI-free on purpose — the HighlightSwift
/// view wrappers can stall the SPM resolve, but this contract is what the
/// renderer reads and what the litter-parity audit calls out as v1
/// (`docs/PLAN-2026-05-19.md` "Code block view with syntax highlighting").
///
/// Test surface mirrors the call sites:
///   - `SyntaxLanguage.fromFence(...)`  ← used by ConversationCodeBlock
///   - `SyntaxLanguage.fromPath(...)`   ← used by ConversationDiffBlock
///   - `SyntaxLanguage.normalize(...)`  ← shared alias collapse
@Suite("SyntaxLanguage")
struct SyntaxHighlightingTests {

    // MARK: - fromFence

    @Test func fenceSwiftReturnsCanonical() {
        #expect(SyntaxLanguage.fromFence("swift") == "swift")
    }

    @Test func fenceUppercaseNormalizes() {
        #expect(SyntaxLanguage.fromFence("Swift") == "swift")
        #expect(SyntaxLanguage.fromFence("TS") == "typescript")
    }

    @Test func fenceAliasesCollapse() {
        #expect(SyntaxLanguage.fromFence("ts") == "typescript")
        #expect(SyntaxLanguage.fromFence("tsx") == "typescript")
        #expect(SyntaxLanguage.fromFence("js") == "javascript")
        #expect(SyntaxLanguage.fromFence("py") == "python")
        #expect(SyntaxLanguage.fromFence("rs") == "rust")
        #expect(SyntaxLanguage.fromFence("kt") == "kotlin")
        #expect(SyntaxLanguage.fromFence("md") == "markdown")
        #expect(SyntaxLanguage.fromFence("sh") == "bash")
        #expect(SyntaxLanguage.fromFence("yml") == "yaml")
    }

    @Test func fenceWithTitleSuffixIgnoresMetadata() {
        // GitHub-style ` ```swift title=Foo.swift` — first token wins.
        #expect(SyntaxLanguage.fromFence("swift title=Foo.swift") == "swift")
        #expect(SyntaxLanguage.fromFence("ts file=index.ts") == "typescript")
    }

    @Test func fenceEmptyReturnsNil() {
        #expect(SyntaxLanguage.fromFence("") == nil)
        #expect(SyntaxLanguage.fromFence("   ") == nil)
        #expect(SyntaxLanguage.fromFence(nil) == nil)
    }

    @Test func fenceUnknownLanguageReturnsNil() {
        // Caller falls back to plain monospace. Asserting nil
        // (rather than "brainfuck") keeps the contract crisp.
        #expect(SyntaxLanguage.fromFence("brainfuck") == nil)
        #expect(SyntaxLanguage.fromFence("madeuplang") == nil)
    }

    // MARK: - fromPath

    @Test func pathSwiftExtension() {
        #expect(SyntaxLanguage.fromPath("Foo.swift") == "swift")
        #expect(SyntaxLanguage.fromPath("apps/ios/Sources/Views/ConversationView.swift") == "swift")
    }

    @Test func pathTypescriptAlias() {
        #expect(SyntaxLanguage.fromPath("index.ts") == "typescript")
        #expect(SyntaxLanguage.fromPath("Component.tsx") == "typescript")
    }

    @Test func pathStripsDiffPrefix() {
        // Git diff paths come through as `a/foo.swift` / `b/foo.swift`.
        #expect(SyntaxLanguage.fromPath("b/apps/ios/Sources/Foo.swift") == "swift")
        #expect(SyntaxLanguage.fromPath("a/cmd/broker/main.go") == "go")
    }

    @Test func pathCoversWiredExtensions() {
        // Spot-check each extension explicitly called out in the
        // PR description as "wired" — if any of these flip to nil
        // the renderer silently loses color for that file type.
        #expect(SyntaxLanguage.fromPath("a.swift") == "swift")
        #expect(SyntaxLanguage.fromPath("a.go") == "go")
        #expect(SyntaxLanguage.fromPath("a.kt") == "kotlin")
        #expect(SyntaxLanguage.fromPath("a.rs") == "rust")
        #expect(SyntaxLanguage.fromPath("a.py") == "python")
        #expect(SyntaxLanguage.fromPath("a.ts") == "typescript")
        #expect(SyntaxLanguage.fromPath("a.js") == "javascript")
        #expect(SyntaxLanguage.fromPath("a.md") == "markdown")
    }

    @Test func pathNoExtensionReturnsNil() {
        #expect(SyntaxLanguage.fromPath("Makefile") == nil)
        #expect(SyntaxLanguage.fromPath("README") == nil)
    }

    @Test func pathUnknownExtensionReturnsNil() {
        #expect(SyntaxLanguage.fromPath("data.weird") == nil)
        #expect(SyntaxLanguage.fromPath("photo.png") == nil)
    }

    // MARK: - normalize

    @Test func normalizeIsCaseInsensitive() {
        #expect(SyntaxLanguage.normalize("SWIFT") == "swift")
        #expect(SyntaxLanguage.normalize("Swift") == "swift")
    }

    @Test func normalizeReturnsNilForUnknown() {
        #expect(SyntaxLanguage.normalize("brainfuck") == nil)
        #expect(SyntaxLanguage.normalize("") == nil)
    }

    @Test func normalizeMappingsAreStable() {
        // Lock the alias table — a future "tidy up the canonical
        // set" refactor that drops a mapping would silently strip
        // color from existing fenced blocks. Better to fail loud.
        let cases: [(String, String?)] = [
            ("ts", "typescript"),
            ("tsx", "typescript"),
            ("js", "javascript"),
            ("jsx", "javascript"),
            ("mjs", "javascript"),
            ("py", "python"),
            ("rs", "rust"),
            ("kt", "kotlin"),
            ("kts", "kotlin"),
            ("md", "markdown"),
            ("markdown", "markdown"),
            ("sh", "bash"),
            ("zsh", "bash"),
            ("yml", "yaml"),
            ("hpp", "cpp"),
            ("cc", "cpp"),
            ("h", "c"),
            ("m", "objectivec"),
            ("mm", "objectivec"),
            ("rb", "ruby"),
        ]
        for (input, want) in cases {
            #expect(SyntaxLanguage.normalize(input) == want, "input=\(input)")
        }
    }
}
