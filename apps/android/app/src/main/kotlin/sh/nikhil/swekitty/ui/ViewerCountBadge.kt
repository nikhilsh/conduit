package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * sweswe-parity / android-viewer-badge — Android mirror of the iOS
 * `ViewerCountBadge` shipped in PR #67. Surfaces the `viewers` field on
 * the `status` envelope (broker emits it once PR #79 lands) so a
 * pair-programming or hand-off session is obviously shared instead of
 * silently fan-out by the broker.
 *
 * Visibility rules — defended by `ViewerCountBadgeModelTest` and pinned
 * to the iOS contract:
 *  - `null` count → invisible (no `viewer_count` frame yet, or pre-#79
 *    broker that never emits the field).
 *  - `count <= 1` → invisible (you are the only viewer; announcing
 *    yourself to yourself is noise).
 *  - `count >= 2` → render a glass capsule `"👥 N"` with a literal
 *    `"N viewers"` TalkBack label so the screen reader doesn't speak
 *    the emoji codepoint.
 */
@Composable
fun ViewerCountBadge(count: Int?, modifier: Modifier = Modifier) {
    val model = ViewerCountBadgeModel(count = count)
    val label = model.label ?: return
    val a11y = model.accessibilityLabel ?: label
    Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        color = SweKittyTheme.textSecondary(),
        modifier = modifier
            .testTag("ViewerCountBadge")
            .glassCapsule()
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .semantics { contentDescription = a11y },
    )
}

/**
 * Pure-data backing for `ViewerCountBadge` — mirror of the iOS
 * `ViewerCountBadgeModel` struct. Keeps the visibility & formatting
 * rules in a value type so the contract is unit-testable without a
 * Compose host. Same shape (`label`, `accessibilityLabel`, `isVisible`)
 * as iOS so a future audit can grep both platforms side by side.
 */
data class ViewerCountBadgeModel(val count: Int?) {
    /** Rendered string, or `null` when the badge must be hidden. */
    val label: String?
        get() = count?.takeIf { it >= 2 }?.let { "👥 $it" }

    /**
     * TalkBack string. Stays in sync with [label] — `null` when hidden,
     * otherwise spells out the count ("2 viewers" not "people emoji 2")
     * so the reader doesn't announce the glyph codepoint.
     */
    val accessibilityLabel: String?
        get() = count?.takeIf { it >= 2 }?.let { "$it viewers" }

    /** Convenience for tests — reads better than `model.label != null`. */
    val isVisible: Boolean get() = label != null
}
