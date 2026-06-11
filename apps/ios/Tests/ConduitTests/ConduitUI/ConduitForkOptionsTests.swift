import Foundation
import Testing
@testable import Conduit

/// Pins `ConduitUI.ForkOptions.models(forAssistant:)` + `modelLabel` /
/// `inheritModel`. The fork sheet's model dropdown is built straight off
/// these pure lists, and the broker passes the chosen value to the
/// agent's --model flag — so the per-assistant filtering and the
/// inherit→no-override mapping are a contract worth pinning. Mirror of
/// Android `ForkModelOptionsTest`.
@Suite("ConduitUI.ForkOptions.models")
struct ConduitForkOptionsTests {

    @Test func claudeOffersInheritThenAliases() {
        let models = ConduitUI.ForkOptions.models(forAssistant: "claude")
        #expect(models == [ConduitUI.ForkOptions.inheritModel, "opus", "sonnet", "haiku"])
        // The leading entry is the inherit sentinel (no override).
        #expect(models.first == ConduitUI.ForkOptions.inheritModel)
    }

    @Test func codexOffersInheritThenCodexAlias() {
        let models = ConduitUI.ForkOptions.models(forAssistant: "codex")
        #expect(models == [ConduitUI.ForkOptions.inheritModel, "gpt-5-codex", "gpt-5", "gpt-5.5"])
    }

    @Test func unknownAssistantOnlyOffersInherit() {
        let models = ConduitUI.ForkOptions.models(forAssistant: "gemini")
        #expect(models == [ConduitUI.ForkOptions.inheritModel])
    }

    @Test func optionsAreFilteredByAssistant() {
        // claude aliases never leak into codex's list and vice-versa.
        let claude = ConduitUI.ForkOptions.models(forAssistant: "claude")
        let codex = ConduitUI.ForkOptions.models(forAssistant: "codex")
        #expect(claude.contains("opus"))
        #expect(!codex.contains("opus"))
        #expect(codex.contains("gpt-5-codex"))
        #expect(!claude.contains("gpt-5-codex"))
    }

    @Test func inheritModelIsTheEmptyNoOverrideSentinel() {
        // The sheet sends `model.isEmpty ? nil : model` to forkSession,
        // so the inherit option must be the empty string for an untouched
        // fork to carry no --model override.
        #expect(ConduitUI.ForkOptions.inheritModel == "")
    }

    @Test func modelLabelRendersInheritAsDefaultAndAliasesVerbatim() {
        #expect(ConduitUI.ForkOptions.modelLabel(ConduitUI.ForkOptions.inheritModel) == "Default (inherit)")
        #expect(ConduitUI.ForkOptions.modelLabel("") == "Default (inherit)")
        #expect(ConduitUI.ForkOptions.modelLabel("opus") == "opus")
        #expect(ConduitUI.ForkOptions.modelLabel("gpt-5-codex") == "gpt-5-codex")
    }
}

/// Pins the catalog-aware ForkOptions overloads: with a broker-discovered
/// catalog the picker options come from the agent itself (per-model effort
/// ranges, live display names); without one everything falls back to the
/// static lists above. Mirror of Android `AgentModelCatalogTest`.
@Suite("ConduitUI.ForkOptions catalog")
struct ConduitForkOptionsCatalogTests {
    // Shapes mirror what the broker normalizes from the live agents
    // (claude initialize control response / codex model/list).
    private let claudeCatalog: [ConduitUI.AgentModel] = [
        .init(id: "", displayName: "Default (recommended)",
              description: "Opus 4.8 with 1M context · Best for everyday, complex tasks",
              isDefault: true, efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(id: "claude-fable-5[1m]", displayName: "Fable",
              description: "Fable 5 · Most capable",
              efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(id: "sonnet", displayName: "Sonnet",
              description: "Sonnet 4.6 · Efficient for routine tasks",
              efforts: ["low", "medium", "high", "max"]),
        .init(id: "haiku", displayName: "Haiku",
              description: "Haiku 4.5 · Fastest for quick answers"),
    ]
    private let codexCatalog: [ConduitUI.AgentModel] = [
        .init(id: "gpt-5.5", displayName: "GPT-5.5",
              description: "Frontier model for complex coding.",
              isDefault: true, defaultEffort: "medium",
              efforts: ["low", "medium", "high", "xhigh"]),
        .init(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini",
              description: "Small and fast.", defaultEffort: "medium",
              efforts: ["low", "medium"]),
    ]

    @Test func catalogModelsPrependInheritWhenAbsent() {
        // codex's catalog has no "" entry → the inherit sentinel is added.
        let codex = ConduitUI.ForkOptions.models(forAssistant: "codex", catalog: codexCatalog)
        #expect(codex == ["", "gpt-5.5", "gpt-5.4-mini"])
        // claude's catalog already leads with the normalized "" entry.
        let claude = ConduitUI.ForkOptions.models(forAssistant: "claude", catalog: claudeCatalog)
        #expect(claude == ["", "claude-fable-5[1m]", "sonnet", "haiku"])
    }

    @Test func nilOrEmptyCatalogFallsBackToStaticLists() {
        #expect(ConduitUI.ForkOptions.models(forAssistant: "claude", catalog: nil)
            == ConduitUI.ForkOptions.models(forAssistant: "claude"))
        #expect(ConduitUI.ForkOptions.models(forAssistant: "codex", catalog: [])
            == ConduitUI.ForkOptions.models(forAssistant: "codex"))
        #expect(ConduitUI.ForkOptions.efforts(forAssistant: "claude", model: "", catalog: nil)
            == ConduitUI.ForkOptions.efforts(forAssistant: "claude"))
    }

    @Test func effortsArePerModel() {
        // sonnet lacks xhigh; haiku has no effort control at all.
        #expect(ConduitUI.ForkOptions.efforts(forAssistant: "claude", model: "sonnet", catalog: claudeCatalog)
            == ["low", "medium", "high", "max"])
        #expect(ConduitUI.ForkOptions.efforts(forAssistant: "claude", model: "haiku", catalog: claudeCatalog).isEmpty)
        // codex xhigh flows through from the live catalog (the static
        // fallback list tops out at high).
        #expect(ConduitUI.ForkOptions.efforts(forAssistant: "codex", model: "gpt-5.5", catalog: codexCatalog)
            .contains("xhigh"))
    }

    @Test func inheritResolvesToDefaultEntryForEfforts() {
        // Selecting "Default (inherit)" on codex uses the default model's
        // effort range (gpt-5.5), not an empty list.
        #expect(ConduitUI.ForkOptions.efforts(forAssistant: "codex", model: "", catalog: codexCatalog)
            == ["low", "medium", "high", "xhigh"])
    }

    @Test func defaultEffortPrefersAgentAdvertisedDefault() {
        #expect(ConduitUI.ForkOptions.defaultEffort(forAssistant: "codex", model: "gpt-5.5", catalog: codexCatalog) == "medium")
        // haiku: no effort control → empty (UI hides the section).
        #expect(ConduitUI.ForkOptions.defaultEffort(forAssistant: "claude", model: "haiku", catalog: claudeCatalog) == "")
        // No catalog → static list default.
        #expect(ConduitUI.ForkOptions.defaultEffort(forAssistant: "claude") == "medium")
    }

    @Test func modelLabelAndDetailComeFromCatalog() {
        #expect(ConduitUI.ForkOptions.modelLabel("gpt-5.5", catalog: codexCatalog) == "GPT-5.5")
        // Fix A: the default/inherit entry shows the resolved model name so
        // Opus is discoverable after the user has switched to another model.
        // claude: catalog has an entry with id "" and displayName
        // "Default (recommended)" → resolved to "Opus 4.8 (recommended)".
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: claudeCatalog) == "Opus 4.8 (recommended)")
        // codex: no catalog entry with id "" but isDefault=gpt-5.5 →
        // inherit sentinel resolves to "GPT-5.5 (recommended)".
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: codexCatalog) == "GPT-5.5 (recommended)")
        // Unknown id (stale selection) falls back to verbatim.
        #expect(ConduitUI.ForkOptions.modelLabel("opus", catalog: codexCatalog) == "opus")
        #expect(ConduitUI.ForkOptions.modelDetail("sonnet", catalog: claudeCatalog)
            == "Sonnet 4.6 · Efficient for routine tasks")
        // Inherit resolves to the default entry's description.
        #expect(ConduitUI.ForkOptions.modelDetail("", catalog: codexCatalog)
            == "Frontier model for complex coding.")
        #expect(ConduitUI.ForkOptions.modelDetail("opus", catalog: nil) == nil)
    }

    // Fix A: default entry label surfaces the resolved model name so the
    // option is identifiable after another model is selected. No hardcoding
    // of "opus" — derived from the catalog description's first ·-chunk.
    @Test func defaultModelLabelSurfacesResolvedName() {
        // claude: catalog entry id "" has displayName "Default (recommended)"
        // → resolved to "Opus 4.8 (recommended)" via defaultModelTitle.
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: claudeCatalog) == "Opus 4.8 (recommended)")
        // Non-default entries retain their verbatim display name.
        #expect(ConduitUI.ForkOptions.modelLabel("claude-fable-5[1m]", catalog: claudeCatalog) == "Fable")
        #expect(ConduitUI.ForkOptions.modelLabel("sonnet", catalog: claudeCatalog) == "Sonnet")
        // Without a catalog: falls back to the static no-catalog label.
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: nil) == "Default (inherit)")
        // Empty catalog: also falls back to static label.
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: []) == "Default (inherit)")
        // Unknown id with catalog: no matching entry → falls back to verbatim.
        #expect(ConduitUI.ForkOptions.modelLabel("unknown-model", catalog: claudeCatalog) == "unknown-model")
    }

    // Fix 3 (device feedback v0.0.134): codex has no literal "" catalog entry,
    // so the inherit sentinel must resolve via the isDefault entry ("gpt-5.5")
    // and show "GPT-5.5 (recommended)" — not the stale "Default (inherit)".
    @Test func codexInheritResolvesToDefaultModelName() {
        // The inherit sentinel "" resolves through the isDefault entry (gpt-5.5)
        // → "GPT-5.5 (recommended)".
        #expect(ConduitUI.ForkOptions.modelLabel("", catalog: codexCatalog) == "GPT-5.5 (recommended)")
        // Explicit gpt-5.5 row still shows its own name verbatim (no "(recommended)" suffix).
        #expect(ConduitUI.ForkOptions.modelLabel("gpt-5.5", catalog: codexCatalog) == "GPT-5.5")
        // Consequence: the picker will show both "GPT-5.5 (recommended)" (inherit)
        // and "GPT-5.5" (pinned). That's acceptable — inherit-follows-default vs
        // pinned — Nikhil to decide if a dedup pass is needed.
    }

    @Test func defaultModelTitleResolvesCardLabel() {
        // codex: the default entry's display name verbatim.
        #expect(ConduitUI.ForkOptions.defaultModelTitle(forCatalog: codexCatalog) == "GPT-5.5")
        // claude: "Default (recommended)" resolves through the description's
        // first ·-chunk, with the context-size suffix stripped.
        #expect(ConduitUI.ForkOptions.defaultModelTitle(forCatalog: claudeCatalog) == "Opus 4.8")
        #expect(ConduitUI.ForkOptions.defaultModelTitle(forCatalog: nil) == nil)
        #expect(ConduitUI.ForkOptions.defaultModelTitle(forCatalog: []) == nil)
    }

    // Fix B: effort labels must be the REAL level names so the dial and
    // the raw-value chip agree. "Deep" was wrong for "high"; "Fast" /
    // "Balanced" were renamed to "Low" / "Medium" to match broker values.
    @Test func effortLabelsCoverKnownLevelsAndFallBack() {
        #expect(ConduitUI.ForkOptions.effortLabel("low") == "Low")
        #expect(ConduitUI.ForkOptions.effortLabel("medium") == "Medium")
        #expect(ConduitUI.ForkOptions.effortLabel("high") == "High")
        #expect(ConduitUI.ForkOptions.effortLabel("xhigh") == "X-High")
        #expect(ConduitUI.ForkOptions.effortLabel("max") == "Max")
        #expect(ConduitUI.ForkOptions.effortLabel("turbo") == "Turbo")
    }

    @Test func agentModelDecodesBrokerWireShape() throws {
        let json = """
        [{"id":"gpt-5.5","display_name":"GPT-5.5","description":"Frontier.",
          "is_default":true,"default_effort":"medium","efforts":["low","medium","high","xhigh"]},
         {"id":"haiku","display_name":"Haiku"}]
        """.data(using: .utf8)!
        let models = try JSONDecoder().decode([ConduitUI.AgentModel].self, from: json)
        #expect(models.count == 2)
        #expect(models[0].id == "gpt-5.5")
        #expect(models[0].isDefault)
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh"])
        // Omitted optional fields decode to inert defaults.
        #expect(models[1].efforts.isEmpty)
        #expect(!models[1].isDefault)
        #expect(models[1].defaultEffort == "")
    }

    @Test func supportsFastModeOnlyOnAnnotatedEntries() {
        let withFastMode: [ConduitUI.AgentModel] = [
            .init(id: "", displayName: "Default (recommended)",
                  description: "Opus 4.8 with 1M context · Best for everyday, complex tasks",
                  isDefault: true, efforts: ["low", "medium", "high", "xhigh", "max"],
                  supportsFastMode: true),
            .init(id: "sonnet", displayName: "Sonnet",
                  description: "Sonnet 4.6 · Efficient for routine tasks",
                  efforts: ["low", "medium", "high", "max"]),
        ]
        // Inherit sentinel resolves to the default entry — fast mode true.
        #expect(ConduitUI.ForkOptions.supportsFastMode("", catalog: withFastMode))
        // Explicit sonnet entry — fast mode false.
        #expect(!ConduitUI.ForkOptions.supportsFastMode("sonnet", catalog: withFastMode))
        // No catalog — always false.
        #expect(!ConduitUI.ForkOptions.supportsFastMode("", catalog: nil))
    }

    @Test func supportsFastModeDecodesFromWireFormat() throws {
        let json = """
        [{"id":"","display_name":"Default (recommended)",
          "is_default":true,"supports_fast_mode":true,
          "efforts":["low","medium","high","xhigh","max"]},
         {"id":"sonnet","display_name":"Sonnet"}]
        """.data(using: .utf8)!
        let models = try JSONDecoder().decode([ConduitUI.AgentModel].self, from: json)
        #expect(models[0].supportsFastMode)
        #expect(!models[1].supportsFastMode)
    }
}
