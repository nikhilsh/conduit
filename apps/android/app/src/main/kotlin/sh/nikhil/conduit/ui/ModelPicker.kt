package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.components.ConduitChip

// MARK: - Model picker (config-sheet redesign)
//
// Extracted from `AgentPickerSheet.kt` so the pipeline Builder's step /
// sub-step / fan-out-run model rows share this EXACT implementation
// instead of re-rolling a stock system dropdown per call site (owner ask:
// "make it look like the new session picker" + the duplicate-Default bug
// visible in the owner's Builder screenshot, caused by hand-rolled
// "Default" + `catalog.forEach` lists instead of the shared
// `forkModelOptions(assistant, catalog)` helper, which already folds the
// catalog's own "" entry and the static inherit sentinel into ONE row).
// Mirror of iOS `ConduitUI.ModelPickerRow` / `ConduitUI.ModelPickerSheet`.

/**
 * Model picker trigger row + sheet. Mirrors the fork chooser's model
 * dropdown (`SessionInfoScreen.kt`) and the iOS new-session model menu.
 * Reuses the shared per-assistant option/label helpers so the broker never
 * gets an alias it would drop. The default selection is the inherit
 * sentinel -> no `--model` override.
 */
@Composable
internal fun ModelPicker(
    assistant: String,
    model: String,
    catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?,
    onSelect: (String) -> Unit,
    fastMode: Boolean,
    onFastModeChange: (Boolean) -> Unit,
) {
    val neon = LocalNeonTheme.current
    var showSheet by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        ModelPickerSectionLabel("Model")
        // Trigger row — Conduit-styled, opens the model sheet (round-3: the
        // system DropdownMenu read as off-brand and clipped the captions).
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface)
                .clickable { showSheet = true },
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp).fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    modelCleanName(model, catalog),
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    color = neon.text,
                )
                Icon(Icons.Filled.ArrowDropDown, contentDescription = "Choose model", tint = neon.textDim)
            }
        }
        // The agent's own description of the (resolved) selection — e.g.
        // "Sonnet 4.6 · Efficient for routine tasks". Only when the live
        // catalog is in; the static fallback has none.
        forkModelDetail(model, catalog)?.let { detail ->
            Text(detail, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
        }
        // Fast-mode toggle — actionable when the selected model supports it.
        if (forkModelSupportsFastMode(model, catalog)) {
            FastModeToggle(checked = fastMode, onCheckedChange = onFastModeChange)
        }
    }
    if (showSheet) {
        ModelPickerSheet(
            assistant = assistant,
            selected = model,
            catalog = catalog,
            onSelect = {
                onSelect(it)
                showSheet = false
            },
            onDismiss = { showSheet = false },
        )
    }
}

/**
 * Lightweight model-row trigger + sheet -- no fast-mode toggle, no detail
 * caption (unlike [ModelPicker], the new-session flow's fuller variant).
 * Used by the pipeline Builder's step/sub-step/fan-out-run block config,
 * which has no fast-mode concept on `PipelineStepDraft`/`PipelineSubStepDraft`.
 * Mirror of iOS `ConduitUI.ModelPickerRow`.
 */
@Composable
internal fun ModelPickerRow(
    assistant: String,
    model: String,
    catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?,
    onSelect: (String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    var showSheet by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(13.dp), fill = neon.surface)
            .clickable { showSheet = true },
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp).fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                modelCleanName(model, catalog),
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = neon.sans,
                color = neon.text,
            )
            Icon(Icons.Filled.ArrowDropDown, contentDescription = "Choose model", tint = neon.textDim)
        }
    }
    if (showSheet) {
        ModelPickerSheet(
            assistant = assistant,
            selected = model,
            catalog = catalog,
            onSelect = {
                onSelect(it)
                showSheet = false
            },
            onDismiss = { showSheet = false },
        )
    }
}

/**
 * Clean display name for a model option, with the " (recommended)" suffix
 * [forkModelLabel] appends stripped — the sheet shows that as a badge, not
 * inline text.
 */
internal fun modelCleanName(option: String, catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?): String =
    forkModelLabel(option, catalog).removeSuffix(" (recommended)")

/** True when [option] is the catalog's recommended/default row. */
internal fun isRecommendedModel(option: String, catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?): Boolean {
    val entry = catalogEntryFor(option, catalog)
    return option == forkModelInherit ||
        entry?.isDefault == true ||
        entry?.displayName?.lowercase()?.startsWith("default") == true
}

/**
 * Conduit-styled model picker (round-3 fix 7): a ModalBottomSheet list
 * replacing the off-brand system DropdownMenu. Each row carries the clean
 * model name, a structured caption (the agent's own "·"-separated detail),
 * a RECOMMENDED badge on the default, and a checkmark on the selection.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelPickerSheet(
    assistant: String,
    selected: String,
    catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val tint = neonAgentColor(assistant, neon)
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val options = forkModelOptions(assistant, catalog)
    val agentName = assistant.replaceFirstChar { it.uppercaseChar() }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Agent header — which agent these models belong to.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AgentAvatar(assistant = assistant, size = 22.dp)
                Text(
                    "$agentName models",
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
            }
            options.forEach { option ->
                ModelRow(
                    name = modelCleanName(option, catalog),
                    caption = forkModelDetail(option, catalog),
                    recommended = isRecommendedModel(option, catalog),
                    selected = option == selected,
                    tint = tint,
                    onTap = { onSelect(option) },
                )
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
internal fun ModelRow(
    name: String,
    caption: String?,
    recommended: Boolean,
    selected: Boolean,
    tint: Color,
    onTap: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(13.dp),
                fill = if (selected) tint.copy(alpha = 0.12f) else neon.surface,
                borderColor = if (selected) tint else neon.border,
            )
            .clickable(onClick = onTap)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                Text(
                    name,
                    style = MaterialTheme.typography.bodyLarge,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
                if (recommended) {
                    ConduitChip(
                        label = "RECOMMENDED",
                        tint = tint,
                        selected = true,
                    )
                }
            }
            if (!caption.isNullOrEmpty()) {
                Text(caption, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
            }
        }
        if (selected) {
            Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = tint, modifier = Modifier.size(20.dp))
        } else {
            Box(Modifier.size(20.dp).clip(CircleShape).border(1.5.dp, neon.border, CircleShape))
        }
    }
}

@Composable
internal fun ModelPickerSectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        color = neon.textDim,
    )
}

/**
 * Reasoning-effort dial (§3, `03-ns`): one stop per effort level the
 * selected model supports — Fast/Balanced/Deep for the classic three,
 * growing to X-High/Max when the agent's catalog offers them. The track
 * fills up to (and including) the selected stop in the agent tint; a
 * consequence line + the raw API value chip sit beneath. Mirrors iOS
 * `effortDialSection`.
 */
@Composable
internal fun EffortDial(
    options: List<String>,
    effort: String,
    tint: Color,
    onSelect: (String) -> Unit,
    // Pipeline Builder's block config can opt out of an effort override
    // entirely (unlike new-session, where an effort is always chosen) --
    // when true, prepends a "Default" stop with value "" so the dial can
    // still represent "no override, inherit the pipeline's default effort".
    allowDefault: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    data class Stop(val label: String, val value: String, val desc: String)
    val stops = buildList {
        if (allowDefault) add(Stop("Default", "", "Inherits the pipeline's default reasoning effort."))
        addAll(options.map { Stop(effortLabel(it), it, effortDescription(it)) })
    }
    if (stops.isEmpty()) return
    val idx = stops.indexOfFirst { it.value == effort }
        .let { if (it < 0) minOf(1, stops.size - 1) else it }
    val cur = stops[idx]
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ModelPickerSectionLabel("Reasoning effort")
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.fillMaxWidth()) {
            stops.forEachIndexed { i, stop ->
                Column(
                    modifier = Modifier.weight(1f).clickable { onSelect(stop.value) },
                    verticalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(RoundedCornerShape(99.dp))
                            .background(if (i <= idx && !(allowDefault && idx == 0)) tint else neon.textFaint.copy(alpha = 0.25f)),
                    )
                    Text(
                        stop.label,
                        fontFamily = neon.sans,
                        fontSize = 13.sp,
                        fontWeight = if (i == idx) FontWeight.Bold else FontWeight.Medium,
                        color = if (i == idx) neon.text else neon.textFaint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface)
                .padding(horizontal = 13.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                cur.value,
                fontFamily = neon.mono,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = tint,
                modifier = Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(tint.copy(alpha = 0.12f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            Text(cur.desc, fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim)
        }
    }
}
