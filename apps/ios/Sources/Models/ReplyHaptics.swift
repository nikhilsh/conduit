import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Decides — and plays — the haptic taps that punctuate an agent reply
/// (ChatGPT-style, but tasteful: one tap when a turn *starts*, one when it
/// *finishes* — never the continuous buzz-while-generating that ChatGPT
/// shipped and users widely asked to disable).
///
/// The decision is a **pure** fold over the chat view's `isAgentWorking`
/// busy flag so it can be unit-tested without a haptics engine or a SwiftUI
/// host (`ReplyHapticsModel`). The view owns one `ReplyHapticsModel` per
/// session and feeds it the busy flag on every change; the model returns a
/// `ReplyHapticEvent?` saying which tap (if any) to play, and the view
/// hands that to `ReplyHapticsPlayer` (the only impure part).
///
/// Spec (see PR body for sourcing):
///   - **start**  — `UIImpactFeedbackGenerator(.light)` the first time a turn
///     goes busy (`false → true`). Light = "something began", per Apple HIG.
///   - **finish** — `UINotificationFeedbackGenerator(.success)` when the turn
///     settles (`true → false`). Success = "completed", per HIG.
///   - **debounce** — flips closer together than `minInterval` are swallowed,
///     so a status that blips busy/idle/busy in a few hundred ms doesn't
///     machine-gun. The pure model is given `now` so this is testable.
///   - suppression when the app is backgrounded / the chat isn't visible is
///     the *caller's* job (it simply doesn't feed the model, or passes
///     `enabled: false`), keeping the model a pure state machine.
enum ReplyHapticEvent: Equatable {
    /// First content of a turn — a turn just started.
    case turnStart
    /// The turn settled — agent finished replying.
    case turnFinish
}

/// Pure, host-free decision state for one chat session's reply haptics.
///
/// Fed the `isAgentWorking` flag on each change. Tracks the last-known busy
/// state and the timestamp of the last fired event to debounce rapid flips.
struct ReplyHapticsModel {
    /// Flips closer together than this are swallowed (debounce). Tuned so a
    /// turn that momentarily blips idle mid-stream (status churn) doesn't
    /// fire a spurious finish+start pair, while still allowing back-to-back
    /// real turns a beat apart.
    static let defaultMinInterval: TimeInterval = 0.4

    private let minInterval: TimeInterval
    /// Last busy state we observed. `nil` before the first observation so the
    /// initial state (which may already be busy on a mid-turn open) does NOT
    /// fire a start — we only fire on an actual transition we witnessed.
    private var lastBusy: Bool?
    /// Wall-clock of the last event we *emitted* (for debounce).
    private var lastFiredAt: Date?

    init(minInterval: TimeInterval = ReplyHapticsModel.defaultMinInterval) {
        self.minInterval = minInterval
    }

    /// Fold a fresh busy observation into the model and return the haptic to
    /// play, if any. Pure — no side effects.
    ///
    /// - Parameters:
    ///   - busy: the chat's current `isAgentWorking` value.
    ///   - enabled: master gate (feature flag AND app-foreground AND chat
    ///     visible). When `false` we still track `busy` so a later transition
    ///     is computed correctly, but never emit.
    ///   - now: wall clock, injected for testability.
    mutating func observe(busy: Bool, enabled: Bool, now: Date) -> ReplyHapticEvent? {
        defer { lastBusy = busy }

        // First observation only seeds state — never fires (a mid-turn open
        // that's already busy shouldn't tap).
        guard let was = lastBusy else { return nil }
        guard was != busy else { return nil }

        let event: ReplyHapticEvent = busy ? .turnStart : .turnFinish

        guard enabled else { return nil }

        // Debounce: swallow flips that land within minInterval of the last
        // emitted tap.
        if let last = lastFiredAt, now.timeIntervalSince(last) < minInterval {
            return nil
        }
        lastFiredAt = now
        return event
    }
}

#if canImport(UIKit)
/// Plays the actual taps. The impure counterpart to `ReplyHapticsModel`.
///
/// Holds prepared generators so the first tap of a turn is low-latency
/// (`prepare()` warms the Taptic Engine). Re-`prepare()`s after each play so
/// the *next* tap is warm too. UIKit-only; a no-op shim is provided for other
/// platforms so call sites stay clean.
///
/// Note on Reduce Motion / system haptics: these generators are NOT gated by
/// Reduce Motion (that governs animation, not haptics). They no-op
/// automatically when the device has haptics disabled or unsupported, so we
/// don't read a private "system haptics" flag — the user-facing control is
/// the in-app feature-flag toggle.
@MainActor
final class ReplyHapticsPlayer {
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    init() {
        impact.prepare()
        notification.prepare()
    }

    func play(_ event: ReplyHapticEvent) {
        switch event {
        case .turnStart:
            impact.impactOccurred()
            impact.prepare()
        case .turnFinish:
            notification.notificationOccurred(.success)
            notification.prepare()
        }
        Telemetry.breadcrumb("haptics", "reply tap", data: [
            "event": event == .turnStart ? "start" : "finish",
        ])
    }
}
#endif
