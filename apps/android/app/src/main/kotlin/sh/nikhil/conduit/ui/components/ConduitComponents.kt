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
 * capsule with [tint] (or [NeonTheme.accent]) and switches the label to
 * [NeonTheme.accentText] for legibility on the filled surface. Unselected
 * chips use the standard capsule chrome with [tint] or [NeonTheme.text].
 */
@Composable
fun ConduitChip(
    label: String,
    modifier: Modifier = Modifier,
    tint: Color? = null,
    selected: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    val fg = when {
        selected -> neon.accentText
        tint != null -> tint
        else -> neon.text
    }
    Box(
        modifier
            .glassCapsule(tint = if (selected) (tint ?: neon.accent) else tint)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
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
 */
@Composable
fun ConduitButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    variant: ButtonVariant = ButtonVariant.Primary,
    tint: Color? = null,
) {
    val neon = LocalNeonTheme.current
    val accent = tint ?: if (variant == ButtonVariant.Primary) neon.green else neon.accent
    val fg = if (variant == ButtonVariant.Primary) neon.accentText else accent
    val shape = RoundedCornerShape(14.dp)
    val base = modifier
        .fillMaxWidth()
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
        .clickable(onClick = onClick)
        .padding(vertical = 14.dp)
    Box(base, contentAlignment = Alignment.Center) {
        Text(
            title,
            fontFamily = neon.sans,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
            color = fg,
        )
    }
}

// ---------------------------------------------------------------------------
// Pure logic helpers (unit-testable without Compose runtime)
// ---------------------------------------------------------------------------

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
