package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * Active-tab context for the in-session bottom bar — mirrors
 * `apps/ios/Sources/Views/InSessionBottomBar.swift` `InSessionContext`.
 * Drives where the centre mic FAB routes its voice transcript: chat
 * gets the existing voice path, terminal / browser surface a "not
 * supported" inline note. Lives separately from [ProjectTab] so the
 * bar's pure-data model can be unit-tested without standing up the
 * Compose tree.
 */
enum class InSessionContext {
    Terminal, Chat, Browser;

    companion object {
        /** Bridge from the segmented-tab enum so a future ProjectTab rename
         *  is caught at compile time via the exhaustive `when`. */
        fun fromTab(tab: ProjectTab): InSessionContext = when (tab) {
            ProjectTab.Terminal -> Terminal
            ProjectTab.Chat     -> Chat
            ProjectTab.Browser  -> Browser
        }
    }
}

/**
 * Pure-data description of the in-session bottom bar. Three controls
 * in a fixed leading → centre → trailing order: thread switcher
 * (Outlined.Layers, iOS `square.stack` equivalent), voice FAB
 * (Filled.Mic), new-session (Filled.AddCircle). Lifted out of the
 * composable so the unit tests in `InSessionBottomBarModelTest` can
 * pin the three-control structure + per-tab voice routing without a
 * Compose host. Same pattern as iOS `InSessionBottomBarModel`.
 */
object InSessionBottomBarModel {

    enum class Control {
        Threads,
        Voice,
        NewSession;

        /** Material icon used in the rendered bar. Asserted by tests. */
        val icon: ImageVector
            get() = when (this) {
                Threads    -> Icons.Outlined.Layers
                Voice      -> Icons.Filled.Mic
                NewSession -> Icons.Filled.AddCircle
            }

        /** Accessibility / content description label. Asserted by tests. */
        val accessibilityLabel: String
            get() = when (this) {
                Threads    -> "Switch thread"
                Voice      -> "Voice dictation"
                NewSession -> "New session"
            }
    }

    /** Render order: leading → centre → trailing. Tests pin this triple. */
    val controls: List<Control> = listOf(Control.Threads, Control.Voice, Control.NewSession)

    /**
     * Whether the centre mic FAB is wired to the existing voice path
     * for the supplied tab context. Per the spec: v1 supports chat
     * only; terminal / browser surface an inline note. Tests assert
     * the routing table so a future refactor can't silently broaden
     * or shrink the supported set.
     */
    fun voiceSupported(context: InSessionContext): Boolean = when (context) {
        InSessionContext.Chat                              -> true
        InSessionContext.Terminal, InSessionContext.Browser -> false
    }

    /** Message used by the inline note when voice isn't wired for the current tab. */
    fun voiceUnsupportedMessage(context: InSessionContext): String = "Voice not supported here"
}

/**
 * Persistent in-session bottom dock — visible across the Terminal /
 * Chat / Browser tabs so the user always has the same three controls
 * at thumb-reach: switch parallel sessions on this server (left),
 * fire voice into the active tab (centre), or spin up another session
 * on the same server (right). Mirrors iOS `InSessionBottomBar`.
 */
@Composable
fun InSessionBottomBar(
    context: InSessionContext,
    onThreads: () -> Unit,
    onVoice: () -> Unit,
    onNewSession: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var unsupportedNote by remember { mutableStateOf<String?>(null) }

    // Auto-clear the unsupported toast so the bar returns to its
    // three-icon resting state — same 1.8s window as iOS.
    LaunchedEffect(unsupportedNote) {
        if (unsupportedNote != null) {
            delay(1_800)
            unsupportedNote = null
        }
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        AnimatedVisibility(visible = unsupportedNote != null, enter = fadeIn(), exit = fadeOut()) {
            Text(
                text = unsupportedNote.orEmpty(),
                style = MaterialTheme.typography.labelMedium,
                color = ConduitTheme.textPrimary(),
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .padding(bottom = 6.dp)
                    .glassCapsule(tint = ConduitTheme.warning().copy(alpha = 0.34f))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
                    .semantics { contentDescription = "InSessionBottomBar.voiceUnsupported" },
            )
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 4.dp)
                .glassCapsule(tint = ConduitTheme.surface().copy(alpha = 0.55f))
                .padding(horizontal = 22.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            DockCircleButton(
                icon = InSessionBottomBarModel.Control.Threads.icon,
                label = InSessionBottomBarModel.Control.Threads.accessibilityLabel,
                tint = ConduitTheme.textPrimary(),
                onClick = onThreads,
            )
            Spacer(Modifier.weight(1f))
            VoiceFab(
                onClick = {
                    if (InSessionBottomBarModel.voiceSupported(context)) {
                        onVoice()
                    } else {
                        unsupportedNote = InSessionBottomBarModel.voiceUnsupportedMessage(context)
                    }
                },
            )
            Spacer(Modifier.weight(1f))
            DockCircleButton(
                icon = InSessionBottomBarModel.Control.NewSession.icon,
                label = InSessionBottomBarModel.Control.NewSession.accessibilityLabel,
                tint = LocalNeonTheme.current.accent,
                onClick = onNewSession,
            )
        }
    }
}

@Composable
private fun DockCircleButton(
    icon: ImageVector,
    label: String,
    tint: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .glassCircle(tint = ConduitTheme.surface().copy(alpha = 0.7f))
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
    }
}

/**
 * Centre mic FAB — bigger and copper-accented to match iOS's dominant
 * voice affordance. Disabled state is handled by the caller via
 * [InSessionBottomBarModel.voiceSupported] so the button itself only
 * fires `onClick`.
 */
@Composable
private fun VoiceFab(onClick: () -> Unit) {
    val accent = LocalNeonTheme.current.accent
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(60.dp)
            .clip(CircleShape)
            .background(accent, CircleShape)
            .border(width = 3.dp, color = accent.copy(alpha = 0.55f), shape = CircleShape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = InSessionBottomBarModel.Control.Voice.accessibilityLabel },
    ) {
        Icon(
            InSessionBottomBarModel.Control.Voice.icon,
            contentDescription = null,
            tint = ConduitTheme.textOnAccent(),
            modifier = Modifier.size(28.dp),
        )
    }
}
