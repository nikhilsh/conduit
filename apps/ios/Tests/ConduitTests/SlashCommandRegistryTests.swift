import Testing
@testable import Conduit

/// Pins the slash-command classifier. Mirror of
/// `apps/android/.../ui/SlashCommandRegistryTest.kt` — the command-name
/// set must stay identical across platforms.
@Suite("SlashCommandRegistry — classify + autocomplete")
struct SlashCommandRegistryTests {

    @Test func nonSlashTextIsNotACommand() {
        #expect(SlashCommandRegistry.classify("hello world", agent: "claude") == nil)
        #expect(SlashCommandRegistry.classify("use /compact later", agent: "claude") == nil)
        #expect(SlashCommandRegistry.classify("", agent: "claude") == nil)
        #expect(SlashCommandRegistry.classify("/", agent: "claude") == nil)
    }

    @Test func unknownSlashIsNotMatched() {
        #expect(SlashCommandRegistry.classify("/frobnicate", agent: "claude") == nil)
    }

    @Test func passThroughIsClaudeOnly() {
        let onClaude = SlashCommandRegistry.classify("/compact", agent: "claude")
        #expect(onClaude?.command.name == "compact")
        #expect(onClaude?.command.clazz == .passThrough)
        #expect(onClaude?.supported == true)

        let onCodex = SlashCommandRegistry.classify("/compact", agent: "codex")
        #expect(onCodex?.command.name == "compact")
        #expect(onCodex?.supported == false)
    }

    @Test func aliasesResolve() {
        #expect(SlashCommandRegistry.classify("/cost", agent: "claude")?.command.name == "usage")
        #expect(SlashCommandRegistry.classify("/stats", agent: "claude")?.command.name == "usage")
    }

    @Test func usageAndContextAreAppHandled() {
        // Terminal-only display panels: app-handled (show a note), NOT
        // pass-through — passing them to the agent yields a vague reply.
        #expect(SlashCommandRegistry.classify("/usage", agent: "claude")?.command.clazz == .appHandled)
        #expect(SlashCommandRegistry.classify("/context", agent: "claude")?.command.clazz == .appHandled)
        // …while /compact stays a real pass-through.
        #expect(SlashCommandRegistry.classify("/compact", agent: "claude")?.command.clazz == .passThrough)
    }

    @Test func argsArePreservedAndTrimmed() {
        let m = SlashCommandRegistry.classify("/model   opus  ", agent: "claude")
        #expect(m?.command.name == "model")
        #expect(m?.args == "opus")
        #expect(m?.command.clazz == .appHandled)
        // App-handled commands are agent-agnostic — supported on codex too.
        #expect(SlashCommandRegistry.classify("/loop 30 ping", agent: "codex")?.supported == true)
    }

    @Test func matchIsCaseInsensitive() {
        #expect(SlashCommandRegistry.classify("/COMPACT", agent: "CLAUDE")?.command.name == "compact")
    }

    /// `/clear` is gated on its OWN capability (supports.clear), not on
    /// supports.compact, with a compact fallback when the broker is too old to
    /// state clear. Regression test for the "/clear mis-gated on compact" bug.
    @Test func clearGatedOnClearCapabilityNotCompact() {
        func desc(compact: Bool, clear: Bool?) -> AgentDescriptor {
            AgentDescriptor(supports: AgentDescriptorSupports(compact: compact, clear: clear))
        }
        // clear=true → supported even where compact=false.
        #expect(SlashCommandRegistry.classify("/clear", agent: "codex",
            descriptor: desc(compact: false, clear: true))?.supported == true)
        // clear=false → unsupported even where compact=true.
        #expect(SlashCommandRegistry.classify("/clear", agent: "claude",
            descriptor: desc(compact: true, clear: false))?.supported == false)
        // clear=nil (old broker) → fall back to compact.
        #expect(SlashCommandRegistry.classify("/clear", agent: "claude",
            descriptor: desc(compact: true, clear: nil))?.supported == true)
        #expect(SlashCommandRegistry.classify("/clear", agent: "claude",
            descriptor: desc(compact: false, clear: nil))?.supported == false)
        // No descriptor → static claude-name check (old broker / no capabilities).
        #expect(SlashCommandRegistry.classify("/clear", agent: "claude")?.supported == true)
        #expect(SlashCommandRegistry.classify("/clear", agent: "codex")?.supported == false)
        // /compact still reads compact, unaffected by the clear flag.
        #expect(SlashCommandRegistry.classify("/compact", agent: "claude",
            descriptor: desc(compact: false, clear: true))?.supported == false)
    }

    @Test func autocompleteFiltersByPrefix() {
        let names = SlashCommandRegistry.autocomplete("/c").map(\.name)
        #expect(names.contains("compact"))
        #expect(names.contains("clear"))
        #expect(names.contains("context"))
        #expect(names.contains("usage")) // matched via the "cost" alias
        #expect(!names.contains("model"))

        #expect(SlashCommandRegistry.autocomplete("hello").isEmpty)
        #expect(SlashCommandRegistry.autocomplete("/model opus").isEmpty)
        #expect(SlashCommandRegistry.autocomplete("/").count == SlashCommandRegistry.commands.count)
    }
}
