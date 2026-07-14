package sh.nikhil.conduit.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.LocalNeonTheme

/**
 * Line-kind for a single row of a structured diff hunk. Wire values from
 * the broker `GET .../git/diff` response's `lines[].kind` (`"context"` /
 * `"add"` / `"del"`) -- mirror of iOS `ConduitUI.DiffLineKind`.
 */
enum class DiffLineKind(val wire: String) {
    CONTEXT("context"),
    ADD("add"),
    DEL("del"),
    ;

    companion object {
        fun fromWire(value: String?): DiffLineKind = when (value) {
            "add" -> ADD
            "del" -> DEL
            else -> CONTEXT
        }
    }
}

/**
 * One rendered line of a diff hunk. `old`/`new` are the broker's raw
 * gutter numbers (0 = not applicable to this line's kind -- `add` lines
 * carry `old=0`, `del` lines carry `new=0`, mirroring the wire contract).
 */
data class DiffLineData(
    val kind: DiffLineKind,
    val old: Int,
    val new: Int,
    val text: String,
) {
    /** The line number a comment on this line is anchored to (new for add/context, old for del). */
    val anchorLineNo: Int get() = if (kind == DiffLineKind.DEL) old else new
}

/**
 * Single monospace diff row: old/new gutter numbers, a kind-tinted
 * background + leading glyph, the line text, and (when [annotated]) a
 * trailing comment-gutter [ConduitChip]. Tapping the row invokes
 * [onClick] (opens the annotate sheet) when non-null. Android mirror of
 * iOS `ConduitUI.DiffLine`.
 */
@Composable
fun DiffLineRow(
    line: DiffLineData,
    modifier: Modifier = Modifier,
    annotated: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val neon = LocalNeonTheme.current
    val fg = when (line.kind) {
        DiffLineKind.ADD -> neon.green
        DiffLineKind.DEL -> neon.red
        DiffLineKind.CONTEXT -> neon.textDim
    }
    // Row-highlight tint derives from the same add/del theme tokens (no new
    // hex literal, no new pinned token) -- mirrors the established
    // DiffReviewScreen.InlineDiff precedent (`neon.green.copy(alpha=...)`).
    val bg = when (line.kind) {
        DiffLineKind.ADD -> neon.green.copy(alpha = 0.10f)
        DiffLineKind.DEL -> neon.red.copy(alpha = 0.10f)
        DiffLineKind.CONTEXT -> Color.Transparent
    }
    val glyph = when (line.kind) {
        DiffLineKind.ADD -> "+"
        DiffLineKind.DEL -> "-"
        DiffLineKind.CONTEXT -> " "
    }
    Row(
        modifier
            .fillMaxWidth()
            .background(bg)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 8.dp, vertical = 1.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            if (line.old > 0) "${line.old}" else "",
            modifier = Modifier.width(30.dp),
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
            maxLines = 1,
        )
        Text(
            if (line.new > 0) "${line.new}" else "",
            modifier = Modifier.width(30.dp),
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
            maxLines = 1,
        )
        Text(
            glyph,
            fontFamily = neon.mono,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = fg,
        )
        Text(
            line.text.ifEmpty { " " },
            modifier = Modifier.weight(1f),
            fontFamily = neon.mono,
            fontSize = 11.sp,
            color = if (line.kind == DiffLineKind.CONTEXT) neon.textDim else neon.text,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
        if (annotated) {
            ConduitChip(label = "•", tint = neon.accent)
        }
    }
}
