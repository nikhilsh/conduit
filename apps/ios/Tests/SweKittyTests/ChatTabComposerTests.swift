import Testing
@testable import SweKitty

/// Stage 2 — composer restyle. The plan locks the placeholder to
/// litter's "Message <agent>…" wording, derived from the active
/// session's assistant. We expose the string as a static helper so
/// this test doesn't have to host a SwiftUI body.
@Suite("ChatTab.placeholder")
struct ChatTabComposerTests {
    @Test func placeholderUsesActiveAgentName() {
        // Acceptance: with agent=claude the composer reads
        // "Message claude…" — matches PLAN-LITTER-UI.md line 88.
        #expect(ChatTab.placeholder(for: "claude") == "Message claude\u{2026}")
    }

    @Test func placeholderHandlesOtherAgents() {
        #expect(ChatTab.placeholder(for: "codex") == "Message codex\u{2026}")
    }

    @Test func placeholderFallsBackOnEmptyAssistant() {
        // Sessions that haven't received a status frame yet may have
        // an empty assistant string. The composer still needs to
        // render *something* legible — fall back to a generic noun
        // rather than the literal "Message …".
        #expect(ChatTab.placeholder(for: "") == "Message agent\u{2026}")
        #expect(ChatTab.placeholder(for: "   ") == "Message agent\u{2026}")
    }

    @Test func keyboardDismissModeIsInteractive() {
        // fix-ui-friction-vol2: scrolling the chat surface downward
        // should drag the keyboard with the finger (iOS-native
        // behaviour), not snap it shut or leave it pinned. The live
        // ScrollDismissesKeyboardMode struct isn't Equatable so we
        // pin the matching token instead — both are bound to the
        // same chosen mode by colocation in ChatTab.
        #expect(ChatTab.keyboardDismissModeToken == "interactively")
    }

    @Test func placeholderUsesUnicodeHorizontalEllipsis() {
        // litter uses the single-codepoint "…" (U+2026), not three
        // ASCII dots. The visual is subtly different and the spec
        // calls it out — make sure we don't regress to "...".
        let placeholder = ChatTab.placeholder(for: "claude")
        #expect(placeholder.last == "\u{2026}")
        #expect(!placeholder.hasSuffix("..."))
    }
}
