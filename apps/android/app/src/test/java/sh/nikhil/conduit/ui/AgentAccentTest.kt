package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Defends MOBILE-FEATURE-BACKLOG #9 (multi-agent visual identity) on
 * Android. Mirror of `apps/ios/Tests/ConduitTests/AgentAccentTests.swift`.
 * Each known agent name must return its branded hue; unknown names
 * fall back to the neutral gray (NOT the copper brand accent — see
 * the iOS test for the rationale).
 *
 * Uses the pure (non-Composable) [ConduitTheme.accentForAgentLightRgb]
 * accessors so the test runs under plain JUnit without a Compose
 * runtime.
 */
class AgentAccentTest {

    // 0xFFRRGGBB layout (Compose's `Color(0xFF…)` packing). The high
    // byte is alpha, which we always set to 0xFF. The `L` suffix is
    // required — these literals overflow Int.

    @Test fun claude_isWarmOrange() {
        // Conduit redesign tint: Claude reads as a warm orange
        // (--claude #FF9D4D, BRAND.md §3). Dark ships first (canonical
        // hex); this pins the light variant, deepened for legibility.
        assertEquals(0xFFE07A1EL, ConduitTheme.accentForAgentLightRgb("claude"))
    }

    @Test fun codex_isBrandCyan() {
        // Conduit redesign tint: Codex reads as the brand cyan (#22D3EE)
        // — matching the primary accent on purpose in the ice palette.
        // Light variant deepened (#0E90A8) for legibility.
        assertEquals(0xFF0E90A8L, ConduitTheme.accentForAgentLightRgb("codex"))
    }

    @Test fun hermes_isPurple() {
        assertEquals(0xFFA855F7L, ConduitTheme.accentForAgentLightRgb("hermes"))
    }

    @Test fun pi_isBlue() {
        assertEquals(0xFF3B82F6L, ConduitTheme.accentForAgentLightRgb("pi"))
    }

    @Test fun opencode_isLime() {
        // opencode brand tint: lime (#A3E635 dark / #6B9A0F light), distinct
        // from claude (orange) and codex (cyan). Matches NeonTheme.opencode.
        assertEquals(0xFF6B9A0FL, ConduitTheme.accentForAgentLightRgb("opencode"))
    }

    @Test fun unknown_fallsBackToNeutralGray() {
        // Unknown agents must NOT inherit the copper brand — a future
        // "claude-3" adapter would otherwise masquerade as the current
        // Claude tile. They get the neutral `accent` gray.
        assertEquals(0xFF4A4A4AL, ConduitTheme.accentForAgentLightRgb("totally-fake"))
    }

    @Test fun match_isCaseInsensitive() {
        assertEquals(0xFFE07A1EL, ConduitTheme.accentForAgentLightRgb("CLAUDE"))
        assertEquals(0xFF0E90A8L, ConduitTheme.accentForAgentLightRgb("Codex"))
    }

    // --- Strong variant ---

    @Test fun claudeStrong_isDarker() {
        assertEquals(0xFFC2630FL, ConduitTheme.accentStrongForAgentLightRgb("claude"))
    }

    @Test fun codexStrong_isDarker() {
        // Strong variant deepens the cyan on light so filled avatars +
        // selected states pop.
        assertEquals(0xFF0A7E95L, ConduitTheme.accentStrongForAgentLightRgb("codex"))
    }

    @Test fun unknownStrong_fallsBackToNeutral() {
        assertEquals(0xFF4A4A4AL, ConduitTheme.accentStrongForAgentLightRgb("???"))
    }

    // --- Avatar monogram ---

    @Test fun monogram_perAgent() {
        assertEquals("C", agentAvatarMonogram("claude"))
        // Codex breaks the "first letter" rule — C is already taken by
        // Claude, so Codex is "X" (Codex eXecution).
        assertEquals("X", agentAvatarMonogram("codex"))
        assertEquals("H", agentAvatarMonogram("hermes"))
        assertEquals("π", agentAvatarMonogram("pi"))
        assertEquals("O", agentAvatarMonogram("opencode"))
        // Unknown agent — first letter, uppercased.
        assertEquals("Z", agentAvatarMonogram("zeta"))
    }

    // --- Avatar brand glyph ---

    @Test fun agentGlyph_perAgent() {
        // Claude + Codex render a distinctive Material glyph in the
        // avatar; every other agent (and unknown) falls back to the
        // monogram (null glyph key).
        assertEquals("sparkle", agentGlyphKey("claude"))
        assertEquals("code", agentGlyphKey("Codex"))
        assertNull(agentGlyphKey("hermes"))
        assertNull(agentGlyphKey("zeta"))
    }
}
