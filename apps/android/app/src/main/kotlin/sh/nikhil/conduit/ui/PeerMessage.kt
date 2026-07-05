package sh.nikhil.conduit.ui

/**
 * Parses the framed peer-session message block broker emits from
 * `framePeerMessage` (broker/internal/session/peerchat.go). A peer message
 * always arrives as a **user-role** chat `view_event` whose `content` is:
 *
 *   [CONDUIT PEER MESSAGE -- from another agent session on this box, NOT from the human user]
 *   From session: <uuid> ("<title>")      (title / whole line may be absent)
 *   ...boilerplate (untrusted-data preamble, reply hint)...
 *   ---
 *   <body>
 *   [END CONDUIT PEER MESSAGE]
 *
 * [PeerMessage.parse] extracts the sender id/title and the body, stripping
 * the envelope boilerplate so the chat card never shows it.
 */
object PeerMessage {
    /**
     * The exact leading marker gating detection. Callers must check
     * `content.startsWith(MARKER)` on a **user-role** event before treating
     * it as a peer message -- content-only sniffing mid-message classified
     * unrelated messages incorrectly before (#699); this stays a strict,
     * anchored prefix check.
     */
    const val MARKER = "[CONDUIT PEER MESSAGE"

    private const val END_MARKER = "[END CONDUIT PEER MESSAGE]"
    private const val FROM_SESSION_PREFIX = "From session: "

    data class Parsed(
        /** Sender session id, or null when unidentified / absent. */
        val fromSessionId: String?,
        /** Sender session title, or null when absent (untitled or an
         *  external/unidentified caller). */
        val fromTitle: String?,
        /** The message body with the envelope boilerplate stripped. */
        val body: String,
    )

    /** Returns null when [content] does not start with the exact marker. */
    fun parse(content: String): Parsed? {
        if (!content.startsWith(MARKER)) return null
        val lines = content.split("\n")

        var fromId: String? = null
        var fromTitle: String? = null
        // The "From session: ..." / "From: ..." line is always the second
        // line, but scan a short defensive window in case framing shifts.
        for (line in lines.drop(1).take(4)) {
            val idx = line.indexOf(FROM_SESSION_PREFIX)
            if (idx < 0) continue
            val rest = line.substring(idx + FROM_SESSION_PREFIX.length)
            val parenIdx = rest.indexOf('(')
            if (parenIdx >= 0) {
                fromId = rest.substring(0, parenIdx).trim()
                val afterParen = rest.substring(parenIdx)
                val firstQuote = afterParen.indexOf('"')
                val lastQuote = afterParen.lastIndexOf('"')
                if (firstQuote >= 0 && lastQuote > firstQuote) {
                    fromTitle = afterParen.substring(firstQuote + 1, lastQuote)
                }
            } else {
                fromId = rest.trim()
            }
            break
        }
        if (fromId?.isEmpty() == true) fromId = null
        if (fromTitle?.isEmpty() == true) fromTitle = null

        val sepIdx = lines.indexOfFirst { it.trim() == "---" }
        val endIdx = lines.indexOfFirst { it.trim() == END_MARKER }
        if (sepIdx < 0 || endIdx < 0 || endIdx <= sepIdx) {
            // Malformed frame (no separator / no end marker): fall back to
            // showing everything after the first (marker) line.
            val rest = lines.drop(1).joinToString("\n").trim()
            return Parsed(fromSessionId = fromId, fromTitle = fromTitle, body = rest)
        }
        val body = lines.subList(sepIdx + 1, endIdx).joinToString("\n").trim()
        return Parsed(fromSessionId = fromId, fromTitle = fromTitle, body = body)
    }

    /**
     * Header label: the sender title, else the first 8 chars of the
     * session id, else a generic fallback.
     */
    fun displayLabel(parsed: Parsed): String {
        if (!parsed.fromTitle.isNullOrEmpty()) return parsed.fromTitle
        if (!parsed.fromSessionId.isNullOrEmpty()) return parsed.fromSessionId.take(8)
        return "another session"
    }
}
