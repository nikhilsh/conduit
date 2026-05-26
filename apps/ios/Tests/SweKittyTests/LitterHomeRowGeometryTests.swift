import Testing
import SwiftUI
@testable import SweKitty

/// Pins the home row metrics. Typography stays litter-faithful
/// (`PLAN-LITTER-VISUAL-PARITY` PR 3, audit §A.1.1) — a refactor that
/// restores the old loose `.title3.bold` row would reintroduce the audit
/// drift. The row chrome is the styling-polish card: the status dot now
/// lives INSIDE a contained glass card (it used to float in the screen
/// gutter to the left) with tightened padding so the row no longer reads
/// tall/empty. These expects catch a regression on either front.
@Suite("Litter HomeRow geometry")
struct LitterHomeRowGeometryTests {

    @Test func titleSizeIsFootnote() {
        #expect(HomeRowMetrics.titlePointSize == 13)
    }

    @Test func subtitleSizeIsCaption2() {
        #expect(HomeRowMetrics.subtitlePointSize == 11)
    }

    @Test func indicatorIsSevenPoints() {
        // 7pt filled dot per audit §A.1.7 — replaces the old SF Symbol
        // `circle.fill`/`circle` swap.
        #expect(HomeRowMetrics.indicatorSize == 7)
    }

    @Test func cardChromeIsContained() {
        // The dot + text sit INSIDE the card's internal padding, so
        // nothing floats against the screen gutter. Tight vertical
        // padding keeps the card from reading tall/empty.
        #expect(HomeRowMetrics.cardCornerRadius == 12)
        #expect(HomeRowMetrics.cardHorizontalPadding == 12)
        #expect(HomeRowMetrics.cardVerticalPadding == 9)
        #expect(HomeRowMetrics.dotTextSpacing == 10)
    }

    @Test func selectedCardCarriesBrandTint() {
        // Selection is conveyed by a brand-tinted card, not an SF Symbol
        // swap or a stale-green dot.
        #expect(HomeRowMetrics.selectedTintOpacity == 0.22)
    }
}
