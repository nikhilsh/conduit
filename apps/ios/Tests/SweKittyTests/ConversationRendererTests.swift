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

/// Pins the structured-markdown splitter (BUG 1). `AttributedString
/// (markdown:)` flattens block structure — headings jam into following
/// text and GFM tables collapse into concatenated cell text. The
/// splitter pre-separates the body into typed pieces so the renderer can
/// space them and stack table rows instead of running them together.
@Suite("LitterMarkdownStructure.parse")
struct LitterMarkdownStructureTests {

    @Test func headingIsItsOwnPieceAndDoesNotMergeIntoNextBlock() {
        let pieces = LitterMarkdownStructure.parse("""
        ## Summary
        The build is green.
        """)
        // Two distinct pieces — the heading must NOT concatenate with
        // the paragraph that follows it.
        #expect(pieces.count == 2)
        guard case .heading(let level, let text) = pieces[0] else {
            Issue.record("first piece not a heading: \(pieces[0])"); return
        }
        #expect(level == 2)
        #expect(text == "Summary")
        guard case .paragraph(let body) = pieces[1] else {
            Issue.record("second piece not a paragraph: \(pieces[1])"); return
        }
        #expect(body == "The build is green.")
    }

    @Test func gfmTableParsesIntoHeadersAndRowsNotConcatenated() {
        let pieces = LitterMarkdownStructure.parse("""
        | Session | Assistant | Notes |
        | --- | --- | --- |
        | 062e6bf1 | claude | 120x40 |
        | a1b2c3d4 | codex | 80x24 |
        """)
        #expect(pieces.count == 1)
        guard case .table(let headers, let rows) = pieces[0] else {
            Issue.record("not a table: \(pieces[0])"); return
        }
        #expect(headers == ["Session", "Assistant", "Notes"])
        #expect(rows.count == 2)
        // The delimiter row must be dropped, and cells must stay split
        // (the device bug rendered these run together).
        #expect(rows[0] == ["062e6bf1", "claude", "120x40"])
        #expect(rows[1] == ["a1b2c3d4", "codex", "80x24"])
    }

    @Test func pipeProseLineIsNotMistakenForATable() {
        // A lone pipe line with no delimiter row underneath stays prose.
        let pieces = LitterMarkdownStructure.parse("Run `a | b` to pipe.")
        #expect(pieces.count == 1)
        guard case .paragraph(let text) = pieces[0] else {
            Issue.record("pipe prose collapsed into \(pieces[0])"); return
        }
        #expect(text == "Run `a | b` to pipe.")
    }

    @Test func unorderedListParsesItems() {
        let pieces = LitterMarkdownStructure.parse("""
        - first
        - second
        - third
        """)
        #expect(pieces.count == 1)
        guard case .list(let ordered, let items) = pieces[0] else {
            Issue.record("not a list: \(pieces[0])"); return
        }
        #expect(!ordered)
        #expect(items == ["first", "second", "third"])
    }

    @Test func orderedListParsesItemsAndMarkerType() {
        let pieces = LitterMarkdownStructure.parse("""
        1. alpha
        2. beta
        """)
        #expect(pieces.count == 1)
        guard case .list(let ordered, let items) = pieces[0] else {
            Issue.record("not a list: \(pieces[0])"); return
        }
        #expect(ordered)
        #expect(items == ["alpha", "beta"])
    }

    @Test func mixedBodySeparatesEveryBlock() {
        // Heading + paragraph + list + table all in one body must yield
        // four separate pieces in order — no block bunching.
        let pieces = LitterMarkdownStructure.parse("""
        # Report

        Here are the results.

        - passed
        - failed

        | Test | Status |
        | --- | --- |
        | unit | ok |
        """)
        #expect(pieces.count == 4)
        if case .heading = pieces[0] {} else { Issue.record("0 not heading: \(pieces[0])") }
        if case .paragraph = pieces[1] {} else { Issue.record("1 not paragraph: \(pieces[1])") }
        if case .list = pieces[2] {} else { Issue.record("2 not list: \(pieces[2])") }
        if case .table = pieces[3] {} else { Issue.record("3 not table: \(pieces[3])") }
    }

    @Test func fencedCodeBecomesACodePieceNotRawProse() {
        // Streaming path: the live buffer is passed in raw (not pre-split
        // by ConversationRenderer.blocks), so parse must turn a fence into
        // a .code piece rather than leaking the ``` markers as prose.
        let pieces = LitterMarkdownStructure.parse("""
        Here:

        ```swift
        let x = 1
        ```

        done
        """)
        #expect(pieces.count == 3)
        guard case .code(let lang, let body) = pieces[1] else {
            Issue.record("middle piece not code: \(pieces[1])"); return
        }
        #expect(lang == "swift")
        #expect(body == "let x = 1")
    }

    @Test func unclosedFenceMidStreamStillRendersAsCode() {
        // The common streaming case: the closing ``` hasn't arrived yet.
        // We must still render the body as code (no raw ``` flash).
        let pieces = LitterMarkdownStructure.parse("""
        ```js
        const a =
        """)
        #expect(pieces.count == 1)
        guard case .code(let lang, let body) = pieces[0] else {
            Issue.record("unclosed fence not code: \(pieces[0])"); return
        }
        #expect(lang == "js")
        #expect(body == "const a =")
    }

    @Test func emptyInputProducesOneEmptyParagraph() {
        let pieces = LitterMarkdownStructure.parse("")
        #expect(pieces.count == 1)
        if case .paragraph(let t) = pieces[0] { #expect(t == "") } else {
            Issue.record("empty input not a paragraph: \(pieces[0])")
        }
    }

    @Test func bareFenceWithNoLanguageBecomesCodeWithNilLanguage() {
        // A fence opened with bare ``` (no language tag) must still be a
        // .code piece — and the language must be nil, not the empty
        // string, so the renderer hides the language label entirely.
        let pieces = LitterMarkdownStructure.parse("""
        ```
        plain code
        ```
        """)
        #expect(pieces.count == 1)
        guard case .code(let lang, let body) = pieces[0] else {
            Issue.record("bare fence not code: \(pieces[0])"); return
        }
        #expect(lang == nil)
        #expect(body == "plain code")
    }

    @Test func codeInterleavedWithProseKeepsPieceOrdering() {
        // Prose · code · prose · code · prose — every block must survive
        // in order, with the two fences landing as the 2nd and 4th pieces.
        let pieces = LitterMarkdownStructure.parse("""
        First, the setup:

        ```sh
        npm install
        ```

        Then run it:

        ```sh
        npm start
        ```

        That's all.
        """)
        #expect(pieces.count == 5)
        if case .paragraph(let p) = pieces[0] { #expect(p.contains("First, the setup")) } else { Issue.record("0 not paragraph: \(pieces[0])") }
        guard case .code(let lang1, let body1) = pieces[1] else {
            Issue.record("1 not code: \(pieces[1])"); return
        }
        #expect(lang1 == "sh")
        #expect(body1 == "npm install")
        if case .paragraph(let p) = pieces[2] { #expect(p.contains("Then run it")) } else { Issue.record("2 not paragraph: \(pieces[2])") }
        guard case .code(let lang2, let body2) = pieces[3] else {
            Issue.record("3 not code: \(pieces[3])"); return
        }
        #expect(lang2 == "sh")
        #expect(body2 == "npm start")
        if case .paragraph(let p) = pieces[4] { #expect(p.contains("That's all")) } else { Issue.record("4 not paragraph: \(pieces[4])") }
    }

    @Test func fenceImmediatelyFollowedByHeadingAfterCloseSeparatesCleanly() {
        // The close fence butts right up against a heading with no blank
        // line. The heading must NOT be swallowed into the code body and
        // must surface as its own .heading piece.
        let pieces = LitterMarkdownStructure.parse("""
        ```swift
        let x = 1
        ```
        ## Next steps
        """)
        #expect(pieces.count == 2)
        guard case .code(let lang, let body) = pieces[0] else {
            Issue.record("0 not code: \(pieces[0])"); return
        }
        #expect(lang == "swift")
        #expect(body == "let x = 1")
        guard case .heading(let level, let text) = pieces[1] else {
            Issue.record("1 not heading: \(pieces[1])"); return
        }
        #expect(level == 2)
        #expect(text == "Next steps")
    }
}
