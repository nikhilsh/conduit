package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of iOS `ViewerCountBadgeModelTests` (PR #67). Pins the
 * visibility contract of [ViewerCountBadgeModel]. The composable body
 * is a single early-return on `model.label`, so testing the model
 * fully covers the rendering decision — any drift between the rules
 * below and the rendered surface is a model bug, not a view bug.
 */
class ViewerCountBadgeModelTest {

    @Test
    fun nilCountIsInvisible() {
        // Broker hasn't emitted `viewer_count` yet (either it's a stale
        // pre-parity broker or the first status frame hasn't landed).
        // Don't reserve layout space — render literally nothing.
        val model = ViewerCountBadgeModel(count = null)
        assertNull(model.label)
        assertNull(model.accessibilityLabel)
        assertFalse(model.isVisible)
    }

    @Test
    fun zeroCountIsInvisible() {
        // Defensive: the broker should never broadcast 0 (you are
        // always at least your own viewer), but if it does we still
        // refuse to render. Otherwise an off-by-one in the broker
        // would surface as a confusing "👥 0" pill.
        val model = ViewerCountBadgeModel(count = 0)
        assertFalse(model.isVisible)
    }

    @Test
    fun singleViewerIsInvisible() {
        // You are the only viewer. Announcing yourself to yourself is
        // noise — the badge only earns screen real estate when there
        // is genuinely someone else watching.
        val model = ViewerCountBadgeModel(count = 1)
        assertNull(model.label)
        assertFalse(model.isVisible)
    }

    @Test
    fun twoViewersRendersPill() {
        // Minimum interesting case — one extra viewer. The pill must
        // render with the "👥 N" label so the rest of the UI can hint
        // at the shared session.
        val model = ViewerCountBadgeModel(count = 2)
        assertEquals("👥 2", model.label)
        assertTrue(model.isVisible)
    }

    @Test
    fun largerCountsRenderExactNumber() {
        // No clamping / "9+" abbreviation in v1: the broker caps the
        // fan-out at a sensible number anyway, and seeing the exact
        // count is more useful than a vague indicator while we're
        // still iterating on the multi-viewer story.
        val model = ViewerCountBadgeModel(count = 7)
        assertEquals("👥 7", model.label)
    }

    @Test
    fun accessibilityLabelSpellsOutCount() {
        // TalkBack reads "👥" as "people" or worse; override with a
        // literal phrase so the spoken output is useful instead of
        // confusing.
        val model = ViewerCountBadgeModel(count = 3)
        assertEquals("3 viewers", model.accessibilityLabel)
    }

    @Test
    fun accessibilityLabelIsNullWhenHidden() {
        // The model's visibility decisions must stay consistent — if
        // the pill is hidden, the accessibility label is hidden too.
        // Otherwise TalkBack would announce a pill that isn't on
        // screen.
        val modelOne = ViewerCountBadgeModel(count = 1)
        assertNull(modelOne.accessibilityLabel)

        val modelNil = ViewerCountBadgeModel(count = null)
        assertNull(modelNil.accessibilityLabel)
    }
}
