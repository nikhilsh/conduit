package sh.nikhil.conduit.ui

import android.annotation.SuppressLint
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Code
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Compose mirror of `apps/ios/Sources/Views/AgentAvatar.swift`.
 *
 * Small circular avatar for an agent (claude, codex, hermes, pi,
 * opencode). Used in any place that lists or picks agents — the
 * `AgentPickerSheet` rows, the thread switcher row list, and the
 * `SessionInfoScreen` hero. Not used inside the chat composer or the
 * header pill — those are already tinted via
 * [ConduitTheme.accent].
 *
 * Renders a single-letter monogram on a filled disc using
 * [ConduitTheme.accentStrong]. Falling back to a letter (rather
 * than a logo) means we don't ship third-party brand marks in the
 * APK and the avatar works for any agent the harness exposes.
 */
@Composable
fun AgentAvatar(
    assistant: String,
    modifier: Modifier = Modifier,
    size: Dp = 24.dp,
) {
    val fill = agentAccentStrong(assistant)
    val onAccent = ConduitTheme.textOnAccent()
    val logoRes = agentLogoRes(assistant)
    val glyph = agentGlyph(assistant)
    val monogram = monogramFor(assistant)
    val label = assistant.replaceFirstChar { it.uppercaseChar() }

    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            // Brand logos sit on a white disc (they're designed for a
            // light background — otherwise the black Codex knot is
            // invisible on the dark sheet); glyph/monogram fallbacks sit
            // on the accent disc.
            .then(if (logoRes == null) Modifier.background(fill) else Modifier.background(Color.White))
            .border(0.5.dp, onAccent.copy(alpha = 0.15f), CircleShape)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        when {
            // Divided by the optical-size correction (device feedback:
            // gemini/opencode read visibly smaller than claude/codex at the
            // same padding, since the source art isn't uniformly cropped)
            // so every agent occupies the same visual weight.
            logoRes != null -> Image(
                painter = painterResource(logoRes),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().padding(size * 0.16f / agentGlyphRenderScale(assistant)),
            )
            glyph != null -> Icon(
                // Claude / Codex get a distinctive brand glyph; other
                // agents keep the monogram.
                imageVector = glyph,
                contentDescription = null,
                tint = onAccent,
                modifier = Modifier.size(size * 0.5f),
            )
            else -> Text(
                text = monogram,
                color = onAccent,
                style = TextStyle(
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = (size.value * 0.5f).sp,
                ),
            )
        }
    }
}

/**
 * Bare tinted per-agent glyph -- no background disc/tile, just the real
 * brand mark (Claude starburst / Codex knot / opencode mark), or the icon
 * / monogram letter fallback when no mark is bundled, tinted with the
 * agent's theme color. This is the ConduitUI list-row idiom ("rows lead
 * with a bare tinted symbol, not a filled tile" -- see [ConduitNavRow] /
 * iOS `ConduitListRow`). Use this instead of [AgentAvatar] in any
 * row-leading position; reserve [AgentAvatar]'s filled disc for picker /
 * hero contexts that want a heavier visual anchor. Mirror of iOS
 * `AgentGlyph` (`apps/ios/Sources/Shared/AgentAvatar.swift`).
 */
@Composable
fun AgentGlyph(
    assistant: String,
    modifier: Modifier = Modifier,
    size: Dp = 20.dp,
) {
    val tint = agentAccent(assistant)
    val logoRes = agentLogoRes(assistant)
    val glyph = agentGlyph(assistant)
    val label = assistant.replaceFirstChar { it.uppercaseChar() }

    Box(
        modifier = modifier
            .size(size)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        when {
            logoRes != null -> Icon(
                // Real brand mark, tinted -- Icon's default ColorFilter
                // (BlendMode.SrcIn) replaces the source color entirely
                // using only the drawable's alpha, so this tints cleanly
                // even though the source PNG isn't a pure single color.
                // Scaled by the same optical-size correction as
                // [AgentAvatar] so gemini/opencode don't read smaller than
                // claude/codex; stays well inside the outer `size` Box, so
                // this can't overflow/clip.
                painter = painterResource(logoRes),
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(size * 0.62f * agentGlyphRenderScale(assistant)),
            )
            glyph != null -> Icon(
                imageVector = glyph,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(size * 0.62f),
            )
            else -> Text(
                text = monogramFor(assistant),
                color = tint,
                style = TextStyle(
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = (size.value * 0.58f).sp,
                ),
            )
        }
    }
}

/**
 * Resolves the bundled brand-logo drawable for an agent, if the app owner
 * has supplied the official artwork (`claude_mark` / `codex_mark`). Looked
 * up by name at runtime so a missing drawable degrades to [agentGlyph] /
 * [monogramFor] rather than failing the build — we don't bundle the
 * artwork here; it's added under the trademark attribution in the
 * Licenses screen. Returns null when absent or for agents without a logo.
 */
@SuppressLint("DiscouragedApi")
@Composable
private fun agentLogoRes(assistant: String): Int? {
    val name = when (assistant.lowercase()) {
        "claude"   -> "claude_mark"
        "codex"    -> "codex_mark"
        "gemini"   -> "gemini_mark"
        "opencode" -> "opencode_mark"
        else       -> return null
    }
    val ctx = LocalContext.current
    return ctx.resources.getIdentifier(name, "drawable", ctx.packageName).takeIf { it != 0 }
}

/**
 * Per-agent optical-size correction for the bundled brand-mark drawables.
 * The source art isn't uniformly cropped -- gemini's and opencode's marks
 * carry more effective padding than claude's/codex's at the same
 * `ContentScale.Fit` frame, so they read visibly smaller even in an
 * identical container (device feedback). Applied as an extra multiplier by
 * both [AgentAvatar] and [AgentGlyph] so every agent's logo occupies
 * roughly the same optical weight at any size. `1f` is a no-op; only the
 * two under-sized marks are scaled up. Mirror of iOS
 * `AgentAvatar.glyphRenderScale(forAgent:)`.
 */
private fun agentGlyphRenderScale(assistant: String): Float =
    when (assistant.lowercase()) {
        "gemini", "opencode" -> 1.25f
        else -> 1f
    }

/**
 * Per-agent brand glyph. Claude → a sparkle, Codex → the code-brackets
 * mark. Returns null for agents we don't have a glyph for (they fall
 * back to [monogramFor]). Neutral Material symbols rather than shipping
 * Anthropic / OpenAI logo artwork in the APK. The string key is exposed
 * via [agentGlyphKey] for plain-JVM unit tests.
 */
private fun agentGlyph(assistant: String): ImageVector? = when (agentGlyphKey(assistant)) {
    "sparkle" -> Icons.Filled.AutoAwesome
    "code"    -> Icons.Filled.Code
    else      -> null
}

internal fun agentGlyphKey(assistant: String): String? = when (assistant.lowercase()) {
    "claude" -> "sparkle"
    "codex"  -> "code"
    else     -> null
}

/**
 * Per-agent monogram. Codex breaks the "first letter" pattern — "C"
 * already belongs to Claude, so Codex gets "X" (Codex eXecution, and
 * visually distinct from C). Everything else is the first letter.
 */
internal fun monogramFor(assistant: String): String = when (assistant.lowercase()) {
    "claude"   -> "C"
    "codex"    -> "X"
    "hermes"   -> "H"
    "pi"       -> "π"
    "opencode" -> "O"
    else       -> assistant.take(1).uppercase()
}

/** Visible-for-tests overload that bypasses Compose for unit tests. */
internal fun agentAvatarMonogram(assistant: String): String = monogramFor(assistant)
