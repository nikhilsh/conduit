package sh.nikhil.swekitty.ui

/**
 * Pure, Compose-free markdown → block-structure parser. The fix for the
 * "cramped + structurally collapsed" chat rendering (Android parity of
 * the iOS chat-polish change): the previous pipeline shoved an entire
 * markdown string into a single `Text`, so GFM tables came out as
 * run-on `| a | b |` text, headings jammed straight into the next line,
 * and paragraphs/lists/code had no vertical rhythm.
 *
 * Splitting markdown into typed [MdBlock]s lets the renderer give each
 * block its own composable with real vertical spacing, headings their
 * own weighted line, lists real bullets/indent, and tables a readable
 * stacked layout. The parser is deliberately a separate pure object so
 * [LitterMarkdownBlocksTest] can exercise it with zero Compose deps and
 * so the block parse is cheap enough to run per render (the heavy
 * AnnotatedString styling stays cached in [ParsedMarkdownCache]).
 *
 * Scope: this is a *pragmatic* block tokenizer for agent chat output,
 * not a full CommonMark engine. It recognizes ATX headings, GFM tables,
 * bullet/ordered lists, blockquotes, and paragraphs. Fenced code is
 * handled upstream by [ConversationRenderer.blocks] (which splits ``` `
 * fences into [ConversationBlock.Code]); this parser only ever sees the
 * non-fenced markdown spans, so it does not re-handle fences.
 */
object LitterMarkdownBlocks {

    sealed class MdBlock {
        /** ATX heading. [level] 1..6, [text] with the `#` prefix stripped. */
        data class Heading(val level: Int, val text: String) : MdBlock()

        /** A run of contiguous non-empty prose lines, joined with `\n`. */
        data class Paragraph(val text: String) : MdBlock()

        /**
         * A bullet (`-`/`*`/`+`) or ordered (`1.`) list. [ordered] picks
         * the marker; [items] carry the per-item text (marker stripped),
         * already trimmed. Nested lists are flattened to [indent] depth
         * so the renderer can indent without a tree walk.
         */
        data class ListBlock(val ordered: Boolean, val items: List<ListItem>) : MdBlock()

        /** A blockquote (`>`-prefixed lines), prefix stripped + joined. */
        data class Quote(val text: String) : MdBlock()

        /**
         * A GFM table: a [header] row + zero-or-more [rows], each a list
         * of cell strings. The delimiter row (`| --- | --- |`) is
         * consumed, not emitted. The renderer stacks each row as
         * "header: value" pairs so a narrow phone never shows run-on
         * concatenated cells.
         */
        data class Table(val header: List<String>, val rows: List<List<String>>) : MdBlock()
    }

    data class ListItem(val text: String, val indent: Int)

    private val HEADING = Regex("^(#{1,6})\\s+(.*)$")
    private val ORDERED = Regex("^(\\s*)(\\d+)[.)]\\s+(.*)$")
    private val BULLET = Regex("^(\\s*)[-*+]\\s+(.*)$")

    /**
     * Parse [markdown] into a flat list of [MdBlock]s. Blank lines are
     * block separators. Returns an empty list for blank input.
     */
    fun parse(markdown: String): List<MdBlock> {
        val lines = markdown.split('\n')
        val blocks = mutableListOf<MdBlock>()
        var i = 0
        val paragraph = mutableListOf<String>()

        fun flushParagraph() {
            if (paragraph.isNotEmpty()) {
                val text = paragraph.joinToString("\n").trim()
                if (text.isNotEmpty()) blocks += MdBlock.Paragraph(text)
                paragraph.clear()
            }
        }

        while (i < lines.size) {
            val line = lines[i]
            val trimmed = line.trim()

            // Blank line → close the current paragraph run.
            if (trimmed.isEmpty()) {
                flushParagraph()
                i++
                continue
            }

            // Heading.
            val heading = HEADING.matchEntire(line)
            if (heading != null) {
                flushParagraph()
                blocks += MdBlock.Heading(
                    level = heading.groupValues[1].length,
                    text = heading.groupValues[2].trim(),
                )
                i++
                continue
            }

            // GFM table: a `|`-delimited row immediately followed by a
            // delimiter row of dashes. Require the delimiter so we don't
            // mistake a lone pipe-bearing sentence for a table.
            if (isTableRow(line) && i + 1 < lines.size && isDelimiterRow(lines[i + 1])) {
                flushParagraph()
                val header = splitRow(line)
                val rows = mutableListOf<List<String>>()
                var j = i + 2
                while (j < lines.size && isTableRow(lines[j])) {
                    rows += splitRow(lines[j])
                    j++
                }
                blocks += MdBlock.Table(header, rows)
                i = j
                continue
            }

            // Blockquote: consume the contiguous `>` run.
            if (trimmed.startsWith(">")) {
                flushParagraph()
                val quote = mutableListOf<String>()
                var j = i
                while (j < lines.size && lines[j].trim().startsWith(">")) {
                    quote += lines[j].trim().removePrefix(">").trimStart()
                    j++
                }
                blocks += MdBlock.Quote(quote.joinToString("\n").trim())
                i = j
                continue
            }

            // List (ordered or bullet): consume the contiguous run of
            // list items (a blank line ends it).
            if (ORDERED.matchEntire(line) != null || BULLET.matchEntire(line) != null) {
                flushParagraph()
                val ordered = ORDERED.matchEntire(line) != null
                val items = mutableListOf<ListItem>()
                var j = i
                while (j < lines.size) {
                    val l = lines[j]
                    val om = ORDERED.matchEntire(l)
                    val bm = BULLET.matchEntire(l)
                    when {
                        om != null -> items += ListItem(
                            text = om.groupValues[3].trim(),
                            indent = indentDepth(om.groupValues[1]),
                        )
                        bm != null -> items += ListItem(
                            text = bm.groupValues[2].trim(),
                            indent = indentDepth(bm.groupValues[1]),
                        )
                        else -> break
                    }
                    j++
                }
                blocks += MdBlock.ListBlock(ordered, items)
                i = j
                continue
            }

            // Plain prose line: accumulate into the current paragraph.
            paragraph += line
            i++
        }
        flushParagraph()
        return blocks
    }

    /** A pipe-bearing line that looks like a table row. */
    private fun isTableRow(line: String): Boolean {
        val t = line.trim()
        return t.contains('|') && t.removePrefix("|").isNotEmpty()
    }

    /** The `| --- | :--: |` delimiter row under a table header. */
    private fun isDelimiterRow(line: String): Boolean {
        val cells = splitRow(line)
        if (cells.isEmpty()) return false
        return cells.all { cell ->
            val c = cell.trim()
            c.isNotEmpty() && c.all { it == '-' || it == ':' } && c.contains('-')
        }
    }

    /** Split a `| a | b |` row into trimmed cell strings. */
    private fun splitRow(line: String): List<String> =
        line.trim()
            .removePrefix("|")
            .removeSuffix("|")
            .split('|')
            .map { it.trim() }

    /** Map a leading-whitespace run to a discrete indent depth. */
    private fun indentDepth(lead: String): Int {
        val spaces = lead.replace("\t", "  ").length
        return (spaces / 2).coerceIn(0, 4)
    }
}
