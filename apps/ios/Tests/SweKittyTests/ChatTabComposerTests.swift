import Testing
@testable import SweKitty

/// Composer placeholder + Unicode ellipsis assertions. The legacy
/// `ChatTab` view was deleted in the litter-ui-cutover; the same
/// "Message <agent>…" rule is now expressed by
/// `LitterUI.ChatViewModel.composerPlaceholder(forAgent:)`. Tests are
/// retargeted onto that surface so the rule keeps its anti-regression
/// pin without depending on a deleted view.
@Suite("LitterChatView.composerPlaceholder")
struct ChatTabComposerTests {
    @Test func placeholderUsesActiveAgentName() {
        #expect(
            LitterUI.ChatViewModel.composerPlaceholder(forAgent: "claude")
            == "Message claude\u{2026}"
        )
    }

    @Test func placeholderHandlesOtherAgents() {
        #expect(
            LitterUI.ChatViewModel.composerPlaceholder(forAgent: "codex")
            == "Message codex\u{2026}"
        )
    }

    @Test func placeholderFallsBackOnEmptyAssistant() {
        // Sessions that haven't received a status frame yet may have
        // an empty assistant string. The composer still needs to
        // render *something* legible.
        #expect(LitterUI.ChatViewModel.composerPlaceholder(forAgent: "") == "Message\u{2026}")
        #expect(LitterUI.ChatViewModel.composerPlaceholder(forAgent: nil) == "Message\u{2026}")
    }

    @Test func placeholderUsesUnicodeHorizontalEllipsis() {
        // litter uses the single-codepoint "…" (U+2026), not three
        // ASCII dots. The visual is subtly different and the spec
        // calls it out — make sure we don't regress to "...".
        let placeholder = LitterUI.ChatViewModel.composerPlaceholder(forAgent: "claude")
        #expect(placeholder.last == "\u{2026}")
        #expect(!placeholder.hasSuffix("..."))
    }
}
