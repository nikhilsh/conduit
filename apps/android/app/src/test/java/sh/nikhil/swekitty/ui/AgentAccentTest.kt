package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Defends MOBILE-FEATURE-BACKLOG #9 (multi-agent visual identity) on
 * Android. Mirror of `apps/ios/Tests/SweKittyTests/AgentAccentTests.swift`.
 * Each known agent name must return its branded hue; unknown names
 * fall back to the neutral gray (NOT the copper brand accent — see
 * the iOS test for the rationale).
 *
 * Uses the pure (non-Composable) [SweKittyTheme.accentForAgentLightRgb]
 * accessors so the test runs under plain JUnit without a Compose
 * runtime.
 */
class AgentAccentTest {

    // 0xFFRRGGBB layout (Compose's `Color(0xFF…)` packing). The high
    // byte is alpha, which we always set to 0xFF. The `L` suffix is
    // required — these literals overflow Int.

    @Test fun claude_isAnthropicCopper() {
        assertEquals(0xFFCC785CL, SweKittyTheme.accentForAgentLightRgb("claude"))
    }

    @Test fun codex_isMonochrome() {
        // Codex brand wordmark is monochrome (white on dark, dark on
        // light) — switched off the emerald-500 (#10B981) which didn't
        // match marketing. Light theme gets a near-black accent so it
        // reads clearly against the light surface; dark counterpart is
        // #F5F5F5 (asserted by the dark-variant tests, not here).
        assertEquals(0xFF262626L, SweKittyTheme.accentForAgentLightRgb("codex"))
    }

    @Test fun hermes_isPurple() {
        assertEquals(0xFFA855F7L, SweKittyTheme.accentForAgentLightRgb("hermes"))
    }

    @Test fun pi_isBlue() {
        assertEquals(0xFF3B82F6L, SweKittyTheme.accentForAgentLightRgb("pi"))
    }

    @Test fun opencode_isOrange() {
        assertEquals(0xFFF97316L, SweKittyTheme.accentForAgentLightRgb("opencode"))
    }

    @Test fun unknown_fallsBackToNeutralGray() {
        // Unknown agents must NOT inherit the copper brand — a future
        // "claude-3" adapter would otherwise masquerade as the current
        // Claude tile. They get the neutral `accent` gray.
        assertEquals(0xFF4A4A4AL, SweKittyTheme.accentForAgentLightRgb("totally-fake"))
    }

    @Test fun match_isCaseInsensitive() {
        assertEquals(0xFFCC785CL, SweKittyTheme.accentForAgentLightRgb("CLAUDE"))
        assertEquals(0xFF262626L, SweKittyTheme.accentForAgentLightRgb("Codex"))
    }

    // --- Strong variant ---

    @Test fun claudeStrong_isDarker() {
        assertEquals(0xFFA85A3FL, SweKittyTheme.accentStrongForAgentLightRgb("claude"))
    }

    @Test fun codexStrong_isDarker() {
        // Strong variant pushes the monochrome accent further toward
        // pure black on light so filled avatars + selected states pop.
        assertEquals(0xFF0A0A0AL, SweKittyTheme.accentStrongForAgentLightRgb("codex"))
    }

    @Test fun unknownStrong_fallsBackToNeutral() {
        assertEquals(0xFF4A4A4AL, SweKittyTheme.accentStrongForAgentLightRgb("???"))
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
}
