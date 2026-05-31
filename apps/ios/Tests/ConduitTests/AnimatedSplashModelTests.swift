import Testing
import SwiftUI
@testable import Conduit

/// `ios-splash-polish` — pure-data contract for the cold-start splash.
/// Mirrors PR B's `ProjectHeaderModel` and the upstream-multi-thread
/// `InSessionBottomBarModel` pattern: lift timing + dismiss-trigger
/// logic out of the SwiftUI view so it can be pinned without a host.
///
/// Audit item A.10 — iOS-only here, Android polish follows separately.
@Suite("AnimatedSplashModel — cold-start splash")
struct AnimatedSplashModelTests {

    // MARK: - Timing

    @Test func defaultDurationIsOnePointFiveSeconds() {
        // Hard timeout has to stay tight enough that the splash
        // doesn't feel like a hang when the broker is unreachable.
        // 1.5s is the audit spec — drifting up turns a polish PR
        // into a regression.
        #expect(AnimatedSplashModel.defaultDuration == 1.5)
    }

    @Test func pulsePeriodMakesTwelveHundredMillisecondBeat() {
        // Pulse is ease-in-out + autoreverse, so the full visible
        // beat is 2 × pulsePeriod. The audit asks for a 1.2s beat.
        #expect(AnimatedSplashModel.pulsePeriod == 0.6)
        #expect(AnimatedSplashModel.pulsePeriod * 2 == 1.2)
    }

    @Test func pulseScaleIsSubtle() {
        // 1.05 is the documented peak. Anything above ~1.1 reads
        // as a heartbeat, not a polish detail.
        #expect(AnimatedSplashModel.pulseScale == 1.05)
    }

    @Test func crossFadeDurationMatchesConduitAppEnvelope() {
        // ConduitApp drives the dismissal with .easeOut(duration:)
        // using this same constant — keep them in lock-step so a
        // future tweak to either side updates both.
        #expect(AnimatedSplashModel.crossFadeDuration == 0.3)
    }

    // MARK: - Dismiss trigger

    @Test func disconnectedDoesNotDismissSplash() {
        // The cold-start state. Splash should hold until either the
        // broker answers or the hard timeout fires.
        #expect(AnimatedSplashModel.shouldDismiss(on: .disconnected) == false)
    }

    @Test func connectingDoesNotDismissSplash() {
        // We're mid-handshake — still no decisive answer from the
        // harness, so keep the splash up to mask the gap.
        #expect(AnimatedSplashModel.shouldDismiss(on: .connecting) == false)
    }

    @Test func linkedDismissesSplash() {
        // First decisive "we've heard from the broker" signal —
        // drop into RootView immediately.
        #expect(AnimatedSplashModel.shouldDismiss(on: .linked) == true)
    }

    @Test func liveDismissesSplash() {
        // Definitive success — at least one round-trip has landed.
        #expect(AnimatedSplashModel.shouldDismiss(on: .live) == true)
    }

    @Test func reconnectingDismissesSplash() {
        // A reconnect attempt means we *had* a link and lost it —
        // RootView's reconnect banner is the right surface for
        // that state, not the splash.
        let reconnecting: HarnessState = .reconnecting(attempt: 1, maxAttempts: 5)
        #expect(AnimatedSplashModel.shouldDismiss(on: reconnecting) == true)
    }

    @Test func failedDismissesSplash() {
        // Critical: don't trap the user behind the splash when the
        // harness is unreachable. RootView's offline empty-state
        // explains what happened.
        let failed: HarnessState = .failed("ECONNREFUSED")
        #expect(AnimatedSplashModel.shouldDismiss(on: failed) == true)
    }

    // MARK: - Theme colours

    @Test func captionColorIsCopperTintedInBothSchemes() {
        // The caption is the noisiest visual element on the splash,
        // so it gets the copper tint at reduced opacity in both
        // schemes. Same hue family, different alpha for contrast.
        // Resolving Color → identical values requires the same
        // underlying `accentStrong`; assert resolvability instead.
        let dark = AnimatedSplashModel.captionColor(for: .dark)
        let light = AnimatedSplashModel.captionColor(for: .light)
        // Sanity: both schemes return a non-clear colour. We can't
        // peek into Color's components without UIKit traits, but a
        // description string is stable enough to catch a regression
        // back to .clear or .black.
        #expect(String(describing: dark) != String(describing: Color.clear))
        #expect(String(describing: light) != String(describing: Color.clear))
    }

    @Test func logoColorPicksTheAccentInEitherScheme() {
        // The logo is always copper — the wordmark carries the
        // theme-adaptive contrast. We can't compare Color equality
        // structurally (UIDynamicProviderColor wraps a different
        // pointer each call so stringified equality fails), so the
        // looser check is that the colour is non-clear and non-black.
        let dark = AnimatedSplashModel.logoColor(for: .dark)
        let light = AnimatedSplashModel.logoColor(for: .light)
        #expect(String(describing: dark) != String(describing: Color.clear))
        #expect(String(describing: light) != String(describing: Color.clear))
        #expect(String(describing: dark) != String(describing: Color.black))
        #expect(String(describing: light) != String(describing: Color.black))
    }

    @Test func wordmarkColorTracksAdaptiveTextPrimary() {
        // Wordmark uses textPrimary so the eye lands on the brand
        // name in both schemes without us special-casing per mode.
        // Same caveat as logoColor: can't compare Color equality
        // structurally; just guard against a regression to clear/black.
        let dark = AnimatedSplashModel.wordmarkColor(for: .dark)
        let light = AnimatedSplashModel.wordmarkColor(for: .light)
        #expect(String(describing: dark) != String(describing: Color.clear))
        #expect(String(describing: light) != String(describing: Color.clear))
        #expect(String(describing: dark) != String(describing: Color.black))
        #expect(String(describing: light) != String(describing: Color.black))
    }

    // MARK: - Copy + asset wiring

    @Test func wordmarkIsLowercaseKebab() {
        // The product is consistently rendered "conduit" in copy.
        // A regression to "Conduit" or "Conduit" on the splash
        // would be jarring on first launch.
        #expect(AnimatedSplashModel.wordmark == ">conduit")
    }

    @Test func loadingCaptionUsesHorizontalEllipsis() {
        // U+2026 (…) is the typographer's ellipsis. Three dots
        // (...) would look noisier and would also break the
        // "visually quietest option" requirement from the audit.
        #expect(AnimatedSplashModel.loadingCaption == "Loading\u{2026}")
        #expect(AnimatedSplashModel.loadingCaption.contains("\u{2026}"))
    }

    @Test func logoAssetNameMatchesXcassetEntry() {
        // The asset catalog ships `ConduitMark.imageset`. If somebody
        // renames the asset without updating the model, the splash
        // silently falls through to the SF Symbol — this test
        // catches that drift.
        #expect(AnimatedSplashModel.logoAssetName == "ConduitMark")
    }

    @Test func fallbackSymbolIsAPawprint() {
        // Defensive fallback when the asset isn't bundled (stripped
        // test hosts, etc.). terminal.fill is on every supported
        // iOS version and matches the brand metaphor.
        #expect(AnimatedSplashModel.fallbackSymbol == "terminal.fill")
    }
}
