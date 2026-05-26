package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-data tests for the markdown block tokenizer (Bug 1: chat
 * markdown rendered cramped + structurally collapsed). These pin the
 * contract the renderer relies on: GFM tables become a structured
 * [Table] (never run-on concatenated cells), headings are their OWN
 * block (never jammed into the following paragraph), and consecutive
 * prose / lists are separated into distinct blocks so the renderer can
 * give them vertical rhythm.
 */
class LitterMarkdownBlocksTest {

    private fun parse(s: String) = LitterMarkdownBlocks.parse(s)

    @Test fun blankInputIsEmpty() {
        assertTrue(parse("").isEmpty())
        assertTrue(parse("\n\n  \n").isEmpty())
    }

    @Test fun plainParagraphIsOneBlock() {
        val b = parse("hello world")
        assertEquals(1, b.size)
        assertEquals(LitterMarkdownBlocks.MdBlock.Paragraph("hello world"), b[0])
    }

    @Test fun headingIsItsOwnBlockNotMergedIntoNextText() {
        // The core regression: "## Title" followed by prose must NOT
        // collapse into one run.
        val b = parse("## Plan\nDo the thing.")
        assertEquals(2, b.size)
        val h = b[0] as LitterMarkdownBlocks.MdBlock.Heading
        assertEquals(2, h.level)
        assertEquals("Plan", h.text)
        assertEquals(LitterMarkdownBlocks.MdBlock.Paragraph("Do the thing."), b[1])
    }

    @Test fun headingLevelsAreCaptured() {
        val b = parse("# H1\n## H2\n### H3\n#### H4")
        assertEquals(4, b.size)
        assertEquals(1, (b[0] as LitterMarkdownBlocks.MdBlock.Heading).level)
        assertEquals(2, (b[1] as LitterMarkdownBlocks.MdBlock.Heading).level)
        assertEquals(3, (b[2] as LitterMarkdownBlocks.MdBlock.Heading).level)
        assertEquals(4, (b[3] as LitterMarkdownBlocks.MdBlock.Heading).level)
    }

    @Test fun blankLineSeparatesParagraphs() {
        val b = parse("First para.\n\nSecond para.")
        assertEquals(2, b.size)
        assertEquals("First para.", (b[0] as LitterMarkdownBlocks.MdBlock.Paragraph).text)
        assertEquals("Second para.", (b[1] as LitterMarkdownBlocks.MdBlock.Paragraph).text)
    }

    @Test fun gfmTableParsesToStructuredRowsNotRunOnText() {
        val md = """
            | Name | Status |
            | --- | --- |
            | build | ok |
            | test | failed |
        """.trimIndent()
        val b = parse(md)
        assertEquals(1, b.size)
        val t = b[0] as LitterMarkdownBlocks.MdBlock.Table
        assertEquals(listOf("Name", "Status"), t.header)
        assertEquals(2, t.rows.size)
        assertEquals(listOf("build", "ok"), t.rows[0])
        assertEquals(listOf("test", "failed"), t.rows[1])
    }

    @Test fun tableDelimiterRowVariantsRecognized() {
        val md = "| A | B |\n|:--|--:|\n| 1 | 2 |"
        val b = parse(md)
        assertEquals(1, b.size)
        assertTrue(b[0] is LitterMarkdownBlocks.MdBlock.Table)
    }

    @Test fun loneSentenceWithPipeIsNotATable() {
        // No delimiter row → not a table, stays prose (avoids false grids).
        val b = parse("use a | b to pipe")
        assertEquals(1, b.size)
        assertTrue(b[0] is LitterMarkdownBlocks.MdBlock.Paragraph)
    }

    @Test fun bulletListItemsCarryMarkersStripped() {
        val b = parse("- first\n- second\n- third")
        assertEquals(1, b.size)
        val list = b[0] as LitterMarkdownBlocks.MdBlock.ListBlock
        assertTrue(!list.ordered)
        assertEquals(listOf("first", "second", "third"), list.items.map { it.text })
    }

    @Test fun orderedListIsOrdered() {
        val b = parse("1. one\n2. two")
        val list = b[0] as LitterMarkdownBlocks.MdBlock.ListBlock
        assertTrue(list.ordered)
        assertEquals(listOf("one", "two"), list.items.map { it.text })
    }

    @Test fun nestedBulletCarriesIndent() {
        val b = parse("- top\n  - nested")
        val list = b[0] as LitterMarkdownBlocks.MdBlock.ListBlock
        assertEquals(0, list.items[0].indent)
        assertTrue(list.items[1].indent >= 1)
    }

    @Test fun blockquoteStripsPrefix() {
        val b = parse("> quoted line\n> second")
        assertEquals(1, b.size)
        val q = b[0] as LitterMarkdownBlocks.MdBlock.Quote
        assertEquals("quoted line\nsecond", q.text)
    }

    @Test fun headingTableAndProseAllStaySeparate() {
        // The full regression scenario: a heading immediately above a
        // table immediately above prose must yield three distinct,
        // correctly-typed blocks — never one collapsed run.
        val md = """
            ## Results
            | Step | Time |
            | --- | --- |
            | lint | 2s |
            Done.
        """.trimIndent()
        val b = parse(md)
        assertEquals(3, b.size)
        assertTrue(b[0] is LitterMarkdownBlocks.MdBlock.Heading)
        assertTrue(b[1] is LitterMarkdownBlocks.MdBlock.Table)
        assertTrue(b[2] is LitterMarkdownBlocks.MdBlock.Paragraph)
    }
}
