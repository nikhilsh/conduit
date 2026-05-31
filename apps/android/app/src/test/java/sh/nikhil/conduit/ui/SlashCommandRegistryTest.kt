package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the slash-command classifier. Mirror of
 * `apps/ios/Tests/ConduitTests/SlashCommandRegistryTests.swift` — the
 * command-name set must stay identical across platforms.
 */
class SlashCommandRegistryTest {

    @Test fun nonSlashTextIsNotACommand() {
        assertNull(SlashCommandRegistry.classify("hello world", "claude"))
        assertNull(SlashCommandRegistry.classify("use /compact later", "claude"))
        assertNull(SlashCommandRegistry.classify("", "claude"))
        assertNull(SlashCommandRegistry.classify("/", "claude"))
    }

    @Test fun unknownSlashIsNotMatched() {
        assertNull(SlashCommandRegistry.classify("/frobnicate", "claude"))
    }

    @Test fun passThroughIsClaudeOnly() {
        val onClaude = SlashCommandRegistry.classify("/compact", "claude")!!
        assertEquals("compact", onClaude.command.name)
        assertEquals(SlashCommandClass.PASS_THROUGH, onClaude.command.clazz)
        assertTrue(onClaude.supported)

        // Same command on a codex session is recognised but unsupported.
        val onCodex = SlashCommandRegistry.classify("/compact", "codex")!!
        assertEquals("compact", onCodex.command.name)
        assertFalse(onCodex.supported)
    }

    @Test fun aliasesResolve() {
        assertEquals("usage", SlashCommandRegistry.classify("/cost", "claude")!!.command.name)
        assertEquals("usage", SlashCommandRegistry.classify("/stats", "claude")!!.command.name)
    }

    @Test fun usageAndContextAreAppHandled() {
        // Terminal-only display panels: app-handled (show a note), NOT
        // pass-through — passing them to the agent yields a vague reply.
        assertEquals(SlashCommandClass.APP_HANDLED, SlashCommandRegistry.classify("/usage", "claude")!!.command.clazz)
        assertEquals(SlashCommandClass.APP_HANDLED, SlashCommandRegistry.classify("/context", "claude")!!.command.clazz)
        // …while /compact stays a real pass-through.
        assertEquals(SlashCommandClass.PASS_THROUGH, SlashCommandRegistry.classify("/compact", "claude")!!.command.clazz)
    }

    @Test fun argsArePreservedAndTrimmed() {
        val m = SlashCommandRegistry.classify("/model   opus  ", "claude")!!
        assertEquals("model", m.command.name)
        assertEquals("opus", m.args)
        assertEquals(SlashCommandClass.APP_HANDLED, m.command.clazz)
        // App-handled commands are agent-agnostic — supported on codex too.
        assertTrue(SlashCommandRegistry.classify("/loop 30 ping", "codex")!!.supported)
    }

    @Test fun matchIsCaseInsensitive() {
        assertEquals("compact", SlashCommandRegistry.classify("/COMPACT", "CLAUDE")!!.command.name)
    }

    @Test fun autocompleteFiltersByPrefix() {
        // "/c" → compact, clear, context, (cost alias of usage)
        val names = SlashCommandRegistry.autocomplete("/c").map { it.name }
        assertTrue(names.containsAll(listOf("compact", "clear", "context")))
        assertTrue(names.contains("usage")) // matched via the "cost" alias
        assertFalse(names.contains("model"))

        // No leading slash, or already typing args → no suggestions.
        assertTrue(SlashCommandRegistry.autocomplete("hello").isEmpty())
        assertTrue(SlashCommandRegistry.autocomplete("/model opus").isEmpty())

        // Bare "/" lists everything.
        assertEquals(SlashCommandRegistry.commands.size, SlashCommandRegistry.autocomplete("/").size)
    }
}
