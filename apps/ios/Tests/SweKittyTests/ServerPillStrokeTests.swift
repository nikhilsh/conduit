import Testing
import SwiftUI
@testable import SweKitty

/// Pins the litter-faithful stroke treatment chosen for `ServerPill`
/// in `PLAN-LITTER-VISUAL-PARITY` PR 5. Before this PR every pill
/// carried a `glassCapsule(interactive: true, tint: …)` fill — active
/// vs idle differed only by tint, which was indistinguishable at a
/// glance in bright daylight. PR 5 swaps to a transparent background +
/// 1.2pt accent stroke (active) or 0.6pt muted stroke (inactive).
///
/// Tests pin the values so a future "tightening" can't quietly drop
/// the active stroke to 0.4pt (the audit's failure mode — invisible
/// border becomes "no affordance at all").
@Suite("ServerPill stroke")
struct ServerPillStrokeTests {

    @Test func activePillCarriesLoudStroke() {
        #expect(ServerPillStroke.activeWidth == 1.2)
        #expect(ServerPillStroke.activeOpacity == 0.75)
    }

    @Test func inactivePillCarriesQuietStroke() {
        #expect(ServerPillStroke.inactiveWidth == 0.6)
        #expect(ServerPillStroke.inactiveOpacity == 0.25)
    }

    @Test func activeStrokeIsThickerThanInactive() {
        // Even if the absolute widths change, the active pill must
        // remain visibly thicker than the inactive one — otherwise
        // the "which server am I on?" affordance evaporates.
        #expect(ServerPillStroke.activeWidth > ServerPillStroke.inactiveWidth)
        #expect(ServerPillStroke.activeOpacity > ServerPillStroke.inactiveOpacity)
    }
}

/// Pins the post-audit (§A.4.2) icon size for `LitterAddServerSheet`
/// rows. Before PR 5 each row showed a 36pt filled-color circle; the
/// audit called this out as reading "launchpad" rather than
/// "settings sheet." 28pt symbol-only matches the rest of the LitterUI
/// row pattern.
@Suite("LitterAddServerSheet metrics")
struct LitterAddServerSheetMetricsTests {

    @Test func iconSizeIs28() {
        #expect(LitterAddServerSheetMetrics.iconSize == 28)
    }
}
