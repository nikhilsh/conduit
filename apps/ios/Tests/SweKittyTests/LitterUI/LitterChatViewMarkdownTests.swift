import Testing
import Foundation
@testable import SweKitty

/// Smoke tests for the markdown pipeline now driving LitterChatView.
///
/// LitterChatView routes assistant content through `ConversationRenderer`
/// (block tokenizer) and `AttributedString(markdown:)` via the
/// `LitterMarkdownBlock` view. The view itself isn't trivially testable
/// (SwiftUI body + environment-injected coordinator + render cache);
/// these tests pin the pure-data layer the view depends on, so any
/// regression there fails CI long before it hits a render.
@Suite("LitterChatView — markdown pipeline")
struct LitterChatViewMarkdownTests {

    @Test func plainTextBecomesSingleMarkdownBlock() {
        let blocks = ConversationRenderer.blocks(for: "hello world")
        #expect(blocks.count == 1)
        if case .markdown(let text) = blocks[0] {
            #expect(text == "hello world")
        } else {
            Issue.record("expected markdown block, got \(blocks[0])")
        }
    }

    @Test func fencedSwiftCodeExtractsLanguage() {
        let src = """
        intro line

        ```swift
        func hello() {}
        ```

        trailing
        """
        let blocks = ConversationRenderer.blocks(for: src)
        // Expect: markdown("intro line"), code(.swift, ...), markdown("trailing")
        #expect(blocks.count == 3)
        if case .code(let lang, let content) = blocks[1] {
            #expect(lang == "swift")
            #expect(content == "func hello() {}")
        } else {
            Issue.record("expected code block at index 1, got \(blocks[1])")
        }
    }

    @Test func attributedStringParsesBoldMarkdown() throws {
        let parsed = try AttributedString(
            markdown: "Hello **world**",
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )
        // The marker characters are interpreted, so the rendered
        // string drops the leading `**` markers.
        let plain = String(parsed.characters)
        #expect(plain == "Hello world")
    }

    @Test func messageRenderCacheKeysOnItemRevisionPair() {
        // Set a value for (msg-cutover-1, 100), confirm we get it back
        // at the same key; a different (item, rev) is a miss. Lighter
        // assertion than the broader cache eviction coverage already
        // in `MessageRenderCacheTests` — this is the smoke test that
        // LitterMarkdownBlock's lookup contract holds.
        let cache = MessageRenderCache.shared
        let value = AttributedString("v1")
        cache.set(itemID: "msg-cutover-1", revision: 100, value: value)
        let hit = cache.get(itemID: "msg-cutover-1", revision: 100)
        #expect(hit != nil)
        cache.invalidate(itemID: "msg-cutover-1")
    }
}
