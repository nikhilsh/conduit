package sh.nikhil.swekitty.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.RecencyBucket
import sh.nikhil.swekitty.SessionNaming
import sh.nikhil.swekitty.SessionRecencyGrouping
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.firstUserMessageOf
import uniffi.swe_kitty_core.ProjectSession

/**
 * Past-session history + cross-session search — opened from the
 * bottom-bar magnifying glass. Android parity of the iOS "Resume an old
 * thread" `SessionsScreen`. With no query it shows every session the
 * client knows about grouped into recency buckets by last activity
 * ("Today" / "Yesterday" / "Previous 7 Days" / "Earlier"); typing
 * filters across name, agent, branch, and transcript and re-groups the
 * matches the same way. Server identity moves to a per-row chip rather
 * than the section header (Android speaks to one server at a time).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionSearchScreen(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val sessions by store.sessions.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    var query by remember { mutableStateOf("") }

    // The server label shown on each row's chip. Prefer the saved-server
    // name for the active endpoint; fall back to the sanitized host.
    val serverLabel = savedServers.firstOrNull { it.endpoint == endpoint }?.name
        ?: endpoint.displayHost

    // Match + bucket in one derivation. An empty query shows everything as
    // history; a query filters first, then both paths group by recency.
    val groups by remember(query, sessions, conversationLog, displayNames) {
        derivedStateOf {
            val needle = query.trim().lowercase()
            val hits = sessions.mapNotNull { s ->
                val firstMsg = firstUserMessageOf(conversationLog[s.id])
                val title = SessionNaming.friendlyFor(
                    session = s,
                    custom = displayNames[s.id],
                    firstUserMessage = firstMsg,
                )
                val snippet = if (needle.isEmpty()) null
                else matchSnippet(needle, conversationLog[s.id].orEmpty())
                val matches = needle.isEmpty() ||
                    title.lowercase().contains(needle) ||
                    s.assistant.lowercase().contains(needle) ||
                    (s.branch ?: "").lowercase().contains(needle) ||
                    snippet != null
                if (!matches) return@mapNotNull null
                SearchHit(
                    session = s,
                    title = title,
                    subtitle = snippet ?: "${s.assistant} · ${s.branch ?: "no branch"}",
                    relativeTime = SessionNaming.relativeAgo(s.lastActivityAt ?: s.startedAt),
                )
            }
            SessionRecencyGrouping.group(hits) { it.session.lastActivityAt ?: it.session.startedAt }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Sessions", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)

            Surface(
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Search, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(8.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        textStyle = MaterialTheme.typography.bodyMedium.copy(
                            color = MaterialTheme.colorScheme.onSurface,
                        ),
                        decorationBox = { inner ->
                            if (query.isEmpty()) {
                                Text(
                                    "Search sessions, transcripts, paths…",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            inner()
                        },
                        modifier = Modifier.fillMaxWidth().weight(1f, fill = true),
                    )
                    if (query.isNotEmpty()) {
                        Icon(
                            Icons.Default.Cancel,
                            contentDescription = "Clear",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp).clickable { query = "" },
                        )
                    }
                }
            }

            if (groups.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        if (query.isEmpty()) "No sessions yet" else "No matches",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        if (query.isEmpty())
                            "Start one from Home — it'll show up here so you can pick up later."
                        else
                            "Try a different query.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    groups.forEach { group ->
                        SectionLabel(group.bucket.label)
                        group.rows.forEach { result ->
                            SessionHistoryRow(
                                result = result,
                                serverLabel = serverLabel,
                                onClick = {
                                    store.select(result.session.id)
                                    onDismiss()
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 6.dp),
    )
}

@Composable
private fun SessionHistoryRow(
    result: SearchHit,
    serverLabel: String,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HealthDot("unknown")
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    result.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
                Text(
                    result.subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // Server identity moves here from the section header.
                    Surface(
                        shape = RoundedCornerShape(50),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                    ) {
                        Text(
                            serverLabel,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                    if (result.relativeTime.isNotEmpty()) {
                        Text(
                            result.relativeTime,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                            maxLines = 1,
                        )
                    }
                }
            }
            Icon(
                Icons.Default.ChevronRight,
                null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun matchSnippet(
    needle: String,
    events: List<uniffi.swe_kitty_core.ConversationItem>,
): String? {
    for (ev in events.asReversed()) {
        val lower = ev.content.lowercase()
        val idx = lower.indexOf(needle)
        if (idx >= 0) {
            val start = (idx - 20).coerceAtLeast(0)
            val end = (idx + needle.length + 40).coerceAtMost(ev.content.length)
            return ev.content.substring(start, end).trim()
        }
    }
    return null
}

private data class SearchHit(
    val session: ProjectSession,
    val title: String,
    val subtitle: String,
    val relativeTime: String,
)
