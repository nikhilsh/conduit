package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import sh.nikhil.conduit.RenameSessionValidator
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.ConduitButton
import uniffi.conduit_core.ProjectSession

/**
 * Native rename-session sheet -- Android mirror of
 * `apps/ios/Sources/ConduitUI/Views/ConduitRenameSessionSheet.swift`.
 *
 * Replaces the plain `AlertDialog` + bare `TextField`/`BasicTextField` that
 * both [ProjectScreen]'s title menu and [SessionInfoScreen]'s inline rename
 * button used to roll independently -- both now call this single composable,
 * so the neon-theme redesign (and the rename validation rule) live in one
 * place instead of drifting across two dialogs.
 *
 * Idiom matches the other redesigned sheets ([AgentLoginSheet],
 * [FoundSessionsSheet]): a `ModalBottomSheet` with a `TopAppBar` trailing
 * close "X" (no text Cancel/Save in a title bar), a neon card around the
 * field with a small-caps section label, and a pill-style primary `Save`
 * CTA via [ConduitButton]. Validation delegates to [RenameSessionValidator]
 * (Kotlin mirror of the iOS `Shared/RenameSessionValidator.swift`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RenameSessionSheet(
    store: SessionStore,
    session: ProjectSession,
    initialDraft: String,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var draft by remember { mutableStateOf(initialDraft) }
    val focusRequester = remember { FocusRequester() }

    val trimmed = draft.trim()
    val isValid = RenameSessionValidator.isValid(draft)
    val showsError = trimmed.isNotEmpty() && !isValid

    fun save() {
        if (!isValid) return
        Telemetry.breadcrumb("session", "rename saved", mapOf("session_id" to session.id))
        store.renameSession(session.id, trimmed)
        onDismiss()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.bg,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(neon.appBg)
                .imePadding(),
        ) {
            TopAppBar(
                title = {
                    Text(
                        "Rename session",
                        style = MaterialTheme.typography.titleMedium,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.text,
                    )
                },
                actions = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Rounded.Close, contentDescription = "Close", tint = neon.textDim)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    "Choose a label for this session. The broker name stays the same — this rename is local to your device.",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.sans,
                    color = neon.textFaint,
                )
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface)
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        "NAME",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        color = neon.textFaint,
                        letterSpacing = 0.6.sp,
                    )
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        singleLine = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .focusRequester(focusRequester),
                        textStyle = MaterialTheme.typography.bodyMedium.copy(
                            color = neon.text,
                            fontFamily = neon.sans,
                        ),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = if (showsError) neon.red else neon.accent,
                            unfocusedBorderColor = if (showsError) neon.red.copy(alpha = 0.6f) else neon.borderStrong,
                            cursorColor = neon.accent,
                        ),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { save() }),
                    )
                    Text(
                        RenameSessionValidator.HELP_TEXT,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = if (showsError) neon.red else neon.textFaint,
                    )
                }
                ConduitButton(
                    title = "Save",
                    onClick = { save() },
                    variant = ButtonVariant.Primary,
                    enabled = isValid,
                )
            }
        }
    }

    // Defer focus so the sheet's slide-up animation completes before the
    // keyboard follows -- same nicety as ExpandedComposerView, prevents a
    // jitter on opening.
    LaunchedEffect(Unit) {
        delay(120)
        focusRequester.requestFocus()
    }
}
