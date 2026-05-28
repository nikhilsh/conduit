package sh.nikhil.swekitty.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.EventBusy
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.ConversationNotFoundException
import sh.nikhil.swekitty.SavedSession
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ConversationItem
import uniffi.swe_kitty_core.ProjectSession

/**
 * Read-only viewer for an exited session's persisted transcript.
 * Android mirror of `apps/ios/Sources/Shared/SavedTranscriptView.swift`:
 * fetches the broker's `conversation.jsonl` over HTTP via
 * [SessionStore.fetchConversation] and feeds the items into [ChatPage]
 * in `readOnly = true` mode. The composer + quick-reply bar are
 * suppressed by the existing read-only branch in ChatPage, so the
 * surface reuses the live renderer without conditional layout here.
 *
 * Caveat (broker PR #196): `conversation.jsonl` is only written for
 * sessions created after that redeploy — older exited rows 404. We
 * render an explicit "no saved transcript" state so the user knows the
 * row is intentionally empty rather than a failure.
 */
private sealed class LoadState {
    object Loading : LoadState()
    data class Loaded(val items: List<ConversationItem>) : LoadState()
    object NotFound : LoadState()
    data class Failed(val message: String) : LoadState()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SavedTranscriptScreen(
    store: SessionStore,
    session: SavedSession,
    onDismiss: () -> Unit,
) {
    var state by remember(session.compoundId) { mutableStateOf<LoadState>(LoadState.Loading) }
    BackHandler { onDismiss() }
    LaunchedEffect(session.compoundId) {
        state = try {
            LoadState.Loaded(store.fetchConversation(session.id))
        } catch (_: ConversationNotFoundException) {
            LoadState.NotFound
        } catch (t: Throwable) {
            LoadState.Failed(t.message ?: "Unknown error")
        }
    }

    val title = session.summary.takeIf { it.isNotBlank() } ?: session.id

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        title,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (val s = state) {
                LoadState.Loading -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(color = SweKittyTheme.accentStrong())
                }
                is LoadState.Loaded -> if (s.items.isEmpty()) {
                    InfoState(
                        icon = Icons.Filled.ChatBubbleOutline,
                        title = "Empty transcript",
                        message = "This session ended without any recorded messages.",
                    )
                } else {
                    ChatPage(
                        store = store,
                        session = projectSessionFor(session),
                        readOnly = true,
                        readOnlyItems = s.items,
                    )
                }
                LoadState.NotFound -> InfoState(
                    icon = Icons.Filled.EventBusy,
                    title = "No saved transcript",
                    message = "This session ended before transcripts were saved on the server, so there's nothing to replay.",
                )
                is LoadState.Failed -> InfoState(
                    icon = Icons.Filled.WarningAmber,
                    title = "Couldn't load transcript",
                    message = s.message,
                )
            }
        }
    }
}

/**
 * Build a stand-in [ProjectSession] from a saved row's persisted
 * metadata. [ChatPage] needs one for its title / assistant / composer
 * placeholder, but a saved row has no live one. Only the read-only
 * render path runs against it, so the unused live fields are harmless.
 * Mirrors iOS `SavedTranscriptView.projectSession`.
 */
private fun projectSessionFor(session: SavedSession): ProjectSession =
    ProjectSession(
        id = session.id,
        name = session.summary.takeIf { it.isNotBlank() } ?: session.id,
        assistant = session.agent,
        branch = null,
        preview = null,
        reasoningEffort = null,
        cwd = session.cwd,
        startedAt = session.firstSeen,
        lastActivityAt = session.lastSeen,
        displayName = null,
    )

@Composable
private fun InfoState(icon: ImageVector, title: String, message: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 36.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(14.dp))
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
