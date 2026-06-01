package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Android mirror of iOS ConduitUI.TabletActivityBar — the design bundle's
// far-left iPad activity bar (tablet-sections.jsx → TabletActivityBar):
// brand mark on top, vertical section items (Home / Sessions / History /
// Boxes / Settings), account glyph pinned to the bottom. 84dp wide; the
// active item carries an accent-tinted pill.

enum class TabletSection(val label: String) {
    Home("Home"),
    Sessions("Sessions"),
    History("History"),
    Boxes("Boxes"),
    Settings("Settings"),
}

private fun iconFor(section: TabletSection): ImageVector = when (section) {
    TabletSection.Home -> Icons.Outlined.Home
    TabletSection.Sessions -> Icons.Outlined.Forum
    TabletSection.History -> Icons.Outlined.History
    TabletSection.Boxes -> Icons.Outlined.Dns
    TabletSection.Settings -> Icons.Outlined.Settings
}

@Composable
fun NeonTabletActivityBar(section: TabletSection, onPick: (TabletSection) -> Unit) {
    val neon = LocalNeonTheme.current
    Column(
        modifier = Modifier
            .width(84.dp)
            .fillMaxHeight()
            .background(
                if (neon.dark) Color(0xFF04070E).copy(alpha = 0.7f)
                else Color.White.copy(alpha = 0.72f),
            )
            // Keep the rail tint full-bleed behind the status bar but inset
            // its contents (brand mark + items) so they clear the system clock
            // (device bug: top cuts into the status bar).
            .statusBarsPadding()
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        AnimatedBrandMark(size = 30.dp)
        Spacer(Modifier.size(2.dp))
        TabletSection.entries.forEach { item ->
            ActivityItem(item, item == section) { onPick(item) }
        }
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.Filled.AccountCircle,
            contentDescription = "Account",
            tint = neonAgentColor("claude", neon),
            modifier = Modifier.size(34.dp),
        )
    }
}

@Composable
private fun ActivityItem(item: TabletSection, selected: Boolean, onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
    val tint = if (selected) neon.accent else neon.textDim
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier = Modifier
            .width(66.dp)
            .clip(shape)
            .then(
                if (selected) {
                    Modifier
                        .background(neon.accent.copy(alpha = if (neon.dark) 0.12f else 0.08f))
                        .border(1.dp, neon.accent.copy(alpha = 0.4f), shape)
                } else {
                    Modifier
                },
            )
            .clickable(onClick = onClick)
            .padding(vertical = 11.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(iconFor(item), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Text(
            item.label,
            fontFamily = neon.sans,
            fontSize = 10.5.sp,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.SemiBold,
            color = tint,
        )
    }
}
