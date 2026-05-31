package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.swekitty.LocalAppearanceStore
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

// Android mirror of iOS LitterUI.TabletRightPane — the design's tablet
// Sessions right pane: a Terminal / Browser / Info tab row over the
// matching surface, beside the chat-only ProjectScreen(chatOnly=true).
// Reuses the same surfaces the phone uses as pager pages (TerminalPage /
// TermuxTerminalView, BrowserPage, SessionInfoScreen) — no second renderer.

private enum class RightPaneTab(val label: String) {
    Terminal("Terminal"),
    Browser("Browser"),
    Info("Info"),
}

@Composable
fun NeonTabletRightPane(store: SessionStore, session: ProjectSession) {
    val neon = LocalNeonTheme.current
    val appearance = LocalAppearanceStore.current
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    var tab by rememberSaveable { mutableStateOf(RightPaneTab.Terminal) }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            RightPaneTab.entries.forEach { t ->
                val selected = t == tab
                Text(
                    t.label,
                    fontFamily = neon.sans,
                    fontSize = 13.sp,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = if (selected) neon.accent else neon.textDim,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .then(
                            if (selected) {
                                Modifier
                                    .background(neon.accent.copy(alpha = if (neon.dark) 0.13f else 0.10f))
                                    .border(1.dp, neon.accent.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
                            } else {
                                Modifier
                            },
                        )
                        .clickable { tab = t }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
        HorizontalDivider(color = neon.border)
        // Sit all three surfaces on the neon canvas so the Info tab (whose
        // embedded content carries no background of its own) matches the
        // pane chrome instead of floating on whatever is painted behind.
        Box(modifier = Modifier.weight(1f).fillMaxWidth().background(neon.bg)) {
            when (tab) {
                RightPaneTab.Terminal ->
                    if (experimentalNativeTerminal) TermuxTerminalView(store, session)
                    else TerminalPage(store, session)
                RightPaneTab.Browser -> BrowserPage(store, session, BrowserMode.Preview)
                RightPaneTab.Info -> SessionInfoScreen(store, session, onDismiss = {}, embedded = true)
            }
        }
    }
}
