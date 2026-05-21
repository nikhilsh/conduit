package sh.nikhil.swekitty.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * Free-function entry points for the per-agent accent map. The
 * canonical map lives on [SweKittyTheme] (mirror of iOS
 * `SweKittyTheme.accent(forAgent:)`); these are thin convenience
 * wrappers so call sites that don't already import the theme object
 * can write `agentAccent("claude")` directly.
 *
 * Mirrors `apps/ios/Sources/Views/AgentAvatar.swift`'s neighbouring
 * `SweKittyTheme.accent(forAgent:)` usage pattern. Per
 * MOBILE-FEATURE-BACKLOG item 9 (multi-agent visual identity), the
 * map ships five branded hues + a neutral fallback:
 *
 *  - claude   -> #CC785C  (Anthropic copper)
 *  - codex    -> #10B981  (emerald)
 *  - hermes   -> #A855F7  (purple)
 *  - pi       -> #3B82F6  (blue)
 *  - opencode -> #F97316  (orange)
 *  - default  -> #4A4A4A  (neutral gray)
 */
@Composable
@ReadOnlyComposable
fun agentAccent(agent: String): Color = SweKittyTheme.accent(forAgent = agent)

/**
 * High-emphasis variant of [agentAccent]. Use for filled avatars or
 * any chrome that needs to read clearly against the
 * `textOnAccent` foreground. See [SweKittyTheme.accentStrong].
 */
@Composable
@ReadOnlyComposable
fun agentAccentStrong(agent: String): Color = SweKittyTheme.accentStrong(forAgent = agent)
