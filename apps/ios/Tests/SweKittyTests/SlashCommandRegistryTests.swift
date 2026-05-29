import Testing
@testable import SweKitty

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
