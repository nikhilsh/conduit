package sh.nikhil.conduit.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.outlined.Layers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `android-multi-thread` — persistent in-session bottom bar shape.
 * Mirrors iOS `InSessionBottomBarTests` from PR #42: assert against
 * the pure-data [InSessionBottomBarModel] rather than hosting the
 * composable, so the three-control layout + per-tab voice routing are
 * pinned without a Compose host. Pure JUnit — no Robolectric needed
 * because the Material icon vectors resolve at compile time without
 * an Android runtime.
 */
class InSessionBottomBarModelTest {

    // ---------- three-control structure ----------

    @Test
    fun dockHasThreeControlsInOrder() {
        // iOS HomeBottomBar parity: leading thread-switcher, centre
        // voice FAB, trailing new-session button. Drift here means the
        // visual reference is broken.
        assertEquals(
            listOf(
                InSessionBottomBarModel.Control.Threads,
                InSessionBottomBarModel.Control.Voice,
                InSessionBottomBarModel.Control.NewSession,
            ),
            InSessionBottomBarModel.controls,
        )
        assertEquals(3, InSessionBottomBarModel.controls.size)
    }

    @Test
    fun eachControlUsesItsSpecIcon() {
        // Pin the Material icons so a refactor can't silently swap
        // Outlined.Layers (the Compose equivalent of iOS
        // `square.stack`) for a different glyph, or downgrade the
        // voice FAB. Compare by ImageVector.name — that's the stable
        // identity of a Material icon (e.g. "Outlined.Layers"); the
        // backing instances are cached but the name is the contract.
        assertEquals(Icons.Outlined.Layers.name, InSessionBottomBarModel.Control.Threads.icon.name)
        assertEquals(Icons.Filled.Mic.name, InSessionBottomBarModel.Control.Voice.icon.name)
        assertEquals(Icons.Filled.AddCircle.name, InSessionBottomBarModel.Control.NewSession.icon.name)
    }

    @Test
    fun eachControlExposesAccessibilityLabel() {
        // TalkBack labels are a regression-prone surface — assert them
        // explicitly so a string-table refactor can't strip them.
        assertEquals("Switch thread", InSessionBottomBarModel.Control.Threads.accessibilityLabel)
        assertEquals("Voice dictation", InSessionBottomBarModel.Control.Voice.accessibilityLabel)
        assertEquals("New session", InSessionBottomBarModel.Control.NewSession.accessibilityLabel)
    }

    // ---------- per-tab voice routing ----------

    @Test
    fun voiceWiredOnChatTabOnly() {
        // v1 spec: voice routes to `sendChat` when the user is on the
        // chat tab; terminal and browser surface a "not supported"
        // toast instead. Centralising the routing matrix in the model
        // means the composable has nothing to decide — it just asks.
        assertTrue(InSessionBottomBarModel.voiceSupported(InSessionContext.Chat))
        assertFalse(InSessionBottomBarModel.voiceSupported(InSessionContext.Terminal))
        assertFalse(InSessionBottomBarModel.voiceSupported(InSessionContext.Browser))
    }

    @Test
    fun voiceUnsupportedMessageIsActionable() {
        // The toast string is part of the contract — pin it so an
        // accidental copy edit doesn't turn it into a no-op nag.
        assertEquals(
            "Voice not supported here",
            InSessionBottomBarModel.voiceUnsupportedMessage(InSessionContext.Terminal),
        )
        assertEquals(
            "Voice not supported here",
            InSessionBottomBarModel.voiceUnsupportedMessage(InSessionContext.Browser),
        )
    }

    // ---------- ProjectTab → InSessionContext bridge ----------

    @Test
    fun inSessionContextMatchesProjectTab() {
        // The bottom bar lives next to the existing ProjectTab
        // segmented picker — the bridge between them must round-trip
        // cleanly so the active-tab signal doesn't drift if a future
        // refactor renames either enum.
        assertEquals(InSessionContext.Terminal, InSessionContext.fromTab(ProjectTab.Terminal))
        assertEquals(InSessionContext.Chat, InSessionContext.fromTab(ProjectTab.Chat))
        assertEquals(InSessionContext.Browser, InSessionContext.fromTab(ProjectTab.Browser))
    }

    @Test
    fun allProjectTabsHaveAContext() {
        // Defensive: every ProjectTab case maps to an InSessionContext
        // case. The `fromTab` `when` is exhaustive on ProjectTab, so a
        // new tab added without updating the bridge fails to compile.
        // This test additionally pins the count parity.
        val all = ProjectTab.entries.map { InSessionContext.fromTab(it) }.toSet()
        assertEquals(InSessionContext.entries.toSet(), all)
    }
}
