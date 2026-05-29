package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.PinnedContext
import sh.nikhil.swekitty.PinnedContextKind

/**
 * One pinned-context chip, rendered above the composer. Tap clears
 * the chip via `onRemove`. The chip is purely presentational — data
 * lives in `SessionStore.pinnedContexts`. Mirror of iOS
 * `ContextChipView`.
 */
@Composable
fun ContextChip(
    context: PinnedContext,
    onRemove: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Surface(
        shape = RoundedCornerShape(50),
        color = neon.accent.copy(alpha = 0.16f),
        border = androidx.compose.foundation.BorderStroke(1.dp, neon.accent.copy(alpha = 0.45f)),
        modifier = Modifier.semantics { contentDescription = "Pinned: ${context.label}" },
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, end = 2.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                iconFor(context.kind),
                contentDescription = null,
                tint = neon.accent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                context.label,
                style = MaterialTheme.typography.labelMedium,
                fontFamily = neon.mono,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            IconButton(
                onClick = onRemove,
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Remove ${context.label}",
                    tint = neon.textDim,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

private fun iconFor(kind: PinnedContextKind): ImageVector = when (kind) {
    PinnedContextKind.File -> Icons.Outlined.Description
    PinnedContextKind.Url -> Icons.Outlined.Link
    PinnedContextKind.Snippet -> Icons.Outlined.FormatQuote
}
