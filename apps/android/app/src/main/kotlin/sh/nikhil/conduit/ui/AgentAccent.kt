package sh.nikhil.conduit.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * Free-function entry points for the per-agent accent map, resolved
 * against the active Neon palette ([neonAgentColor] over
 * [LocalNeonTheme]). Replaces the legacy copper-brand
 * `ConduitTheme.accent(forAgent:)` so agents follow the selected
 * palette: claude stays orange, codex takes the palette accent, hermes
 * purple, pi blue, others the secondary accent — matching the design
 * bundle's "agent colours constant so agents stay recognizable" rule
 * (and the iOS `neon.agentTint(forAgent:)`).
 */
@Composable
@ReadOnlyComposable
fun agentAccent(agent: String): Color = neonAgentColor(agent, LocalNeonTheme.current)

/**
 * High-emphasis variant of [agentAccent]. The Neon palette carries a
 * single per-agent hue (no separate "strong" tier), so this resolves to
 * the same [neonAgentColor]; kept as a distinct entry point for call
 * sites (filled avatars) that document the high-emphasis intent.
 */
@Composable
@ReadOnlyComposable
fun agentAccentStrong(agent: String): Color = neonAgentColor(agent, LocalNeonTheme.current)
