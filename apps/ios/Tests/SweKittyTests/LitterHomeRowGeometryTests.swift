import Testing
import SwiftUI
@testable import SweKitty

/// Pins the litter-faithful home row metrics chosen in
/// `PLAN-LITTER-VISUAL-PARITY` PR 3. Before this PR the home row was
/// rendered at `.title3.bold` (~20pt) with `.padding(.horizontal, 14)
/// .vertical, 12`, which is roughly 2.8× litter's actual row density
/// (audit §A.1.1 / §A.1.2). If a refactor accidentally restores any of
/// the loose values, the row stops matching litter's reference and the
/// audit drift comes back — these expects catch that.
@Suite("Litter HomeRow geometry")
struct LitterHomeRowGeometryTests {

    @Test func titleSizeIsFootnote() {
        #expect(HomeRowMetrics.titlePointSize == 13)
    }

    @Test func subtitleSizeIsCaption2() {
        #expect(HomeRowMetrics.subtitlePointSize == 11)
    }

    @Test func leadingPaddingMatchesLitter() {
        // Litter's `SessionCanvasLine` runs flush to the left gutter
        // (`.padding(.leading, 1)`). The trailing side keeps a small
        // 8pt gap so the trailing chevron / time stamp doesn't kiss
        // the edge.
        #expect(HomeRowMetrics.leadingPadding == 1)
        #expect(HomeRowMetrics.trailingPadding == 8)
    }

    @Test func verticalPaddingMatchesLitter() {
        #expect(HomeRowMetrics.verticalPadding == 5)
    }

    @Test func indicatorIsSevenPoints() {
        // 7pt filled dot per audit §A.1.7 — replaces the old SF Symbol
        // `circle.fill`/`circle` swap.
        #expect(HomeRowMetrics.indicatorSize == 7)
    }

    @Test func activeRowFillMatchesLitter() {
        // Litter selects a row by painting a 6pt rounded rect at
        // 55% `surfaceLight` (audit §A.1.3). Both values matter — a
        // looser corner reads "tile," a tighter opacity reads "muted."
        #expect(HomeRowMetrics.activeRowCornerRadius == 6)
        #expect(HomeRowMetrics.activeRowOpacity == 0.55)
    }
}
