package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Android mirror of the design's `OutcomeChips` (palette.jsx): a session's
// result at a glance — landed diff (+add / −rem), the associated PR (#num +
// state), and commit count. Fed by the broker's git/gh stats on
// ProjectSession (lines_added / lines_removed / commits / pr_number /
// pr_state). The tests chip is intentionally omitted until there's a
// non-fragile test-result data source.
//
// Each value is gated on > 0 / present so an untouched session (or a non-git
// workspace, where everything is null) renders nothing rather than a noisy
// row of zeros.
@Composable
fun NeonOutcomeChips(
    neon: NeonTheme,
    linesAdded: Int?,
    linesRemoved: Int?,
    commits: Int?,
    prNumber: Int?,
    prState: String?,
    modifier: Modifier = Modifier,
    dense: Boolean = false,
) {
    val showDiff = (linesAdded ?: 0) > 0 || (linesRemoved ?: 0) > 0
    val showPr = (prNumber ?: 0) > 0
    val showCommits = (commits ?: 0) > 0
    if (!showDiff && !showPr && !showCommits) return

    val fs = if (dense) 9.5.sp else 10.5.sp
    // Plain Row (≤3 compact chips) rather than FlowRow — avoids depending on
    // the experimental flow-layout API for a row that won't realistically wrap.
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showDiff) {
            Chip(neon.textDim, dense) {
                Text("+${linesAdded ?: 0}", fontFamily = neon.mono, fontSize = fs, fontWeight = FontWeight.SemiBold, color = neon.green)
                Text("−${linesRemoved ?: 0}", fontFamily = neon.mono, fontSize = fs, fontWeight = FontWeight.SemiBold, color = neon.red)
            }
        }
        if (showPr) {
            val prColor = when (prState) {
                "merged" -> neon.purple
                "open" -> neon.green
                else -> neon.textFaint // draft / closed
            }
            Chip(prColor, dense) {
                Text("#${prNumber} ${prState ?: ""}".trim(), fontFamily = neon.mono, fontSize = fs, fontWeight = FontWeight.SemiBold, color = prColor)
            }
        }
        if (showCommits) {
            val n = commits ?: 0
            Chip(neon.textFaint, dense) {
                Text("$n commit${if (n == 1) "" else "s"}", fontFamily = neon.mono, fontSize = fs, fontWeight = FontWeight.SemiBold, color = neon.textFaint)
            }
        }
    }
}

@Composable
private fun Chip(color: Color, dense: Boolean, content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(color.copy(alpha = 0.08f))
            .border(1.dp, color.copy(alpha = 0.20f), RoundedCornerShape(99.dp))
            .padding(horizontal = if (dense) 6.dp else 7.dp, vertical = if (dense) 1.dp else 2.dp),
        content = content,
    )
}
