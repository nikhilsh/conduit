import Testing
@testable import SweKitty

/// Pins `LitterUI.ForkOptions.models(forAssistant:)` + `modelLabel` /
/// `inheritModel`. The fork sheet's model dropdown is built straight off
/// these pure lists, and the broker passes the chosen value to the
/// agent's --model flag — so the per-assistant filtering and the
/// inherit→no-override mapping are a contract worth pinning. Mirror of
/// Android `ForkModelOptionsTest`.
@Suite("LitterUI.ForkOptions.models")
struct LitterForkOptionsTests {

    @Test func claudeOffersInheritThenAliases() {
        let models = LitterUI.ForkOptions.models(forAssistant: "claude")
        #expect(models == [LitterUI.ForkOptions.inheritModel, "opus", "sonnet", "haiku"])
        // The leading entry is the inherit sentinel (no override).
        #expect(models.first == LitterUI.ForkOptions.inheritModel)
    }

    @Test func codexOffersInheritThenCodexAlias() {
        let models = LitterUI.ForkOptions.models(forAssistant: "codex")
        #expect(models == [LitterUI.ForkOptions.inheritModel, "gpt-5-codex"])
    }

    @Test func unknownAssistantOnlyOffersInherit() {
        let models = LitterUI.ForkOptions.models(forAssistant: "gemini")
        #expect(models == [LitterUI.ForkOptions.inheritModel])
    }

    @Test func optionsAreFilteredByAssistant() {
        // claude aliases never leak into codex's list and vice-versa.
        let claude = LitterUI.ForkOptions.models(forAssistant: "claude")
        let codex = LitterUI.ForkOptions.models(forAssistant: "codex")
        #expect(claude.contains("opus"))
        #expect(!codex.contains("opus"))
        #expect(codex.contains("gpt-5-codex"))
        #expect(!claude.contains("gpt-5-codex"))
    }

    @Test func inheritModelIsTheEmptyNoOverrideSentinel() {
        // The sheet sends `model.isEmpty ? nil : model` to forkSession,
        // so the inherit option must be the empty string for an untouched
        // fork to carry no --model override.
        #expect(LitterUI.ForkOptions.inheritModel == "")
    }

    @Test func modelLabelRendersInheritAsDefaultAndAliasesVerbatim() {
        #expect(LitterUI.ForkOptions.modelLabel(LitterUI.ForkOptions.inheritModel) == "Default (inherit)")
        #expect(LitterUI.ForkOptions.modelLabel("") == "Default (inherit)")
        #expect(LitterUI.ForkOptions.modelLabel("opus") == "opus")
        #expect(LitterUI.ForkOptions.modelLabel("gpt-5-codex") == "gpt-5-codex")
    }
}
