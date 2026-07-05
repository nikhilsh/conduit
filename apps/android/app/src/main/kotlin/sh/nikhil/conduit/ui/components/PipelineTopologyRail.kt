package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.AgentAvatar
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.NeonTheme

/**
 * PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md §3.1). One
 * entry in [PipelineTopologyRail] -- agent/role/gate/fanout only, no
 * config detail. Mirror of iOS `ConduitUI.PipelineTopologyItem`.
 */
data class PipelineTopologyItem(
    val id: String,
    val agentType: String,
    val role: String,
    val gateAfter: Boolean,
    /** 0 = no fanout; otherwise the declared run count. */
    val fanoutCount: Int,
)

/**
 * Compact, read-only rail rendering a not-yet-started harness's block stack
 * top-to-bottom -- mirrors the visual shape `PipelineMonitorScreen` already
 * draws for a RUNNING pipeline (leading agent avatar, index, fanout badge,
 * indented run cluster, gate marker) but carries no live-run state. Mirror
 * of iOS `ConduitUI.PipelineTopologyRail`.
 */
@Composable
fun PipelineTopologyRail(
    items: List<PipelineTopologyItem>,
    modifier: Modifier = Modifier,
    onSelect: (String) -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    Column(modifier = modifier) {
        items.forEachIndexed { index, item ->
            TopologyRow(item = item, index = index, isLast = index == items.lastIndex, neon = neon, onSelect = onSelect)
        }
    }
}

@Composable
private fun TopologyRow(
    item: PipelineTopologyItem,
    index: Int,
    isLast: Boolean,
    neon: NeonTheme,
    onSelect: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onSelect(item.id) }
                .padding(vertical = 2.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AgentAvatar(assistant = item.agentType, size = 20.dp)
            Text(
                "${index + 1}. ${item.role.replaceFirstChar { it.uppercase() }}",
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                fontSize = 11.sp,
                color = neon.text,
                maxLines = 1,
            )
            if (item.fanoutCount > 0) {
                Text(
                    "${item.fanoutCount}x",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 9.sp,
                    color = neon.accent,
                    modifier = Modifier
                        .background(neon.accent.copy(alpha = 0.15f), RoundedCornerShape(50))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
        }

        if (item.fanoutCount > 0) {
            Row(
                modifier = Modifier.padding(start = 9.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                androidx.compose.foundation.layout.Box(
                    modifier = Modifier.width(1.dp).height(12.dp).background(neon.border.copy(alpha = 0.6f)),
                )
                Text(
                    "${item.fanoutCount} parallel runs",
                    fontFamily = neon.mono,
                    fontSize = 9.sp,
                    color = neon.textFaint,
                )
            }
        }

        if (!isLast) {
            if (item.gateAfter) {
                Row(
                    modifier = Modifier.padding(start = 9.dp),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    androidx.compose.foundation.layout.Box(
                        modifier = Modifier.width(1.dp).height(8.dp).background(neon.yellow.copy(alpha = 0.6f)),
                    )
                    Icon(
                        Icons.Filled.PanTool,
                        contentDescription = "Gate",
                        tint = neon.yellow,
                        modifier = Modifier.height(8.dp),
                    )
                    Text(
                        "gate",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 8.sp,
                        color = neon.yellow,
                    )
                }
            } else {
                Spacer(Modifier.height(2.dp))
                androidx.compose.foundation.layout.Box(
                    modifier = Modifier
                        .padding(start = 9.dp)
                        .width(1.dp)
                        .height(8.dp)
                        .background(neon.border.copy(alpha = 0.4f)),
                )
            }
        }
    }
}
