import Testing
import Foundation
@testable import Conduit

/// Pins the pure reply-haptics decision (`ReplyHapticsModel`): which tap
/// (if any) to play as the chat's `isAgentWorking` busy flag flips, including
/// the "don't fire on a mid-turn open", debounce, and gate behaviours.
@Suite("ReplyHaptics")
struct ReplyHapticsTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstObservationNeverFires() {
        // A session opened mid-turn (already busy) must NOT tap — we only fire
        // on a transition we actually witnessed.
        var model = ReplyHapticsModel()
        #expect(model.observe(busy: true, enabled: true, now: t0) == nil)
    }

    @Test func firstObservationIdleAlsoSilent() {
        var model = ReplyHapticsModel()
        #expect(model.observe(busy: false, enabled: true, now: t0) == nil)
    }

    @Test func busyRiseFiresTurnStart() {
        var model = ReplyHapticsModel()
        _ = model.observe(busy: false, enabled: true, now: t0) // seed idle
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(1)) == .turnStart)
    }

    @Test func busyFallFiresTurnFinish() {
        var model = ReplyHapticsModel()
        _ = model.observe(busy: false, enabled: true, now: t0)
        _ = model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(1))
        #expect(model.observe(busy: false, enabled: true, now: t0.addingTimeInterval(5)) == .turnFinish)
    }

    @Test func noFlipNoFire() {
        var model = ReplyHapticsModel()
        _ = model.observe(busy: false, enabled: true, now: t0)
        // Same value re-observed (e.g. an unrelated re-render) → nothing.
        #expect(model.observe(busy: false, enabled: true, now: t0.addingTimeInterval(1)) == nil)
    }

    @Test func disabledSwallowsButStillTracks() {
        // While disabled (flag off / backgrounded) we don't tap, but we keep
        // tracking so the NEXT enabled transition is computed correctly and
        // doesn't spuriously fire on the stale state.
        var model = ReplyHapticsModel()
        _ = model.observe(busy: false, enabled: false, now: t0)
        // Rise while disabled → no tap.
        #expect(model.observe(busy: true, enabled: false, now: t0.addingTimeInterval(1)) == nil)
        // Re-enable, no flip (still busy) → still no tap (no spurious start).
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(2)) == nil)
        // Now a real fall while enabled → finish.
        #expect(model.observe(busy: false, enabled: true, now: t0.addingTimeInterval(5)) == .turnFinish)
    }

    @Test func debounceSwallowsRapidFlip() {
        // A status that blips busy→idle→busy faster than minInterval must not
        // machine-gun: only the first tap in the window fires.
        var model = ReplyHapticsModel(minInterval: 0.4)
        _ = model.observe(busy: false, enabled: true, now: t0)
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(0.0)) == .turnStart)
        // Falls 0.1s later — inside the 0.4s window → swallowed.
        #expect(model.observe(busy: false, enabled: true, now: t0.addingTimeInterval(0.1)) == nil)
        // Rises again 0.2s after start — still inside → swallowed.
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(0.2)) == nil)
    }

    @Test func debounceAllowsSpacedTurns() {
        // Real back-to-back turns a beat apart both fire.
        var model = ReplyHapticsModel(minInterval: 0.4)
        _ = model.observe(busy: false, enabled: true, now: t0)
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(0)) == .turnStart)
        #expect(model.observe(busy: false, enabled: true, now: t0.addingTimeInterval(2)) == .turnFinish)
        #expect(model.observe(busy: true, enabled: true, now: t0.addingTimeInterval(4)) == .turnStart)
    }
}
