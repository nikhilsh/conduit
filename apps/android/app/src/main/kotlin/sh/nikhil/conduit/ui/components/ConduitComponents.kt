package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.glassCapsule
import sh.nikhil.conduit.ui.glassRoundedRect

// ---------------------------------------------------------------------------
// ConduitCard
// ---------------------------------------------------------------------------

/**
 * The base card surface for the design component library. Applies the
 * glass rounded-rect surface (border + glow/elevation via [glassRoundedRect])
 * with configurable internal padding. Radius inherits the current
 * [ConduitTheme.cardCornerRadiusDp] token so PR 3's radius update
 * propagates automatically.
 */
@Composable
fun ConduitCard(
    modifier: Modifier = Modifier,
    pad: androidx.compose.ui.unit.Dp = 14.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth().glassRoundedRect().padding(pad), content = content)
}

// ---------------------------------------------------------------------------
// ConduitRow (base) + factory variants
// ---------------------------------------------------------------------------

/**
 * Base list row: leading icon, title + optional subtitle column, a
 * spacer, and an optional trailing slot. A hairline divider is drawn
 * below unless [last] is true. Tap handling via [onClick].
 */
@Composable
fun ConduitRow(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    iconTint: Color? = null,
    last: Boolean = false,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val neon = LocalNeonTheme.current
    Column(modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .heightIn(min = 44.dp)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = iconTint ?: neon.accent,
                modifier = Modifier.size(20.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    fontFamily = neon.sans,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (subtitle != null) {
                    Text(
                        subtitle,
                        fontFamily = neon.sans,
                        fontSize = 12.sp,
                        color = neon.textDim,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(6.dp))
            trailing?.invoke()
        }
        if (!last) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
        }
    }
}

/**
 * Navigation row: [ConduitRow] with a trailing chevron arrow indicating
 * that tapping navigates to a deeper screen.
 */
@Composable
fun ConduitNavRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    iconTint: Color? = null,
    last: Boolean = false,
    onClick: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    ConduitRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        iconTint = iconTint,
        last = last,
        onClick = onClick,
    ) {
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = neon.textDim,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * Value-display row: [ConduitRow] with a trailing mono-text value label.
 * Use for read-only data pairs (e.g. "Version" / "1.2.3").
 */
@Composable
fun ConduitValueRow(
    icon: ImageVector,
    title: String,
    value: String,
    subtitle: String? = null,
    iconTint: Color? = null,
    last: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    ConduitRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        iconTint = iconTint,
        last = last,
    ) {
        Text(value, fontFamily = neon.mono, fontSize = 13.sp, color = neon.textDim)
    }
}

/**
 * Toggle row: [ConduitRow] with a Material3 [Switch] trailing, tinted
 * to [NeonTheme.accent] when checked.
 */
@Composable
fun ConduitToggleRow(
    icon: ImageVector,
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    subtitle: String? = null,
    iconTint: Color? = null,
    last: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    ConduitRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        iconTint = iconTint,
        last = last,
    ) {
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = neon.accent),
        )
    }
}

// ---------------------------------------------------------------------------
// ConduitChip
// ---------------------------------------------------------------------------

/**
 * Small label chip using the glass capsule surface. [selected] fills the
 * capsule with a SOLID [tint] (or [NeonTheme.accent]) and switches the
 * label to [NeonTheme.accentText] for legibility on the filled surface --
 * `glassCapsule(tint = ...)` only recolors the BORDER/glow, keeping the
 * background at the plain dark `neon.surface`, so routing the selected
 * state through it read as near-invisible `accentText` on a dark surface
 * (owner: "selected options cannot be read", pipeline Builder #911
 * follow-up). Unselected chips keep the standard capsule chrome with
 * [tint] or [NeonTheme.text].
 *
 * [leadingIcon] mirrors iOS ConduitUI.Chip's `systemImage` slot: when
 * non-null a small [Icon] (~11dp) is rendered before the label text.
 */
@Composable
fun ConduitChip(
    label: String,
    modifier: Modifier = Modifier,
    tint: Color? = null,
    selected: Boolean = false,
    leadingIcon: ImageVector? = null,
) {
    val neon = LocalNeonTheme.current
    val fg = when {
        selected -> neon.accentText
        tint != null -> tint
        else -> neon.text
    }
    val chipShape = RoundedCornerShape(percent = 50)
    val base = if (selected) {
        modifier
            .clip(chipShape)
            .background(color = tint ?: neon.accent, shape = chipShape)
    } else {
        modifier.glassCapsule(tint = tint)
    }
    Row(
        base.padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = fg,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(
            label,
            fontFamily = neon.mono,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = fg,
            maxLines = 1,
        )
    }
}

// ---------------------------------------------------------------------------
// NeonSegmentedPill
// ---------------------------------------------------------------------------

/**
 * Descriptor for a single segment in [NeonSegmentedPill]. Kept as a top-level
 * class (not nested under the composable) to avoid a Kotlin name clash.
 */
data class NeonPillSegment(
    val label: String,
    val icon: ImageVector? = null,
)

/**
 * Floating segmented pill — Android mirror of iOS `NeonSegmentedPill`
 * (NeonChrome.swift). A glass-capsule container with the ACTIVE segment
 * filled with [NeonTheme.accent] and [NeonTheme.accentText] label;
 * inactive segments use [NeonTheme.textDim]. Labels are mono 12sp semibold.
 * An optional [NeonPillSegment.icon] mirrors the iOS `systemImage` slot.
 *
 * @param segments  ordered list of [NeonPillSegment] descriptors
 * @param selected  index of the currently active segment
 * @param onSelect  called with the tapped segment index
 */
@Composable
fun NeonSegmentedPill(
    segments: List<NeonPillSegment>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = modifier
            .glassCapsule()
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        segments.forEachIndexed { i, seg ->
            val isActive = i == selected
            val fg = if (isActive) neon.accentText else neon.textDim
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(percent = 50))
                    .background(if (isActive) neon.accent else Color.Transparent)
                    .clickable { onSelect(i) }
                    .padding(horizontal = 14.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                if (seg.icon != null) {
                    Icon(
                        seg.icon,
                        contentDescription = null,
                        tint = fg,
                        modifier = Modifier.size(11.dp),
                    )
                }
                Text(
                    seg.label,
                    fontFamily = neon.mono,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = fg,
                    maxLines = 1,
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ConduitActionPill
// ---------------------------------------------------------------------------

/**
 * Visual variant for [ConduitActionPill]. Mirrors [ConduitUI.ActionPill.Variant] on iOS.
 *
 * - [Soft]  — low-opacity tint fill; foreground = tint. Status badge look ("ACTIVE").
 * - [Solid] — solid tint fill; foreground = [NeonTheme.accentText]. CTA action look
 *             ("Open guide", "Connect", "Review").
 */
enum class ActionPillVariant { Soft, Solid }

/**
 * Small capsule pill extracted from the hand-rolled pills in the home screen.
 * Mirrors iOS [ConduitUI.ActionPill] value-for-value.
 *
 * Soft:  [RoundedCornerShape](percent=50) background at tint alpha=0.14, foreground = tint,
 *        mono 10sp bold, padding (h6dp, v2dp). Optional [leadingIcon] at 10dp.
 * Solid: solid tint background, foreground = [NeonTheme.accentText],
 *        sans 12sp semibold, padding (h11dp, v6dp). Optional [leadingIcon] at 10dp.
 *
 * When [onClick] is non-null the pill is made [clickable]; otherwise it is static.
 * [tint] defaults to [NeonTheme.accent] when null.
 */
@Composable
fun ConduitActionPill(
    label: String,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    leadingIcon: ImageVector? = null,
    variant: ActionPillVariant = ActionPillVariant.Soft,
    tint: Color? = null,
) {
    val neon = LocalNeonTheme.current
    val (fill, fg) = resolveActionPillColors(
        variant = variant,
        tint = tint,
        accent = neon.accent,
        accentText = neon.accentText,
    )
    val hPad = if (variant == ActionPillVariant.Soft) 6.dp else 11.dp
    val vPad = if (variant == ActionPillVariant.Soft) 2.dp else 6.dp
    val shape = RoundedCornerShape(percent = 50)
    Row(
        modifier
            .clip(shape)
            .background(fill)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = hPad, vertical = vPad),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = fg,
                modifier = Modifier.size(10.dp),
            )
        }
        val fontSize = if (variant == ActionPillVariant.Soft) 10.sp else 12.sp
        val fontWeight = if (variant == ActionPillVariant.Soft) FontWeight.Bold else FontWeight.SemiBold
        val fontFamily = if (variant == ActionPillVariant.Soft) neon.mono else neon.sans
        Text(
            label,
            fontFamily = fontFamily,
            fontSize = fontSize,
            fontWeight = fontWeight,
            color = fg,
            maxLines = 1,
        )
    }
}

// ---------------------------------------------------------------------------
// ConduitStatTile
// ---------------------------------------------------------------------------

/**
 * Metric tile occupying a [RowScope] weight slot. Renders a large [value]
 * (bold mono) above a small [label] (uppercase mono dim). [tint] overrides
 * the value colour for semantic states (e.g. green for success, red for
 * errors). Intended to be placed inside a [Row] with [fillMaxWidth]/[weight].
 */
@Composable
fun RowScope.ConduitStatTile(value: String, label: String, tint: Color? = null) {
    val neon = LocalNeonTheme.current
    Column(
        Modifier
            .weight(1f)
            .glassRoundedRect()
            .padding(14.dp),
    ) {
        Text(
            value,
            fontFamily = neon.mono,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            color = tint ?: neon.text,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            label.uppercase(),
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textDim,
        )
    }
}

// ---------------------------------------------------------------------------
// ConduitButton
// ---------------------------------------------------------------------------

/** Visual variant for [ConduitButton]. */
enum class ButtonVariant { Primary, Secondary, Ghost }

/**
 * Full-width branded button in three variants:
 * - [ButtonVariant.Primary] — solid fill ([NeonTheme.green] by default),
 *   [NeonTheme.accentText] label. Use for the single primary CTA per screen.
 * - [ButtonVariant.Secondary] — glass rounded-rect with [tint]-colored
 *   border/glow (falls back to [NeonTheme.accent]), accent-colored label.
 * - [ButtonVariant.Ghost] — outlined only (1dp border at 35% alpha),
 *   accent-colored label. Lowest visual weight.
 *
 * The Secondary variant uses [glassRoundedRect] with its [tint] parameter
 * (added in this PR as a library extension) so the neon chrome surface
 * recolors the border and glow to the button's accent — matching the
 * iOS ConduitUI.Components.ConduitButton.secondary fidelity.
 *
 * [enabled] mirrors iOS's caller-side `.disabled(_:)` + dimmed opacity:
 * when false the button ignores taps and renders at 45% opacity. Added
 * because several call sites previously had to fall back to a raw M3
 * `Button` just to get a disabled state (see `FoundSessionsSheet`) — this
 * closes that gap in the shared component instead of forking another one.
 */
@Composable
fun ConduitButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    variant: ButtonVariant = ButtonVariant.Primary,
    tint: Color? = null,
    enabled: Boolean = true,
    // Optional leading slot (e.g. a spinner while a request is in flight,
    // or a static glyph) rendered before the title. Additive/nil-default so
    // every existing title-only call site is unaffected.
    leadingContent: (@Composable () -> Unit)? = null,
) {
    val neon = LocalNeonTheme.current
    val accent = tint ?: if (variant == ButtonVariant.Primary) neon.green else neon.accent
    val fg = if (variant == ButtonVariant.Primary) neon.accentText else accent
    val shape = RoundedCornerShape(14.dp)
    val base = modifier
        .fillMaxWidth()
        .alpha(if (enabled) 1f else 0.45f)
        .then(
            when (variant) {
                ButtonVariant.Primary ->
                    Modifier
                        .clip(shape)
                        .background(accent)
                ButtonVariant.Secondary ->
                    // glassRoundedRect tint extension added in this PR;
                    // recolors the border and glow to the button accent.
                    Modifier.glassRoundedRect(cornerRadiusDp = 14f, tint = accent)
                ButtonVariant.Ghost ->
                    Modifier
                        .clip(shape)
                        .border(1.dp, accent.copy(alpha = 0.35f), shape)
            },
        )
        .clickable(enabled = enabled, onClick = onClick)
        .padding(vertical = 14.dp)
    Box(base, contentAlignment = Alignment.Center) {
        if (leadingContent != null) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                leadingContent()
                Text(
                    title,
                    fontFamily = neon.sans,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    color = fg,
                )
            }
        } else {
            Text(
                title,
                fontFamily = neon.sans,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                color = fg,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Pure logic helpers (unit-testable without Compose runtime)
// ---------------------------------------------------------------------------

/**
 * Resolve the fill and foreground [Color] for a [ConduitActionPill].
 * Extracted so tests can pin the logic without a Compose runtime.
 *
 * @param variant    the requested [ActionPillVariant]
 * @param tint       caller-supplied color override (null = use [accent])
 * @param accent     the resolved [NeonTheme.accent] value
 * @param accentText the resolved [NeonTheme.accentText] value
 * @return Pair of (fill, foreground)
 */
fun resolveActionPillColors(
    variant: ActionPillVariant,
    tint: Color?,
    accent: Color,
    accentText: Color,
): Pair<Color, Color> {
    val resolvedTint = tint ?: accent
    return when (variant) {
        ActionPillVariant.Soft  -> resolvedTint.copy(alpha = 0.14f) to resolvedTint
        ActionPillVariant.Solid -> resolvedTint to accentText
    }
}

/**
 * Resolve the foreground [Color] for a [ConduitChip] given the [selected]
 * state. Extracted so tests can pin the logic without a Compose runtime.
 *
 * @param selected whether the chip is in the selected/active state
 * @param tint     caller-supplied accent override (null = theme default)
 * @param accent   the resolved [NeonTheme.accent] value
 * @param accentText the resolved [NeonTheme.accentText] value
 * @param text     the resolved [NeonTheme.text] value
 */
fun resolveChipFg(
    selected: Boolean,
    tint: Color?,
    accent: Color,
    accentText: Color,
    text: Color,
): Color = when {
    selected -> accentText
    tint != null -> tint
    else -> text
}

/**
 * Resolve the foreground and accent [Color] for a [ConduitButton].
 * Extracted for unit testing.
 *
 * @param variant  the requested [ButtonVariant]
 * @param tint     caller-supplied color override (null = theme default)
 * @param green    [NeonTheme.green] — default Primary fill
 * @param accent   [NeonTheme.accent] — default Secondary/Ghost accent
 * @param accentText [NeonTheme.accentText] — text color on solid fills
 * @return Pair of (buttonAccent, labelFg)
 */
fun resolveButtonColors(
    variant: ButtonVariant,
    tint: Color?,
    green: Color,
    accent: Color,
    accentText: Color,
): Pair<Color, Color> {
    val buttonAccent = tint ?: if (variant == ButtonVariant.Primary) green else accent
    val labelFg = if (variant == ButtonVariant.Primary) accentText else buttonAccent
    return buttonAccent to labelFg
}
