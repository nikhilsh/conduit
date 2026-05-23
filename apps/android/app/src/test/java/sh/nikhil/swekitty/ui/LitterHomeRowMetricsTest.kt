package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Android mirror of `apps/ios/Tests/SweKittyTests/LitterHomeRowGeometryTests.swift`.
 *
 * Pins the litter-faithful home row metrics chosen in
 * `PLAN-LITTER-VISUAL-PARITY` PR 3. Before this PR the home row was
 * rendered at `titleSmall` / 16dp icon / 14dp horizontal / 12dp
 * vertical, which produced a list ~2.8× looser than litter's actual
 * row density (audit §A.1.1 / §A.1.2). If a refactor accidentally
 * restores any of the loose values, the row stops matching litter's
 * reference — this catches it.
 */
class LitterHomeRowMetricsTest {

    @Test
    fun titleSizeIsFootnote() {
        assertEquals(13f, LitterHomeRowMetrics.titlePointSize)
    }

    @Test
    fun subtitleSizeIsCaption2() {
        assertEquals(11f, LitterHomeRowMetrics.subtitlePointSize)
    }

    @Test
    fun leadingPaddingMatchesLitter() {
        assertEquals(1f, LitterHomeRowMetrics.leadingPadding)
        assertEquals(8f, LitterHomeRowMetrics.trailingPadding)
    }

    @Test
    fun verticalPaddingMatchesLitter() {
        assertEquals(5f, LitterHomeRowMetrics.verticalPadding)
    }

    @Test
    fun indicatorIsSevenDp() {
        assertEquals(7f, LitterHomeRowMetrics.indicatorSize)
    }

    @Test
    fun activeRowFillMatchesLitter() {
        assertEquals(6f, LitterHomeRowMetrics.activeRowCornerRadius)
        assertEquals(0.55f, LitterHomeRowMetrics.activeRowOpacity)
    }
}
