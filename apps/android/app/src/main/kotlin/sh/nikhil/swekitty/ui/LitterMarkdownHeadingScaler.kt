package sh.nikhil.swekitty.ui

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType

/**
 * Android mirror of iOS `LitterMarkdownHeadingScaler.swift`
 * (PLAN-LITTER-VISUAL-PARITY PR 4 / audit §A.2.2 / §B.2).
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
object LitterMarkdownHeadingScaler {

    val multipliers: Map<Int, Float> = mapOf(
        1 to 1.43f,
        2 to 1.30f,
        3 to 1.15f,
        4 to 1.07f,
    )

    fun multiplier(forLevel level: Int): Float? = multipliers[level]

    /**
     * Build an [AnnotatedString] where each markdown heading line is
     * sized at `basePointSize × multiplier(level)`. Non-heading lines
     * are appended verbatim and inherit the outer `Text(style = ...)`
     * font size. Output preserves the original newlines so block
     * geometry doesn't shift.
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
                    builder.append(line)
                }
            } else {
                builder.append(line)
            }
            if (idx < lines.lastIndex) builder.append("\n")
        }
        return builder.toAnnotatedString()
    }

    // `^#{1,6}\s+(.+)$` — capture group 1 is the `#` run (so we know
    // the level), group 2 is the heading text. Trailing whitespace is
    // kept in the body so the rendered heading matches the source.
    private val HEADING_REGEX = Regex("^(#{1,6})\\s+(.+)$")
}
