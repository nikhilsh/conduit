package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

/**
 * Pure-data view-model for [ThreadSwitcherSheet]. Lifts the list
 * derivation out of the composable so the unit tests in
 * `ThreadSwitcherModelTest` can pin (a) same-server filtering,
 * (b) the empty-state CTA, and (c) the multi-thread pill strip
 * without hosting the Compose tree.
 *
 * **Server identity:** `ProjectSession` doesn't carry a `serverID`
 * field on the wire yet — the harness only ever speaks to one endpoint
 * at a time, so every `store.sessions` entry is, by construction, on
 * the currently-connected server. The model takes `currentServerID`
 * for symmetry with iOS so a future Rust core surface that exposes
 * `serverID` plugs in without a model rewrite. Same shape as
 * `apps/ios/Sources/Views/ThreadSwitcherSheet.swift::ThreadSwitcherModel`.
 */
data class ThreadSwitcherModel(
    /** Sessions on the same server as the active session, excluding
     *  the active session itself. Render order = wire order. */
    val sameServerSessions: List<ProjectSession>,
    /** Every session the client knows about — powers the peek pill strip. */
    val allSessions: List<ProjectSession>,
    /** Currently active session — used for highlight + skip. */
    val activeSessionID: String,
) {
    val sameServerIsEmpty: Boolean get() = sameServerSessions.isEmpty()

    companion object {
        @Suppress("UNUSED_PARAMETER")
        fun from(
            allSessions: List<ProjectSession>,
            activeSessionID: String,
            currentServerID: String?,
        ): ThreadSwitcherModel {
            // Same-server filter: drop the active session. `currentServerID`
            // is informational for now; once a wire-side `serverID` lands
            // we'll switch this to `it.serverID == currentServerID`.
            val others = allSessions.filter { it.id != activeSessionID }
            return ThreadSwitcherModel(
                sameServerSessions = others,
                allSessions = allSessions,
                activeSessionID = activeSessionID,
            )
        }
    }
}

/**
 * `ModalBottomSheet` presented from `InSessionBottomBar`'s leading
 * threads button. Mirrors `apps/ios/Sources/Views/ThreadSwitcherSheet.swift`:
 *  - Top: small horizontal pill strip of ALL sessions across servers
 *    (single-letter agent initials in glass capsules).
 *  - Body: vertical list of OTHER sessions on the same server
 *    (HealthDot · name · agent · phase · trailing chevron).
 *  - Empty state: "No other sessions on this server" + `+ New session`
 *    CTA that opens `AgentPickerSheet`.
 *
 * Tap on any pill or row → close sheet, `store.switchTo(sessionID)` —
 * the existing `AppRoot` observer of `selectedId` re-binds the
 * destination ProjectScreen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadSwitcherSheet(
    store: SessionStore,
    activeSession: ProjectSession,
    onDismiss: () -> Unit,
    onNewSession: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val sessions by store.sessions.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()

    val currentServerID = savedServers.firstOrNull { it.endpoint == endpoint }?.id
    val model = ThreadSwitcherModel.from(
        allSessions = sessions,
        activeSessionID = activeSession.id,
        currentServerID = currentServerID,
    )

    val switchTo: (ProjectSession) -> Unit = { target ->
        if (target.id == activeSession.id) {
            onDismiss()
        } else {
            store.switchTo(target.id)
            onDismiss()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "Threads",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = SweKittyTheme.textPrimary(),
                modifier = Modifier.padding(start = 4.dp),
            )

            if (model.allSessions.isNotEmpty()) {
                PeekPillStrip(
                    model = model,
                    onPick = switchTo,
                )
            }

            if (model.sameServerIsEmpty) {
                EmptyState(onNewSession = {
                    onDismiss()
                    onNewSession()
                })
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    items(model.sameServerSessions, key = { it.id }) { s ->
                        SessionRow(
                            session = s,
                            displayName = sh.nikhil.swekitty.SessionNaming.friendlyFor(
                                session = s,
                                custom = displayNames[s.id],
                                firstUserMessage = sh.nikhil.swekitty.firstUserMessageOf(
                                    conversationLog[s.id],
                                ),
                            ),
                            health = statuses[s.id]?.health,
                            phase = statuses[s.id]?.phase,
                            onClick = { switchTo(s) },
                        )
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

/**
 * Horizontal pill strip across the top — every session the client
 * knows about, rendered as a single-letter agent initial inside a
 * tinted glass capsule. Active session highlighted. Same affordance
 * for switching as the full row list below.
 */
@Composable
private fun PeekPillStrip(
    model: ThreadSwitcherModel,
    onPick: (ProjectSession) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        model.allSessions.forEach { s ->
            PeekPill(
                session = s,
                isActive = s.id == model.activeSessionID,
                onClick = { onPick(s) },
            )
        }
    }
}

@Composable
private fun PeekPill(session: ProjectSession, isActive: Boolean, onClick: () -> Unit) {
    val initial = session.assistant.take(1).uppercase()
    val tint = SweKittyTheme.accent(forAgent = session.assistant)
    val capsuleTint = if (isActive) tint.copy(alpha = 0.48f) else tint.copy(alpha = 0.22f)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(width = 32.dp, height = 28.dp)
            .clip(RoundedCornerShape(percent = 50))
            .glassCapsule(interactive = true, tint = capsuleTint)
            .clickable(onClick = onClick),
    ) {
        Text(
            initial,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (isActive) SweKittyTheme.textPrimary() else SweKittyTheme.textSecondary(),
        )
    }
}

@Composable
private fun SessionRow(
    session: ProjectSession,
    displayName: String,
    health: String?,
    phase: String?,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .glassRect(cornerRadiusDp = SweKittyTheme.smallCornerRadiusDp)
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            HealthDot(health = health ?: "unknown")
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    displayName,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    color = SweKittyTheme.textPrimary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        session.assistant,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = SweKittyTheme.textSecondary(),
                    )
                    Spacer(Modifier.width(6.dp))
                    val sub = phase?.takeIf { it.isNotBlank() } ?: "ready"
                    Text(
                        "· $sub",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = SweKittyTheme.textMuted(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = SweKittyTheme.textMuted(),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun EmptyState(onNewSession: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Outlined.Layers,
            contentDescription = null,
            tint = SweKittyTheme.textSecondary(),
            modifier = Modifier.size(40.dp),
        )
        Text(
            "No other sessions on this server",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = SweKittyTheme.textPrimary(),
            textAlign = TextAlign.Center,
        )
        Text(
            "Spin one up to work on something else in parallel — your current session keeps running.",
            style = MaterialTheme.typography.bodySmall,
            color = SweKittyTheme.textMuted(),
            textAlign = TextAlign.Center,
        )
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .clip(CircleShape)
                .background(androidx.compose.ui.graphics.Color.Transparent)
                .clickable(onClick = onNewSession)
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    Icons.Filled.Add,
                    contentDescription = null,
                    tint = SweKittyTheme.accentStrong(),
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    "New session",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = SweKittyTheme.accentStrong(),
                )
            }
        }
    }
}
