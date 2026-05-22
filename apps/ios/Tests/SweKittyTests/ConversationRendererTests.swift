import Testing
@testable import SweKitty

/// First iOS test suite. Drives the pure-function parser from PR #15
/// (tool-call collapse). Picked as the inaugural test because:
///   1. Zero UIKit / SwiftUI dependencies — runs anywhere XCTest does.
///   2. Concrete contract (block in, blocks out) — easy to assert.
///   3. Has known edge cases (length guard, indented continuation,
///      fenced code) that landed without test coverage at the time.
///      Codifying them here lets us refactor the parser confidently.
@Suite("ConversationRenderer.blocks")
struct ConversationRendererTests {

    // MARK: - Code fence handling

    @Test func fencedCodeSeparatesFromProse() {
        let blocks = ConversationRenderer.blocks(for: """
        Here's the fix:

        ```swift
        let x = 1
        ```

        Done.
        """)
        // 3 blocks: prose intro, code, prose outro. Whitespace
        // trimming on markdown is intentional — assert content,
        // not exact whitespace.
        #expect(blocks.count == 3)
        if case .markdown(let intro) = blocks[0] { #expect(intro.contains("Here's the fix")) } else { Issue.record("first block not markdown: \(blocks[0])") }
        if case .code(let lang, let body) = blocks[1] {
            #expect(lang == "swift")
            #expect(body == "let x = 1")
        } else {
            Issue.record("second block not code: \(blocks[1])")
        }
        if case .markdown(let outro) = blocks[2] { #expect(outro == "Done.") } else { Issue.record("third block not markdown: \(blocks[2])") }
    }

    @Test func codeFenceWithoutLanguage() {
        let blocks = ConversationRenderer.blocks(for: """
        ```
        plain text inside
        ```
        """)
        #expect(blocks.count == 1)
        if case .code(let lang, let body) = blocks[0] {
            #expect(lang == nil)
            #expect(body == "plain text inside")
        } else {
            Issue.record("not a code block: \(blocks[0])")
        }
    }

    // MARK: - Tool-call collapse

    @Test func collapsesConsecutiveBashLines() {
        let blocks = ConversationRenderer.blocks(for: """
        Running the test suite.

        $ go test ./...
        $ go vet ./...

        All green.
        """)
        // Expect: prose, toolSummary(count=2), prose.
        #expect(blocks.count == 3)
        guard case .toolSummary(let label, let detail) = blocks[1] else {
            Issue.record("middle block should be toolSummary, was \(blocks[1])")
            return
        }
        #expect(label == "Ran 2 steps")
        #expect(detail.contains("go test"))
        #expect(detail.contains("go vet"))
    }

    @Test func singleStepUsesSingularLabel() {
        let blocks = ConversationRenderer.blocks(for: """
        Quick check:

        $ ls -la
        """)
        guard let summary = blocks.first(where: { if case .toolSummary = $0 { return true } else { return false } }) else {
            Issue.record("no tool summary block found")
            return
        }
        if case .toolSummary(let label, _) = summary {
            #expect(label == "Ran 1 step")
        }
    }

    @Test func verbsTriggerCollapse() {
        let blocks = ConversationRenderer.blocks(for: """
        Running ./build.sh
        Reading manifest.json
        Editing main.swift
        """)
        // Three tool-shaped lines → one toolSummary("Ran 3 steps").
        #expect(blocks.count == 1)
        if case .toolSummary(let label, _) = blocks[0] {
            #expect(label == "Ran 3 steps")
        } else {
            Issue.record("not a toolSummary: \(blocks[0])")
        }
    }

    // MARK: - Length-guard edge case

    @Test func mediumSentenceWithVerbStaysAsProse() {
        // "Reading" is a recognized verb, but "the project documentation
        // and the changelog" pushes the tail past 80 chars, so the line
        // must NOT be folded into a tool summary — it's prose.
        let line = "Reading the project documentation and the changelog before suggesting any changes."
        let blocks = ConversationRenderer.blocks(for: line)
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == line)
        } else {
            Issue.record("length-guard broken — collapsed prose into \(blocks[0])")
        }
    }

    @Test func sentenceWithPeriodSpaceStaysAsProse() {
        // The tail contains ". " so even though it's short, the verb
        // path should bail out — this is the heuristic that prevents
        // "Reading X. Done." from being eaten as a tool line.
        let line = "Reading X. Done."
        let blocks = ConversationRenderer.blocks(for: line)
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == line)
        } else {
            Issue.record("period-guard broken — collapsed prose into \(blocks[0])")
        }
    }

    // MARK: - Indented continuation

    @Test func indentedOutputGroupsWithToolBlock() {
        // Lines indented with 4+ spaces following a tool-shaped line
        // are treated as captured output and stay in the same
        // collapsed summary — they should not surface as prose.
        let blocks = ConversationRenderer.blocks(for: """
        $ make test
            cargo test --workspace
            running 12 tests

        All passed.
        """)
        guard case .toolSummary(let label, let detail) = blocks.first(where: {
            if case .toolSummary = $0 { return true } else { return false }
        })! else {
            Issue.record("no toolSummary")
            return
        }
        // Continuation lines should NOT bump the step count — they're
        // output of the one `$ make test`, not separate steps.
        #expect(label == "Ran 1 step")
        #expect(detail.contains("cargo test"))
        #expect(detail.contains("running 12 tests"))
        // And the outro prose still surfaces as its own block.
        #expect(blocks.contains(where: {
            if case .markdown(let t) = $0 { return t.contains("All passed.") } else { return false }
        }))
    }

    // MARK: - Pure-pass-through

    @Test func plainProseProducesOneMarkdownBlock() {
        let blocks = ConversationRenderer.blocks(for: "Just a normal sentence.")
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == "Just a normal sentence.")
        } else {
            Issue.record("plain prose not preserved: \(blocks[0])")
        }
    }

    @Test func emptyContentReturnsAnEmptyMarkdownFallback() {
        // The parser's documented behavior on empty input — single
        // markdown block with the original string. Asserting it so
        // future "tighten the empty case" refactors don't silently
        // change the contract.
        let blocks = ConversationRenderer.blocks(for: "")
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == "")
        } else {
            Issue.record("empty content didn't produce markdown: \(blocks[0])")
        }
    }

    // User-message rendering style is now expressed directly by the
    // LitterUI chat view (`LitterUI.ChatViewModel.alignment(for:)` +
    // the row's foreground-color / background-style choices). The
    // legacy `ConversationStyle.userMessage` pin was deleted in the
    // litter-ui-cutover along with `ConversationBubbleContainer`; the
    // `alignment(for:)` rule has its own coverage in
    // `LitterUI.ChatViewModel`-adjacent tests.
}
