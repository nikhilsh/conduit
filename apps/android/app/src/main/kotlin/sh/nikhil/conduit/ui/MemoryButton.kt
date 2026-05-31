package sh.nikhil.conduit.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable

/**
 * Header affordance that flips the Browser tab between the live preview
 * and the session memory HTML at <endpoint>/memory/sessions/<uuid>.html.
 * Tapping switches to the Browser tab (via [onJumpToBrowser]) and toggles
 * the mode; tapping again returns to preview.
 */
@Composable
fun MemoryButton(
    currentMode: BrowserMode,
    onToggle: (BrowserMode) -> Unit,
    onJumpToBrowser: () -> Unit,
) {
    IconButton(onClick = {
        onToggle(if (currentMode == BrowserMode.Memory) BrowserMode.Preview else BrowserMode.Memory)
        onJumpToBrowser()
    }) {
        Icon(Icons.AutoMirrored.Outlined.Article, contentDescription = "Memory")
    }
}
