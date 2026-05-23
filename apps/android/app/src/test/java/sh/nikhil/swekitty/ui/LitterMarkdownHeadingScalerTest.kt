package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of iOS `LitterMarkdownHeadingScalerTests.swift`
 * (PLAN-LITTER-VISUAL-PARITY PR 4). The two platforms keep the
 * heading scale aligned — if iOS drifts to a new multiplier set, this
 * test fails because the values are inlined per-platform; the visible
 * jump on either device would otherwise go unnoticed until the user
 * compared the two on the same conversation.
 */
class LitterMarkdownHeadingScalerTest {

    @Test
    fun multipliersMatchIOS() {
        assertEquals(1.43f, LitterMarkdownHeadingScaler.multiplier(forLevel = 1))
        assertEquals(1.30f, LitterMarkdownHeadingScaler.multiplier(forLevel = 2))
        assertEquals(1.15f, LitterMarkdownHeadingScaler.multiplier(forLevel = 3))
        assertEquals(1.07f, LitterMarkdownHeadingScaler.multiplier(forLevel = 4))
    }

    @Test
    fun h5AndBelowDoNotScale() {
        assertNull(LitterMarkdownHeadingScaler.multiplier(forLevel = 5))
        assertNull(LitterMarkdownHeadingScaler.multiplier(forLevel = 6))
    }

    @Test
    fun multipliersAreMonotonicallyIncreasing() {
        val m1 = LitterMarkdownHeadingScaler.multiplier(forLevel = 1)!!
        val m2 = LitterMarkdownHeadingScaler.multiplier(forLevel = 2)!!
        val m3 = LitterMarkdownHeadingScaler.multiplier(forLevel = 3)!!
        val m4 = LitterMarkdownHeadingScaler.multiplier(forLevel = 4)!!
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
        val out = LitterMarkdownHeadingScaler.scaledAnnotated("# Hello", basePointSize = 14f)
        assertEquals("Hello", out.text)
    }

    @Test
    fun scaledAnnotated_preservesNonHeadingLines() {
        val out = LitterMarkdownHeadingScaler.scaledAnnotated(
            text = "intro\n# Heading\noutro",
            basePointSize = 14f,
        )
        // Non-heading lines pass through verbatim; the heading line
        // drops its `# ` prefix per `stripsLeadingHashes`.
        assertEquals("intro\nHeading\noutro", out.text)
    }

    @Test
    fun scaledAnnotated_passesThroughPlainTextUnchanged() {
        val out = LitterMarkdownHeadingScaler.scaledAnnotated(
            text = "Just regular markdown body, no headings.",
            basePointSize = 14f,
        )
        assertEquals("Just regular markdown body, no headings.", out.text)
    }
}
