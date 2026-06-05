import Testing
import SwiftUI
import UIKit
@testable import Conduit

/// Per-agent accent map — defends MOBILE-FEATURE-BACKLOG #9 (multi-agent
/// visual identity). The map ships five branded hues + a neutral
/// fallback for unknown agents; a future refactor that collapses the
/// switch back to a single accent (or silently re-routes unknown to the
/// copper brand accent) should fail here.
@Suite("AgentAccent — per-agent color map")
struct AgentAccentTests {

    // MARK: - Light-mode RGB pins

    @Test func claudeIsWarmOrange() {
        // Conduit redesign tint: Claude reads as a warm orange
        // (--claude #FF9D4D, BRAND.md §3). Dark ships first, so the dark
        // value is the canonical hex; this pins the light variant, which
        // is deepened (#E07A1E) for legibility on a light surface.
        expectRGB(ConduitTheme.accent(forAgent: "claude"), hex: "#E07A1E")
    }

    @Test func codexIsBrandCyan() {
        // Conduit redesign tint: Codex reads as the brand cyan
        // (#22D3EE) — matching the primary accent on purpose in the ice
        // palette. Light variant deepened (#0E90A8) for legibility.
        expectRGB(ConduitTheme.accent(forAgent: "codex"), hex: "#0E90A8")
    }

    @Test func hermesIsPurple() {
        expectRGB(ConduitTheme.accent(forAgent: "hermes"), hex: "#A855F7")
    }

    @Test func piIsBlue() {
        expectRGB(ConduitTheme.accent(forAgent: "pi"), hex: "#3B82F6")
    }

    @Test func opencodeIsOrange() {
        expectRGB(ConduitTheme.accent(forAgent: "opencode"), hex: "#F97316")
    }

    @Test func unknownFallsBackToNeutralGray() {
        // Unknown agents must NOT inherit the brand copper — that would
        // make a future "claude-3" adapter masquerade as the current
        // Claude tile. They get the neutral `accent` gray instead.
        expectRGB(ConduitTheme.accent(forAgent: "totally-fake"), hex: "#4A4A4A")
    }

    @Test func matchIsCaseInsensitive() {
        expectRGB(ConduitTheme.accent(forAgent: "CLAUDE"), hex: "#E07A1E")
        expectRGB(ConduitTheme.accent(forAgent: "Codex"), hex: "#0E90A8")
    }

    // MARK: - Strong variant

    @Test func claudeStrongIsDarker() {
        expectRGB(ConduitTheme.accentStrong(forAgent: "claude"), hex: "#C2630F")
    }

    @Test func codexStrongIsDarker() {
        // Strong variant deepens the cyan on light so filled avatars +
        // selected states pop.
        expectRGB(ConduitTheme.accentStrong(forAgent: "codex"), hex: "#0A7E95")
    }

    @Test func unknownStrongFallsBackToNeutral() {
        expectRGB(ConduitTheme.accentStrong(forAgent: "???"), hex: "#4A4A4A")
    }

    // MARK: - Per-agent brand glyph

    @Test func claudeAndCodexHaveBrandGlyphs() {
        // Claude and Codex render a distinctive SF Symbol in the avatar;
        // every other agent (and unknown) falls back to the monogram
        // (nil glyph). Guards against a refactor that drops the per-agent
        // imagery or accidentally gives every agent the same mark.
        #expect(AgentAvatar.symbol(forAgent: "claude") == "sparkle")
        #expect(AgentAvatar.symbol(forAgent: "Codex") == "chevron.left.forwardslash.chevron.right")
        #expect(AgentAvatar.symbol(forAgent: "hermes") == nil)
        #expect(AgentAvatar.symbol(forAgent: "totally-fake") == nil)
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
