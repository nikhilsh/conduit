package sh.nikhil.conduit.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.ui.graphics.vector.ImageVector

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
