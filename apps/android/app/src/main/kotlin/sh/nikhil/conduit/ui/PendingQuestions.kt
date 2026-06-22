package sh.nikhil.conduit.ui

/**
 * One question inside a pending-input (AskUserQuestion) prompt: its text
 * plus its own options. AskUserQuestion can carry several of these; the
 * broker flattens them into `"<q1>\n1. a\n2. b\n\n<q2>\n1. c\n2. d"` and
 * core flattens the options into one array, so we recover the grouping
 * from `content`. Mirror of iOS `ConduitUI.PendingQuestion`.
 */

/**
 * The resolution state decoded from a persisted pending-input card. Carries
 * whether the user actually answered and, when they did, which option they
 * chose. Mirror of iOS `ConduitUI.ChatViewModel.PendingResolution`.
 */
data class PendingResolution(
    /** True when the user answered (a tap or typed text). False for timed-out / no-answer. */
    val answered: Boolean,
    /** The chosen option text, or null when there is no answer. */
    val answer: String?,
)
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
     * askcontrol.go`). Carried inside the text so no broker -> core -> app
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
     * Leading token of the resolution marker the broker appends to an
     * answered pending-input card's content right after the sentinel. The
     * full line looks like:
     *   `[[conduit:resolved]]{"answered":true,"answer":"Option A"}`
     * Core strips it on the live path (display_content); we strip it
     * defensively here so it never renders as question prose on the
     * HTTP-fetch (archived/saved-transcript) path. Byte-identical to the
     * broker and iOS `ConduitUI.ChatViewModel.pendingResolvedMarker`.
     */
    const val PENDING_RESOLVED_MARKER = "[[conduit:resolved]]"

    /**
     * Decode the resolution state from a persisted pending-input card's
     * content by scanning for the [PENDING_RESOLVED_MARKER] line. Returns
     * null when no marker is present — an unanswered card or a legacy
     * transcript written before this feature (backward-compatible). Mirror
     * of iOS `ConduitUI.ChatViewModel.parsePendingResolution`.
     */
    fun parsePendingResolution(content: String): PendingResolution? {
        for (raw in content.split("\n")) {
            val line = raw.trim()
            if (!line.startsWith(PENDING_RESOLVED_MARKER)) continue
            val json = line.removePrefix(PENDING_RESOLVED_MARKER)
            return try {
                val obj = org.json.JSONObject(json)
                val answered = obj.optBoolean("answered", false)
                val answer = obj.optString("answer", "").takeIf { it.isNotEmpty() }
                PendingResolution(answered = answered, answer = answer)
            } catch (e: Exception) {
                null
            }
        }
        return null
    }

    /**
     * Strip the control lines ([PENDING_INPUT_SENTINEL] and any
     * [PENDING_RESOLVED_MARKER]-prefixed line) from a pending-input card's
     * content, then trim whitespace. The result is a normalized key that is
     * identical for the original (marker-free) and the resolved
     * (marker-carrying) versions of the same card.
     */
    fun strippedKey(content: String): String =
        content.split("\n")
            .filter { line ->
                val t = line.trim()
                t != PENDING_INPUT_SENTINEL && !t.startsWith(PENDING_RESOLVED_MARKER)
            }
            .joinToString("\n")
            .trim()

    /**
     * Recover per-question groups from a pending-input `content` body.
     * Blocks are separated by blank lines; within a block the leading prose
     * is the question and the numbered/bulleted lines are its options. A
     * trailing multi-select marker on the prompt is stripped into
     * [PendingQuestion.multiSelect].
     *
     * Defensively drops both the [PENDING_INPUT_SENTINEL] and any
     * [PENDING_RESOLVED_MARKER] lines — core strips both on the live path;
     * this covers the HTTP-fetch (archive/transcript) path. Mirror of iOS
     * `parsePendingQuestions`.
     */
    fun parse(content: String): List<PendingQuestion> {
        // Defensively drop the broker sentinel line AND any resolution-marker
        // line if either survived to the client (core strips them on the live
        // path; the HTTP-fetch path may carry the resolved marker so the card
        // can rehydrate its state, but the marker must never render as prose).
        val cleaned = content.split("\n")
            .filter {
                val t = it.trim()
                t != PENDING_INPUT_SENTINEL && !t.startsWith(PENDING_RESOLVED_MARKER)
            }
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
