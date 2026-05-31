import Testing
import SwiftUI
@testable import Conduit

/// Pins the upstream-faithful tool-card surface chosen in
/// `PLAN-CONDUIT-VISUAL-PARITY` PR 4. Before this PR `ConduitToolCard`
/// stacked `conduitGlassRoundedRect(tint: statusTint.opacity(0.20))`
/// over nested `ConduitLabeledOutputBlock` glass — once a code or diff
/// sub-block landed inside, you got card-inside-card-inside-card
/// (audit §A.2.3). PR 4 collapses to a single flat surfaceLight fill
/// at 0.6 opacity, status conveyed via a 6pt leading dot (audit
/// §A.2.8). If any of those values regress, the audit drift comes
/// back — this test catches it.
@Suite("Conduit tool-card surface")
struct ConduitToolCardSurfaceTests {

    @Test func statusDotIsSixPoints() {
        // Replaces `wrench.and.screwdriver.fill` (audit §A.2.8) — a
        // 6pt circle is the minimum that reads as a status indicator
        // from a normal reading distance; smaller drops below the
        // accessibility minimum tap-target hint zone.
        #expect(ConduitToolCardMetrics.statusDotSize == 6)
    }

    @Test func surfaceCornerMatchesCardDefault() {
        // 14pt matches `conduitGlassRoundedRect`'s new default landed
        // in PR 2. If the tool card drifts out of sync, cards inside
        // a settings card or inside a discovery section would no
        // longer nest cleanly.
        #expect(ConduitToolCardMetrics.surfaceCornerRadius == 14)
    }

    @Test func surfaceOpacityIsFlat() {
        // 0.6 — high enough that the card reads as a distinct surface
        // against the screen background, low enough that nested
        // code / diff blocks don't drown in stacked opacities.
        #expect(ConduitToolCardMetrics.surfaceOpacity == 0.6)
    }
}
