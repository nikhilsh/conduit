package sh.nikhil.conduit.ui

/**
 * One question inside a pending-input (AskUserQuestion) prompt: its text
 * plus its own options. AskUserQuestion can carry several of these; the
 * broker flattens them into `"<q1>\n1. a\n2. b\n\n<q2>\n1. c\n2. d"` and
 * core flattens the options into one array, so we recover the grouping
 * from `content`. Mirror of iOS `ConduitUI.PendingQuestion`.
 */
data class PendingQuestion(
    val prompt: String,
    val options: List<String>,
    /**
     * True when the broker marked this question multi-select (the
     * " (select all that apply)" marker the card strips from the prompt).
     * Multi-select questions render checkboxes + Send instead of
     * tap-to-send.
     */
    val multiSelect: Boolean = false,
)

/**
 * Pure parser for pending-input card content. Mirror of iOS
 * `ConduitUI.ChatViewModel.parsePendingQuestions` so both platforms group
 * questions and detect multi-select identically. Unit-tested.
 */
object PendingQuestions {
    /**
     * The exact marker the broker's `askUserQuestionContent` appends to a
     * multi-select question's prompt line (see `broker/internal/session/
     * askcontrol.go`). Carried inside the text so no broker → core → app
     * schema change was needed. Byte-identical to the broker / iOS constant.
     */
    const val MULTI_SELECT_MARKER = " (select all that apply)"

    /**
     * The deterministic pending-input sentinel the broker prepends to a
     * genuine AskUserQuestion. Core normally strips it before the item
     * reaches us; this defensive strip covers the raw-chatLog fallback.
     */
    const val PENDING_INPUT_SENTINEL = "[[conduit:needs-input]]"

    /**
     * Recover per-question groups from a pending-input `content` body.
     * Blocks are separated by blank lines; within a block the leading prose
     * is the question and the numbered/bulleted lines are its options. A
     * trailing multi-select marker on the prompt is stripped into
     * [PendingQuestion.multiSelect].
     */
    fun parse(content: String): List<PendingQuestion> {
        // Defensively drop the broker sentinel line if it survived to the
        // client (core strips it on the typed path).
        val cleaned = content.split("\n")
            .filter { it.trim() != PENDING_INPUT_SENTINEL }
            .joinToString("\n")
        val result = mutableListOf<PendingQuestion>()
        for (block in cleaned.split("\n\n")) {
            val prompt = mutableListOf<String>()
            val options = mutableListOf<String>()
            for (rawLine in block.split("\n")) {
                val line = rawLine.trim()
                if (line.isEmpty()) continue
                val opt = optionText(line)
                if (opt != null) {
                    options += opt
                } else if (options.isEmpty()) {
                    // Stray prose AFTER options started is dropped — the
                    // broker never emits it for AskUserQuestion.
                    prompt += line
                }
            }
            var promptText = prompt.joinToString("\n")
            var multi = false
            if (promptText.endsWith(MULTI_SELECT_MARKER)) {
                multi = true
                promptText = promptText.dropLast(MULTI_SELECT_MARKER.length).trim()
            }
            if (options.isNotEmpty() || promptText.isNotEmpty()) {
                result += PendingQuestion(prompt = promptText, options = options, multiSelect = multi)
            }
        }
        return result
    }

    /**
     * Strip a numbered (`1.`/`1)`) or bulleted (`-`/`*`) option marker,
     * returning the option text, or null when the line isn't an option.
     * Mirror of iOS `optionText`.
     */
    private fun optionText(line: String): String? {
        if (line.startsWith("- ") || line.startsWith("* ")) {
            val text = line.drop(2).trim()
            return text.ifEmpty { null }
        }
        var i = 0
        while (i < line.length && line[i].isDigit()) i++
        if (i == 0) return null // no leading digits
        if (i >= line.length || (line[i] != '.' && line[i] != ')')) return null
        val after = i + 1
        if (after >= line.length || line[after] != ' ') return null
        val text = line.substring(after).trim()
        return text.ifEmpty { null }
    }
}
