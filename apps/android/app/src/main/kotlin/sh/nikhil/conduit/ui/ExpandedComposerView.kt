package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay

/**
 * Fullscreen multi-line editor for long messages. Triggered from the
 * composer's expand button; presented as a `Dialog` with full-screen
 * platform width so the keyboard takes the full height instead of
 * competing with the chat history. Mirror of iOS
 * `ExpandedComposerView`.
 */
@Composable
fun ExpandedComposerView(
    draft: String,
    placeholder: String,
    accentTint: Color,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            ExpandedComposerContent(
                draft = draft,
                placeholder = placeholder,
                accentTint = accentTint,
                onDraftChange = onDraftChange,
                onSend = onSend,
                onDismiss = onDismiss,
            )
        }
    }
}

@Composable
private fun ExpandedComposerContent(
    draft: String,
    placeholder: String,
    accentTint: Color,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    val hasDraft = draft.trim().isNotEmpty()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.systemBars),
    ) {
        // Top bar — Cancel on the left, Compose title centered, Send on the right.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
            Spacer(Modifier.weight(1f))
            Text(
                "Compose",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            FilledIconButton(
                onClick = {
                    if (hasDraft) {
                        onSend()
                        onDismiss()
                    }
                },
                enabled = hasDraft,
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = accentTint),
                modifier = Modifier.size(34.dp),
            ) {
                Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Send")
            }
        }

        Box(modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp, vertical = 10.dp)) {
            if (draft.isEmpty()) {
                Text(
                    placeholder,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                )
            }
            BasicTextField(
                value = draft,
                onValueChange = onDraftChange,
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    color = MaterialTheme.colorScheme.onSurface,
                ),
                cursorBrush = SolidColor(accentTint),
                modifier = Modifier
                    .fillMaxSize()
                    .focusRequester(focusRequester),
            )
        }
    }

    // Defer focus so the present animation completes before the keyboard
    // slides up — same nicety as iOS, prevents a jitter on opening.
    LaunchedEffect(Unit) {
        delay(120)
        focusRequester.requestFocus()
    }
}
