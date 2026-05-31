package sh.nikhil.conduit.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.PinnedContext

/**
 * Horizontal strip of pinned-context chips, rendered just above the
 * composer when one or more contexts are pinned. Hides itself when
 * `contexts` is empty so the composer doesn't gain dead vertical
 * space. Mirror of iOS `ContextBarView`.
 */
@Composable
fun ContextBar(
    contexts: List<PinnedContext>,
    onRemove: (String) -> Unit,
) {
    if (contexts.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = 2.dp)
            .semantics { contentDescription = "composer-context-bar" },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        contexts.forEach { ctx ->
            ContextChip(context = ctx) { onRemove(ctx.id) }
        }
    }
}
