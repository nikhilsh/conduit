import Testing
import Foundation
@testable import Conduit

/// Pins `KeyboardAnimationLogic.sanitizedDuration` — the guard that stops a
/// degenerate keyboard-notification duration (0 / negative / non-finite)
/// from reaching `.spring(response:)`, which fatally crashed with
/// `CALayerInvalidGeometry: CALayer bounds contains NaN` when a duration of
/// 0 drove the response of the scroll-to-bottom spring animation.
@Suite("KeyboardAnimationLogic")
struct KeyboardAnimationLogicTests {

    @Test func normalDurationPassesThrough() {
        #expect(KeyboardAnimationLogic.sanitizedDuration(0.25) == 0.25)
        #expect(KeyboardAnimationLogic.sanitizedDuration(0.35) == 0.35)
    }

    @Test func zeroDurationFallsBack() {
        // The observed real-world trigger: iOS re-fires keyboardWillShow as
        // a no-op with duration 0 during the foreground reconcile refresh.
        #expect(KeyboardAnimationLogic.sanitizedDuration(0) == KeyboardAnimationLogic.fallbackDuration)
    }

    @Test func negativeDurationFallsBack() {
        #expect(KeyboardAnimationLogic.sanitizedDuration(-0.1) == KeyboardAnimationLogic.fallbackDuration)
    }

    @Test func nanDurationFallsBack() {
        #expect(KeyboardAnimationLogic.sanitizedDuration(.nan) == KeyboardAnimationLogic.fallbackDuration)
    }

    @Test func infiniteDurationFallsBack() {
        #expect(KeyboardAnimationLogic.sanitizedDuration(.infinity) == KeyboardAnimationLogic.fallbackDuration)
    }

    @Test func tinyPositiveDurationPassesThrough() {
        // Small but valid durations should NOT be clamped -- only the
        // degenerate zero/negative/non-finite cases.
        #expect(KeyboardAnimationLogic.sanitizedDuration(0.001) == 0.001)
    }
}
