package sh.nikhil.conduit.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType

/**
 * Android mirror of iOS `ConduitMarkdownHeadingScaler.swift`
 * (PLAN-CONDUIT-VISUAL-PARITY PR 4 / audit §A.2.2 / §B.2).
 *
 * Compose's Text path doesn't tokenise markdown into runs the way
 * SwiftUI's `AttributedString(markdown:)` does, so the iOS approach
 * (walk presentation-intent runs) doesn't translate. Instead this
 * helper does a per-line scan: lines starting with `#` / `##` /
 * `###` / `####` are stamped with a `SpanStyle` carrying the scaled
 * font size + semibold weight; the `#` prefix itself is stripped so
 * the rendered heading reads naturally.
 *
 * The multipliers match iOS verbatim — same source-of-truth so the
 * two platforms stay aligned without per-platform drift.
 */
object ConduitMarkdownHeadingScaler {

    val multipliers: Map<Int, Float> = mapOf(
        1 to 1.43f,
        2 to 1.30f,
        3 to 1.15f,
        4 to 1.07f,
    )

    fun multiplier(level: Int): Float? = multipliers[level]

    /**
     * Build an [AnnotatedString] where each markdown heading line is
     * sized at `basePointSize x multiplier(level)` and non-heading
     * lines are parsed for inline bold/italic/code spans via
     * [appendInlineSpans]. Output preserves the original newlines so
     * block geometry does not shift.
     */
    fun scaledAnnotated(text: String, basePointSize: Float): AnnotatedString {
        val builder = AnnotatedString.Builder()
        val lines = text.split("\n")
        for ((idx, line) in lines.withIndex()) {
            val match = HEADING_REGEX.matchEntire(line)
            if (match != null) {
                val level = match.groupValues[1].length
                val body = match.groupValues[2]
                val mult = multipliers[level]
                if (mult != null) {
                    val start = builder.length
                    builder.append(body)
                    builder.addStyle(
                        SpanStyle(
                            fontSize = TextUnit(basePointSize * mult, TextUnitType.Sp),
                            fontWeight = FontWeight.SemiBold,
                        ),
                        start,
                        builder.length,
                    )
                } else {
                    appendInlineSpans(builder, line)
                }
            } else {
                appendInlineSpans(builder, line)
            }
            if (idx < lines.lastIndex) builder.append("\n")
        }
        return builder.toAnnotatedString()
    }

    /**
     * Build an [AnnotatedString] from [text] with only inline
     * bold/italic/code spans applied — no heading scaling. Used by
     * [StreamingSpineRow] where the content is a single prose run
     * (no block structure) and must match the settled paragraph look.
     * Cached by callers via [ParsedMarkdownCache].
     */
    fun inlineAnnotated(text: String): AnnotatedString {
        val builder = AnnotatedString.Builder()
        appendInlineSpans(builder, text)
        return builder.toAnnotatedString()
    }

    /**
     * Append [text] to [builder] with inline markdown spans applied.
     * Handles bold (`**...**`), italic (`*...*`), and code (`` `...` ``).
     * `_`-based bold/italic is intentionally excluded to avoid false
     * positives on snake_case identifiers common in agent output.
     * Unclosed markers at the end of [text] (as occurs in partial
     * streaming content) are emitted as literal characters rather than
     * consuming the remainder, so partial streams are safe.
     *
     * Precedence: code backtick first (no nesting inside code), then
     * bold `**` before italic `*` so double-star is not split into two
     * italic opens.
     *
     * This is a pragmatic scanner for the tokens that appear most in
     * agent output — not a full CommonMark engine.
     */
    private fun appendInlineSpans(builder: AnnotatedString.Builder, text: String) {
        var i = 0
        val n = text.length
        while (i < n) {
            when {
                // Inline code: `...`
                text[i] == '`' -> {
                    val closeIdx = text.indexOf('`', i + 1)
                    if (closeIdx != -1) {
                        val start = builder.length
                        builder.append(text.substring(i + 1, closeIdx))
                        builder.addStyle(SpanStyle(fontFamily = FontFamily.Monospace), start, builder.length)
                        i = closeIdx + 1
                    } else {
                        // Unclosed backtick: emit literal and stop scanning.
                        builder.append(text.substring(i))
                        i = n
                    }
                }
                // Bold: **...**
                // Check `**` before single `*` so a double-star is not mis-parsed
                // as two italic opens. `__...__` is intentionally excluded to avoid
                // false positives on identifiers like `my__var__name`.
                i + 1 < n && text[i] == '*' && text[i + 1] == '*' -> {
                    val closeIdx = text.indexOf("**", i + 2)
                    if (closeIdx != -1) {
                        val start = builder.length
                        appendInlineSpans(builder, text.substring(i + 2, closeIdx))
                        builder.addStyle(SpanStyle(fontWeight = FontWeight.Bold), start, builder.length)
                        i = closeIdx + 2
                    } else {
                        // Unclosed bold marker: emit literal.
                        builder.append("**")
                        i += 2
                    }
                }
                // Italic: *...*
                // Only `*` (not `_`) to avoid italicising snake_case identifiers.
                text[i] == '*' -> {
                    val closeIdx = text.indexOf('*', i + 1)
                    if (closeIdx != -1) {
                        val start = builder.length
                        appendInlineSpans(builder, text.substring(i + 1, closeIdx))
                        builder.addStyle(SpanStyle(fontStyle = FontStyle.Italic), start, builder.length)
                        i = closeIdx + 1
                    } else {
                        // Unclosed italic marker: emit literal.
                        builder.append('*')
                        i++
                    }
                }
                else -> {
                    builder.append(text[i])
                    i++
                }
            }
        }
    }

    // `^#{1,6}\s+(.+)$` — capture group 1 is the `#` run (so we know
    // the level), group 2 is the heading text. Trailing whitespace is
    // kept in the body so the rendered heading matches the source.
    private val HEADING_REGEX = Regex("^(#{1,6})\\s+(.+)$")
}
