import Testing
import SwiftUI
import UIKit
@testable import SweKitty

/// Per-agent accent map — defends MOBILE-FEATURE-BACKLOG #9 (multi-agent
/// visual identity). The map ships five branded hues + a neutral
/// fallback for unknown agents; a future refactor that collapses the
/// switch back to a single accent (or silently re-routes unknown to the
/// copper brand accent) should fail here.
@Suite("AgentAccent — per-agent color map")
struct AgentAccentTests {

    // MARK: - Light-mode RGB pins

    @Test func claudeIsAnthropicCopper() {
        expectRGB(SweKittyTheme.accent(forAgent: "claude"), hex: "#CC785C")
    }

    @Test func codexIsMonochrome() {
        // Codex's brand wordmark is monochrome (white on dark, dark on
        // light) — the previous emerald-500 (#10B981) didn't match
        // marketing. Light theme gets a near-black so the accent stays
        // legible against the light surface; the dark counterpart lives
        // in `codexAccent.dark` (#F5F5F5) and isn't checked here because
        // expectRGB pins the light variant only.
        expectRGB(SweKittyTheme.accent(forAgent: "codex"), hex: "#262626")
    }

    @Test func hermesIsPurple() {
        expectRGB(SweKittyTheme.accent(forAgent: "hermes"), hex: "#A855F7")
    }

    @Test func piIsBlue() {
        expectRGB(SweKittyTheme.accent(forAgent: "pi"), hex: "#3B82F6")
    }

    @Test func opencodeIsOrange() {
        expectRGB(SweKittyTheme.accent(forAgent: "opencode"), hex: "#F97316")
    }

    @Test func unknownFallsBackToNeutralGray() {
        // Unknown agents must NOT inherit the brand copper — that would
        // make a future "claude-3" adapter masquerade as the current
        // Claude tile. They get the neutral `accent` gray instead.
        expectRGB(SweKittyTheme.accent(forAgent: "totally-fake"), hex: "#4A4A4A")
    }

    @Test func matchIsCaseInsensitive() {
        expectRGB(SweKittyTheme.accent(forAgent: "CLAUDE"), hex: "#CC785C")
        expectRGB(SweKittyTheme.accent(forAgent: "Codex"), hex: "#262626")
    }

    // MARK: - Strong variant

    @Test func claudeStrongIsDarker() {
        expectRGB(SweKittyTheme.accentStrong(forAgent: "claude"), hex: "#A85A3F")
    }

    @Test func codexStrongIsDarker() {
        // Strong variant pushes the monochrome accent further toward
        // pure black on light so filled avatars + selected states pop.
        expectRGB(SweKittyTheme.accentStrong(forAgent: "codex"), hex: "#0A0A0A")
    }

    @Test func unknownStrongFallsBackToNeutral() {
        expectRGB(SweKittyTheme.accentStrong(forAgent: "???"), hex: "#4A4A4A")
    }

    // MARK: - Helpers

    /// Resolves the SwiftUI `Color` in a fixed light trait collection so
    /// the test result is deterministic regardless of the simulator
    /// theme (the palette is adaptive — light/dark differ).
    private func expectRGB(_ color: Color, hex: String) {
        let trait = UITraitCollection(userInterfaceStyle: .light)
        let resolved = UIColor(color).resolvedColor(with: trait)
        let expected = UIColor(Color(hex: hex))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        resolved.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        expected.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        // 1.5/255 tolerance — hex round-trip can rebase a component by
        // a single bit on some color spaces.
        let tolerance: CGFloat = 1.5 / 255.0
        #expect(abs(r1 - r2) < tolerance, "red component mismatch for \(hex)")
        #expect(abs(g1 - g2) < tolerance, "green component mismatch for \(hex)")
        #expect(abs(b1 - b2) < tolerance, "blue component mismatch for \(hex)")
    }
}
