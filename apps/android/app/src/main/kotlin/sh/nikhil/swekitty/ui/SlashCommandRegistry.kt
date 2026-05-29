package sh.nikhil.swekitty.ui

/**
 * Recognises `/`-prefixed commands typed in the chat composer and
 * classifies how each should be routed. Pure data + parsing — no Compose,
 * no I/O — so it unit-tests under plain JUnit. Mirror of
 * `apps/ios/Sources/SlashCommandRegistry.swift`; keep the two in sync
 * (a test pins the command-name set on each platform).
 *
 * See docs/SLASH-COMMANDS.md for the design + the per-CLI capability
 * matrix that drives [SlashCommand.claudeOnly].
 */
enum class SlashCommandClass {
    /** Sent to the agent unchanged. Only the Claude stream-json backend
     *  intercepts these (Codex `exec` can't — openai/codex#3641). */
    PASS_THROUGH,

    /** swe-kitty handles it on the client; never reaches the agent. */
    APP_HANDLED,
}

data class SlashCommand(
    val name: String,
    val clazz: SlashCommandClass,
    val description: String,
    val aliases: List<String> = emptyList(),
    /** Pass-through commands only work on a Claude stream-json session. */
    val claudeOnly: Boolean = false,
)

/** Result of [SlashCommandRegistry.classify]. */
data class SlashCommandMatch(
    val command: SlashCommand,
    /** Everything after the command token, trimmed (e.g. `opus` for `/model opus`). */
    val args: String,
    /** False when a pass-through command is used on a non-Claude agent —
     *  the caller surfaces an in-chat "not supported with this agent" note. */
    val supported: Boolean,
)

object SlashCommandRegistry {

    val commands: List<SlashCommand> = listOf(
        SlashCommand("compact", SlashCommandClass.PASS_THROUGH, "Summarize the conversation to free up context", claudeOnly = true),
        SlashCommand("clear", SlashCommandClass.PASS_THROUGH, "Start a fresh context", claudeOnly = true),
        SlashCommand("context", SlashCommandClass.PASS_THROUGH, "Show context-window usage", claudeOnly = true),
        SlashCommand("usage", SlashCommandClass.PASS_THROUGH, "Show token usage and cost", aliases = listOf("cost", "stats"), claudeOnly = true),
        SlashCommand("model", SlashCommandClass.APP_HANDLED, "Fork the session onto a different model"),
        SlashCommand("effort", SlashCommandClass.APP_HANDLED, "Fork with a different reasoning effort"),
        SlashCommand("loop", SlashCommandClass.APP_HANDLED, "Repeat a prompt on a loop"),
        SlashCommand("help", SlashCommandClass.APP_HANDLED, "List the available slash commands"),
    )

    private fun lookup(name: String): SlashCommand? {
        val n = name.lowercase()
        return commands.firstOrNull { it.name == n || it.aliases.contains(n) }
    }

    /**
     * Classify [input] for a session running [agent] ("claude" / "codex" / …).
     * Returns null when [input] isn't a recognised slash command (so the
     * caller sends it as a normal chat message).
     */
    fun classify(input: String, agent: String): SlashCommandMatch? {
        val trimmed = input.trimStart()
        if (!trimmed.startsWith("/")) return null
        val body = trimmed.substring(1)
        val name = body.takeWhile { !it.isWhitespace() }
        if (name.isEmpty()) return null
        val cmd = lookup(name) ?: return null
        val args = body.drop(name.length).trim()
        val supported = !(cmd.claudeOnly && !agent.equals("claude", ignoreCase = true))
        return SlashCommandMatch(cmd, args, supported)
    }

    /**
     * Autocomplete candidates for a [draft] that begins with `/`. Filters
     * by the typed command prefix (name or alias). Empty when the draft
     * isn't a bare command token (e.g. already has arguments).
     */
    fun autocomplete(draft: String): List<SlashCommand> {
        val trimmed = draft.trimStart()
        if (!trimmed.startsWith("/")) return emptyList()
        val body = trimmed.substring(1)
        // Only suggest while typing the command itself (no space yet).
        if (body.any { it.isWhitespace() }) return emptyList()
        val typed = body.lowercase()
        return commands.filter { cmd ->
            cmd.name.startsWith(typed) || cmd.aliases.any { it.startsWith(typed) }
        }
    }
}
