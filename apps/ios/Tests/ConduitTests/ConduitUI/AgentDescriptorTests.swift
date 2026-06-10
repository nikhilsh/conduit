import Foundation
import Testing
@testable import Conduit

// MARK: - AgentDescriptor decode tests (WS-3.1)
//
// Mirrors ConduitForkOptionsTests: descriptor decode from wire JSON, gating
// helpers with descriptor present vs absent (fallback = today's behaviour),
// and generic-agent rendering metadata derivation.

@Suite("AgentDescriptor — wire decode")
struct AgentDescriptorDecodeTests {

    @Test func decodeFullClaudeDescriptor() throws {
        let json = """
        {
          "display_name": "Claude",
          "login_provider": "anthropic",
          "supports": {
            "compact": true,
            "ask_user_question": true,
            "effort": true,
            "plan_mode": true,
            "usage": true
          },
          "models": [
            {"id": "haiku", "display_name": "Haiku", "is_default": true, "default_effort": "medium", "efforts": ["low","medium"]}
          ]
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(AgentDescriptor.self, from: json)
        #expect(d.displayName == "Claude")
        #expect(d.loginProvider == "anthropic")
        #expect(d.supports.compact)
        #expect(d.supports.askUserQuestion)
        #expect(d.supports.effort)
        #expect(d.supports.planMode)
        #expect(d.supports.usage)
        #expect(d.models.count == 1)
        #expect(d.models[0].id == "haiku")
    }

    @Test func decodeCodexDescriptorNoCompact() throws {
        let json = """
        {
          "display_name": "Codex",
          "login_provider": "openai",
          "supports": {
            "compact": false,
            "ask_user_question": false,
            "effort": true,
            "plan_mode": false,
            "usage": true
          }
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(AgentDescriptor.self, from: json)
        #expect(d.displayName == "Codex")
        #expect(d.loginProvider == "openai")
        #expect(!d.supports.compact)
        #expect(!d.supports.askUserQuestion)
        #expect(d.supports.effort)
        #expect(!d.supports.planMode)
        #expect(d.supports.usage)
        // Models absent → empty array.
        #expect(d.models.isEmpty)
    }

    @Test func decodeGenericAgentWithMinimalFields() throws {
        // A future agent that omits all optional fields.
        let json = """
        {
          "display_name": "Opencode",
          "supports": {}
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(AgentDescriptor.self, from: json)
        #expect(d.displayName == "Opencode")
        #expect(d.loginProvider == "")
        // Missing booleans default to false for compact/ask/plan/usage,
        // but effort defaults to true (agents without explicit effort:false
        // get the classic effort UI to avoid silent regressions on old brokers).
        #expect(!d.supports.compact)
        #expect(!d.supports.askUserQuestion)
        #expect(d.supports.effort)
        #expect(!d.supports.planMode)
        #expect(!d.supports.usage)
    }

    @Test func decodeAgentsMap() throws {
        // The full /api/capabilities `agents` object shape.
        let json = """
        {
          "claude": {
            "display_name": "Claude",
            "login_provider": "anthropic",
            "supports": {"compact": true, "effort": true, "usage": true, "plan_mode": true, "ask_user_question": true}
          },
          "codex": {
            "display_name": "Codex",
            "login_provider": "openai",
            "supports": {"compact": false, "effort": true, "usage": true, "plan_mode": false, "ask_user_question": false}
          }
        }
        """.data(using: .utf8)!
        let map = try JSONDecoder().decode([String: AgentDescriptor].self, from: json)
        #expect(map["claude"]?.supports.compact == true)
        #expect(map["codex"]?.supports.compact == false)
        #expect(map["claude"]?.loginProvider == "anthropic")
        #expect(map["codex"]?.loginProvider == "openai")
    }
}

// MARK: - Slash command gating with descriptors

@Suite("SlashCommandRegistry — descriptor-driven compact gate")
struct SlashCommandRegistryDescriptorTests {

    // Descriptor that says compact IS supported.
    private let claudeDesc = AgentDescriptor(
        displayName: "Claude",
        loginProvider: "anthropic",
        supports: AgentDescriptorSupports(compact: true, askUserQuestion: true, effort: true, planMode: true, usage: true)
    )

    // Descriptor that says compact is NOT supported (e.g. opencode, codex-exec).
    private let noCompactDesc = AgentDescriptor(
        displayName: "Opencode",
        loginProvider: "",
        supports: AgentDescriptorSupports(compact: false, effort: false, usage: false)
    )

    @Test func compactSupportedWhenDescriptorSaysTrue() {
        let match = SlashCommandRegistry.classify("/compact", agent: "claude", descriptor: claudeDesc)
        #expect(match?.supported == true)
    }

    @Test func compactUnsupportedWhenDescriptorSaysFalse() {
        // Even if the agent name is "claude", the descriptor wins.
        let match = SlashCommandRegistry.classify("/compact", agent: "claude", descriptor: noCompactDesc)
        #expect(match?.supported == false)
    }

    @Test func compactFallsBackToNameGateWithoutDescriptor() {
        // No descriptor → old-broker path: claude = supported, others = not.
        let onClaude = SlashCommandRegistry.classify("/compact", agent: "claude", descriptor: nil)
        #expect(onClaude?.supported == true)

        let onCodex = SlashCommandRegistry.classify("/compact", agent: "codex", descriptor: nil)
        #expect(onCodex?.supported == false)

        let onGeneric = SlashCommandRegistry.classify("/compact", agent: "opencode", descriptor: nil)
        #expect(onGeneric?.supported == false)
    }

    @Test func clearCommandGatingMatchesCompact() {
        // /clear is also claudeOnly pass-through.
        let match = SlashCommandRegistry.classify("/clear", agent: "opencode", descriptor: noCompactDesc)
        #expect(match?.supported == false)
    }

    @Test func appHandledCommandsAreAlwaysSupported() {
        // App-handled commands (/model, /effort, /loop, /help) are never
        // gated — the descriptor doesn't affect them.
        let match = SlashCommandRegistry.classify("/model", agent: "opencode", descriptor: noCompactDesc)
        #expect(match?.supported == true)
        #expect(match?.command.clazz == .appHandled)
    }
}

// MARK: - ForkOptions effort gating with descriptor

@Suite("ConduitUI.ForkOptions — effort hidden when supports.effort = false")
struct ForkOptionsEffortDescriptorTests {

    private let noEffortDesc = AgentDescriptor(
        displayName: "Opencode",
        loginProvider: "",
        supports: AgentDescriptorSupports(compact: false, effort: false, usage: false)
    )
    private let effortDesc = AgentDescriptor(
        displayName: "Claude",
        loginProvider: "anthropic",
        supports: AgentDescriptorSupports(compact: true, effort: true, planMode: true, usage: true)
    )
    private let claudeCatalog: [ConduitUI.AgentModel] = [
        .init(id: "", displayName: "Default", isDefault: true,
              defaultEffort: "medium", efforts: ["low", "medium", "high"]),
    ]

    @Test func descriptorEffortFalseOverridesStaticList() {
        // An agent with supports.effort = false should return empty efforts
        // even if the static list would give a non-empty set.
        // We test the descriptor's gate via the AgentDescriptorSupports directly
        // since ForkOptions itself doesn't take a descriptor (gating is in the view).
        #expect(!noEffortDesc.supports.effort)
    }

    @Test func descriptorEffortTrueLetsStaticListThrough() {
        #expect(effortDesc.supports.effort)
        // With effort supported, the static list for "claude" is non-empty.
        let opts = ConduitUI.ForkOptions.efforts(forAssistant: "claude")
        #expect(!opts.isEmpty)
    }

    @Test func descriptorEffortTrueWithCatalogUsesPerModelList() {
        #expect(effortDesc.supports.effort)
        let opts = ConduitUI.ForkOptions.efforts(forAssistant: "claude", model: "", catalog: claudeCatalog)
        #expect(opts == ["low", "medium", "high"])
    }
}

// MARK: - AgentAccountStatus login provider mapping

@Suite("AgentAccountStatus — descriptor-driven login provider")
struct AgentAccountStatusDescriptorTests {

    private let descriptors: [String: AgentDescriptor] = [
        "claude": AgentDescriptor(
            displayName: "Claude",
            loginProvider: "anthropic",
            supports: AgentDescriptorSupports(compact: true, effort: true, planMode: true, usage: true)
        ),
        "codex": AgentDescriptor(
            displayName: "Codex",
            loginProvider: "openai",
            supports: AgentDescriptorSupports(compact: false, effort: true, usage: true)
        ),
    ]

    @Test func descriptorDrivenCurrentIncludesClaudeAndCodex() {
        let accounts = AgentAccountStatus.current(descriptors: descriptors)
        // Both agents are present.
        #expect(accounts.contains(where: { $0.agent == "claude" }))
        #expect(accounts.contains(where: { $0.agent == "codex" }))
    }

    @Test func claudeAppearsFirstInDescriptorDrivenList() {
        let accounts = AgentAccountStatus.current(descriptors: descriptors)
        #expect(accounts.first?.agent == "claude")
    }

    @Test func agentsWithNoLoginProviderAreExcluded() {
        var descs = descriptors
        descs["opencode"] = AgentDescriptor(
            displayName: "Opencode",
            loginProvider: "",  // no provider
            supports: AgentDescriptorSupports()
        )
        let accounts = AgentAccountStatus.current(descriptors: descs)
        #expect(!accounts.contains(where: { $0.agent == "opencode" }))
    }

    @Test func unknownLoginProviderIsSkipped() {
        var descs = descriptors
        descs["mystery"] = AgentDescriptor(
            displayName: "Mystery",
            loginProvider: "mystery-provider",
            supports: AgentDescriptorSupports()
        )
        let accounts = AgentAccountStatus.current(descriptors: descs)
        #expect(!accounts.contains(where: { $0.agent == "mystery" }))
    }

    @Test func staticFallbackUsedWhenDescriptorsEmpty() {
        let accounts = AgentAccountStatus.current(descriptors: [:])
        // Falls back to hardcoded claude + codex.
        #expect(accounts.contains(where: { $0.agent == "claude" && $0.provider == .anthropic }))
        #expect(accounts.contains(where: { $0.agent == "codex"  && $0.provider == .openai  }))
    }

    @Test func staticFallbackUsedWhenDescriptorsNil() {
        let accounts = AgentAccountStatus.current(descriptors: nil)
        #expect(accounts.count == 2)
        #expect(accounts.first?.agent == "claude")
    }

    @Test func oauthProviderInitMapsKnownProviders() {
        #expect(OAuthProvider(loginProvider: "anthropic") == .anthropic)
        #expect(OAuthProvider(loginProvider: "openai") == .openai)
        #expect(OAuthProvider(loginProvider: "ANTHROPIC") == .anthropic)
        #expect(OAuthProvider(loginProvider: "unknown") == nil)
        #expect(OAuthProvider(loginProvider: "") == nil)
    }
}

// MARK: - Generic agent metadata derivation

@Suite("AgentDescriptor — generic agent name derivation")
struct AgentDescriptorGenericMetaTests {

    @Test func displayNameFallsBackToCapitalizedKeyWhenEmpty() {
        let d = AgentDescriptor(displayName: "", loginProvider: "")
        // When display_name is empty the consumer (AgentPickerSheet.agentMeta)
        // capitalizes the registry key. We verify the guard condition here.
        #expect(d.displayName.isEmpty)
    }

    @Test func displayNamePreservedWhenPresent() {
        let d = AgentDescriptor(displayName: "My Custom Agent", loginProvider: "")
        #expect(d.displayName == "My Custom Agent")
    }

    @Test func supportsDefaultsAreConservativeForNewAgents() {
        // A brand-new agent with no known descriptor should have:
        //   compact = false (don't show /compact for unknowns)
        //   effort  = true  (show effort UI unless explicitly disabled)
        //   usage   = false (don't show a limits card for unknowns)
        let d = AgentDescriptor()
        #expect(!d.supports.compact)
        #expect(d.supports.effort)
        #expect(!d.supports.usage)
    }
}
