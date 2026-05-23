import Testing
import SwiftUI
@testable import SweKitty

/// PLAN-LITTER-VISUAL-PARITY PR 1 — pins the token + corner-radius
/// surface so subsequent visual-parity PRs can rely on a stable
/// foundation. If anyone bumps `cardCornerRadius` back to 22 or
/// drops `textSystem` / `codeBackground`, this catches it before the
/// downstream rebuild PRs absorb the regression.
@Suite("Palette + Theme token surface")
struct PaletteTokensTests {

    // MARK: - New tokens added in PR 1

    @Test func textSystemTokenExists() {
        // Used by handoff / system-emitted bubble rendering; before
        // this PR non-LitterUI surfaces faked it with `textSecondary`
        // at lowered opacity.
        let pair = SweKittyPalette.textSystem
        #expect(!pair.light.isEmpty)
        #expect(!pair.dark.isEmpty)
    }

    @Test func codeBackgroundTokenExists() {
        // Used by inline + fenced code blocks. Was ad-hoc
        // `surface.opacity(0.72)` before PR 1.
        let pair = SweKittyPalette.codeBackground
        #expect(!pair.light.isEmpty)
        #expect(!pair.dark.isEmpty)
    }

    @Test func textSystemMatchesLitterReferenceHex() {
        // Hex values copied verbatim from litter's `LitterPalette.swift`
        // (§B.1 of the audit). If we re-derive them here, this test
        // catches the drift.
        #expect(SweKittyPalette.textSystem.light == "#3A4A3F")
        #expect(SweKittyPalette.textSystem.dark == "#C6D0CA")
    }

    @Test func codeBackgroundMatchesLitterReferenceHex() {
        #expect(SweKittyPalette.codeBackground.light == "#F0F0F5")
        #expect(SweKittyPalette.codeBackground.dark == "#111111")
    }

    // MARK: - Corner-radius shape tokens

    @Test func cardCornerRadiusIs14() {
        // Reduced from 22 → 14 in PR 1 to match litter's flatter
        // card shape. Hero-style cards that intentionally want the
        // larger radius should use `heroCardCornerRadius`.
        #expect(SweKittyTheme.cardCornerRadius == 14)
    }

    @Test func heroCardCornerRadiusKeeps22() {
        #expect(SweKittyTheme.heroCardCornerRadius == 22)
    }

    @Test func tagCornerRadiusIs4() {
        // Hard-edged inline tag / status chip.
        #expect(SweKittyTheme.tagCornerRadius == 4)
    }

    @Test func codeBlockCornerRadiusIs10() {
        #expect(SweKittyTheme.codeBlockCornerRadius == 10)
    }

    // MARK: - Glass shadow halved

    @Test func glassSolidShadowIsHalved() {
        // 0.16 → 0.08 in PR 1. Without this, glass surfaces drop a
        // "magazine" shadow that fights litter's near-flat treatment.
        #expect(GlassConfig.solid.shadowOpacity == 0.08)
        #expect(GlassConfig.transient.shadowOpacity == 0.08)
    }
}
