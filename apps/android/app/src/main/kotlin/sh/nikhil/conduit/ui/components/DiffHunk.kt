package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme

/**
 * One `@@ ... @@` hunk of a structured diff -- the broker's `hunks[]`
 * entry from `GET .../git/diff`. Android mirror of iOS `ConduitUI.DiffHunk`.
 */
data class DiffHunkData(
    val header: String,
    val oldStart: Int,
    val oldLines: Int,
    val newStart: Int,
    val newLines: Int,
    val lines: List<DiffLineData>,
)

/**
 * Renders one [DiffHunkData]: a dim mono hunk-header row followed by its
 * lines via [DiffLineRow]. [isLineAnnotated] flags the trailing gutter chip
 * per line; [onLineClick] opens the annotate sheet for a tapped line.
 * Horizontally scrollable so long lines aren't clipped (mirrors the
 * existing `DiffReviewScreen.InlineDiff` behavior).
 */
@Composable
fun DiffHunkView(
    hunk: DiffHunkData,
    modifier: Modifier = Modifier,
    isLineAnnotated: (DiffLineData) -> Boolean = { false },
    onLineClick: ((DiffLineData) -> Unit)? = null,
) {
    val neon = LocalNeonTheme.current
    Column(modifier.fillMaxWidth()) {
        if (hunk.header.isNotBlank()) {
            Text(
                hunk.header,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(neon.surface2)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                fontFamily = neon.mono,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                color = neon.accent,
                maxLines = 1,
            )
        }
        Column(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(vertical = 2.dp),
        ) {
            hunk.lines.forEach { line ->
                DiffLineRow(
                    line = line,
                    annotated = isLineAnnotated(line),
                    onClick = onLineClick?.let { cb -> { cb(line) } },
                )
            }
        }
    }
}

/**
 * Full file diff: every hunk in order, separated by a hairline. Convenience
 * wrapper over [DiffHunkView] for [ui.ChangesScreen]'s file-detail view.
 */
@Composable
fun DiffFileHunks(
    hunks: List<DiffHunkData>,
    modifier: Modifier = Modifier,
    isLineAnnotated: (String, DiffLineData) -> Boolean = { _, _ -> false },
    onLineClick: ((DiffHunkData, DiffLineData) -> Unit)? = null,
) {
    val neon = LocalNeonTheme.current
    Column(modifier.fillMaxWidth()) {
        hunks.forEachIndexed { idx, hunk ->
            DiffHunkView(
                hunk = hunk,
                isLineAnnotated = { line -> isLineAnnotated(hunk.header, line) },
                onLineClick = onLineClick?.let { cb -> { line -> cb(hunk, line) } },
            )
            if (idx != hunks.lastIndex) {
                androidx.compose.foundation.layout.Box(
                    Modifier.fillMaxWidth().height(1.dp).background(neon.border),
                )
            }
        }
    }
}
