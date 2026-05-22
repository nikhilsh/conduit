import Testing
import Foundation
@testable import SweKitty

/// sweswe-parity audit — pins the visibility contract of
/// `ViewerCountBadgeModel`. The view body is a one-line
/// `if let label = model.label` so testing the model fully covers the
/// rendering decision: any drift between the rules below and the
/// actual rendered surface is a model bug, not a view bug.
@Suite("ViewerCountBadgeModel — viewer count visibility & label")
struct ViewerCountBadgeModelTests {

    @Test func nilCountIsInvisible() {
        // Broker hasn't emitted `viewer_count` yet (either it's a stale
        // pre-parity broker or the first status frame hasn't landed).
        // Don't reserve layout space — render literally nothing.
        let model = ViewerCountBadgeModel(count: nil)
        #expect(model.label == nil)
        #expect(model.accessibilityLabel == nil)
        #expect(!model.isVisible)
    }

    @Test func zeroCountIsInvisible() {
        // Defensive: the broker should never broadcast 0 (you are
        // always at least your own viewer), but if it does we still
        // refuse to render. Otherwise an off-by-one in the broker
        // would surface as a confusing "👥 0" pill.
        let model = ViewerCountBadgeModel(count: 0)
        #expect(!model.isVisible)
    }

    @Test func singleViewerIsInvisible() {
        // You are the only viewer. Announcing yourself to yourself is
        // noise — the badge only earns screen real estate when there
        // is genuinely someone else watching.
        let model = ViewerCountBadgeModel(count: 1)
        #expect(model.label == nil)
        #expect(!model.isVisible)
    }

    @Test func twoViewersRendersPill() {
        // Minimum interesting case — one extra viewer. The pill must
        // render with the "👥 N" label so the rest of the UI can hint
        // at the shared session.
        let model = ViewerCountBadgeModel(count: 2)
        #expect(model.label == "👥 2")
        #expect(model.isVisible)
    }

    @Test func largerCountsRenderExactNumber() {
        // No clamping / "9+" abbreviation in v1: the broker caps the
        // fan-out at a sensible number anyway, and seeing the exact
        // count is more useful than a vague indicator while we're
        // still iterating on the multi-viewer story.
        let model = ViewerCountBadgeModel(count: 7)
        #expect(model.label == "👥 7")
    }

    @Test func accessibilityLabelSpellsOutCount() {
        // VoiceOver reads the codepoint of "👥" as "people" or worse;
        // override with a literal phrase so the spoken output is
        // useful instead of confusing.
        let model = ViewerCountBadgeModel(count: 3)
        #expect(model.accessibilityLabel == "3 viewers")
    }

    @Test func accessibilityLabelIsNilWhenHidden() {
        // The model's visibility decisions must stay consistent — if
        // the pill is hidden, the accessibility label is hidden too.
        // Otherwise VoiceOver would announce a pill that isn't on
        // screen.
        let modelOne = ViewerCountBadgeModel(count: 1)
        #expect(modelOne.accessibilityLabel == nil)

        let modelNil = ViewerCountBadgeModel(count: nil)
        #expect(modelNil.accessibilityLabel == nil)
    }
}
