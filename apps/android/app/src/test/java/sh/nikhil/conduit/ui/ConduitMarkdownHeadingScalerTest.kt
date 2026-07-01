package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of iOS `ConduitMarkdownHeadingScalerTests.swift`
 * (PLAN-CONDUIT-VISUAL-PARITY PR 4). The two platforms keep the
 * heading scale aligned — if iOS drifts to a new multiplier set, this
 * test fails because the values are inlined per-platform; the visible
 * jump on either device would otherwise go unnoticed until the user
 * compared the two on the same conversation.
 */
class ConduitMarkdownHeadingScalerTest {

    @Test
    fun multipliersMatchIOS() {
        assertEquals(1.43f, ConduitMarkdownHeadingScaler.multiplier(level =1))
        assertEquals(1.30f, ConduitMarkdownHeadingScaler.multiplier(level =2))
        assertEquals(1.15f, ConduitMarkdownHeadingScaler.multiplier(level =3))
        assertEquals(1.07f, ConduitMarkdownHeadingScaler.multiplier(level =4))
    }

    @Test
    fun h5AndBelowDoNotScale() {
        assertNull(ConduitMarkdownHeadingScaler.multiplier(level =5))
        assertNull(ConduitMarkdownHeadingScaler.multiplier(level =6))
    }

    @Test
    fun multipliersAreMonotonicallyIncreasing() {
        val m1 = ConduitMarkdownHeadingScaler.multiplier(level =1)!!
        val m2 = ConduitMarkdownHeadingScaler.multiplier(level =2)!!
        val m3 = ConduitMarkdownHeadingScaler.multiplier(level =3)!!
        val m4 = ConduitMarkdownHeadingScaler.multiplier(level =4)!!
        assertTrue("m1 > m2", m1 > m2)
        assertTrue("m2 > m3", m2 > m3)
        assertTrue("m3 > m4", m3 > m4)
        assertTrue("m4 > 1.0", m4 > 1.0f)
    }

    @Test
    fun scaledAnnotated_stripsLeadingHashes() {
        // A `# Title` line should render as `Title`, not `# Title` —
        // the `#` is a markdown control character and would otherwise
        // appear as visible noise at the bumped heading size.
        val out = ConduitMarkdownHeadingScaler.scaledAnnotated("# Hello", basePointSize = 14f)
        assertEquals("Hello", out.text)
    }

    @Test
    fun scaledAnnotated_preservesNonHeadingLines() {
        val out = ConduitMarkdownHeadingScaler.scaledAnnotated(
            text = "intro\n# Heading\noutro",
            basePointSize = 14f,
        )
        // Non-heading lines pass through verbatim; the heading line
        // drops its `# ` prefix per `stripsLeadingHashes`.
        assertEquals("intro\nHeading\noutro", out.text)
    }

    @Test
    fun scaledAnnotated_passesThroughPlainTextUnchanged() {
        val out = ConduitMarkdownHeadingScaler.scaledAnnotated(
            text = "Just regular markdown body, no headings.",
            basePointSize = 14f,
        )
        assertEquals("Just regular markdown body, no headings.", out.text)
    }

    // --- inlineAnnotated / appendInlineSpans tests ---

    @Test
    fun inlineAnnotated_plainTextUnchanged() {
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("Hello world")
        assertEquals("Hello world", out.text)
    }

    @Test
    fun inlineAnnotated_boldStripMarkers() {
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("Say **bold** here")
        // Markers are consumed; visible text has no asterisks.
        assertEquals("Say bold here", out.text)
    }

    @Test
    fun inlineAnnotated_codeStripMarkers() {
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("Run `ls -la` now")
        assertEquals("Run ls -la now", out.text)
    }

    @Test
    fun inlineAnnotated_italicStripMarkers() {
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("An *italic* word")
        assertEquals("An italic word", out.text)
    }

    @Test
    fun inlineAnnotated_unclosedBoldEmitsLiteralMarkers() {
        // Partial stream: bold opened but not closed yet.
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("Say **bold")
        // The two `*` chars are emitted literally, then "bold".
        assertEquals("Say **bold", out.text)
    }

    @Test
    fun inlineAnnotated_unclosedBacktickEmitsLiteral() {
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("Run `ls")
        assertEquals("Run `ls", out.text)
    }

    @Test
    fun inlineAnnotated_snakeCasePreserved() {
        // Underscores in identifiers must NOT be treated as italic markers.
        val out = ConduitMarkdownHeadingScaler.inlineAnnotated("foo_bar_baz")
        assertEquals("foo_bar_baz", out.text)
    }
}
