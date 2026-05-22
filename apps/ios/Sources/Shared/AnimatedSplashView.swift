import SwiftUI
import UIKit

/// Pure-data description of the cold-start splash. Lifted out of the
/// SwiftUI view so timing + dismiss-trigger logic can be unit-tested
/// without a host controller. Mirrors PR B's `ProjectHeaderModel`
/// pattern (and `InSessionBottomBarModel` from the litter-multi-thread
/// PR): the view is dumb, the model is the contract.
///
/// Audit item A.10 — iOS-only here, Android polish follows in a
/// separate PR.
struct AnimatedSplashModel: Equatable {
    /// Hard timeout: dismiss the splash this long after appearance even
    /// if the broker never answers. Keeps the splash from lingering
    /// forever when the harness is unreachable.
    static let defaultDuration: TimeInterval = 1.5

    /// Pulse duration for one half-cycle (1.0 → 1.05). The animation
    /// repeats forever / autoreverses so the full beat is 2× this.
    static let pulsePeriod: TimeInterval = 0.6

    /// Cross-fade duration applied when the splash dismisses into the
    /// real UI underneath. Matches the 0.3s in `SweKittyApp`'s
    /// `.animation(.easeOut(...), value: showSplash)` envelope.
    static let crossFadeDuration: TimeInterval = 0.3

    /// Peak scale during the pulse cycle.
    static let pulseScale: CGFloat = 1.05

    /// Visible caption beneath the wordmark. Quietest of the three
    /// candidates discussed in the audit (vs. a spinner or three-dot
    /// indicator) — single soft string, no spinning chrome.
    static let loadingCaption = "Loading\u{2026}"

    /// The brand wordmark rendered under the logo. Lower-case kebab
    /// matches the GitHub repo name + the in-product copy elsewhere.
    static let wordmark = "swe-kitty"

    /// Name of the brand image in `Assets.xcassets`. The view falls
    /// back to a copper SF Symbol if the asset is missing so the
    /// splash is never blank.
    static let logoAssetName = "KittyMark"

    /// SF Symbol used as a fallback when the asset isn't installed
    /// (e.g. in a stripped test bundle).
    static let fallbackSymbol = "pawprint.fill"

    /// Whether the supplied `HarnessState` represents a "we've heard
    /// from the broker" signal that should dismiss the splash. Any
    /// terminal-ish state qualifies — including `.failed`, so an
    /// unreachable harness still drops the user onto RootView (which
    /// has its own offline empty-state) rather than holding the
    /// splash for the full timeout.
    static func shouldDismiss(on state: HarnessState) -> Bool {
        switch state {
        case .disconnected, .connecting:
            return false
        case .linked, .live, .reconnecting, .failed:
            return true
        }
    }

    /// Caption colour. Copper at low opacity in either theme so the
    /// brand accent reads on both dark and light backgrounds without
    /// a heavy-handed contrast bump.
    static func captionColor(for scheme: ColorScheme) -> Color {
        SweKittyTheme.accentStrong.opacity(scheme == .dark ? 0.85 : 0.75)
    }

    /// Logo tint. Always the strong copper accent — the wordmark
    /// stays in `textPrimary` so the eye lands on it without the two
    /// glyphs fighting each other.
    static func logoColor(for scheme: ColorScheme) -> Color {
        _ = scheme
        return SweKittyTheme.accentStrong
    }

    /// Wordmark colour. Adaptive primary text — black-ish in light
    /// mode, off-white in dark.
    static func wordmarkColor(for scheme: ColorScheme) -> Color {
        _ = scheme
        return SweKittyTheme.textPrimary
    }
}

/// Brief launch splash. Shows the swe-kitty mark over the standard
/// background gradient with a subtle pulse, holds, then cross-fades
/// out into `RootView` underneath. Mirrors the Android `AnimatedSplash.kt`
/// (Android polish follows in a separate PR).
///
/// Dismisses on whichever fires first:
///   • the first decisive harness signal (`.linked` / `.live` /
///     `.failed` / a reconnect attempt), i.e. we've heard from the
///     broker; OR
///   • the `AnimatedSplashModel.defaultDuration` timeout, so the
///     splash never lingers when the broker is unreachable.
///
/// Wired in `SweKittyApp` as an overlay on top of `RootView` so the
/// real UI is mounted underneath and ready by the time the splash
/// fades — no blank window once the splash dismisses.
struct AnimatedSplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SessionStore.self) private var store

    let onFinish: () -> Void

    @State private var entered: Bool = false
    @State private var pulsing: Bool = false
    @State private var dismissed: Bool = false

    var body: some View {
        ZStack {
            SweKittyTheme.backgroundGradient(for: colorScheme)
                .ignoresSafeArea()

            // Subtle copper-tinted glow centred on the logo so the
            // background isn't completely flat. Cheap radial gradient
            // — no blur cost, reads as ambient warmth in dark mode.
            RadialGradient(
                colors: [
                    SweKittyTheme.accentStrong.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 240
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                logoView
                    .frame(width: 96, height: 96)
                    .foregroundStyle(AnimatedSplashModel.logoColor(for: colorScheme))
                    .shadow(
                        color: SweKittyTheme.accentStrong.opacity(0.32),
                        radius: 22, x: 0, y: 10
                    )
                    .scaleEffect(pulsing ? AnimatedSplashModel.pulseScale : 1.0)
                    .accessibilityLabel("SweKitty")

                Text(AnimatedSplashModel.wordmark)
                    .font(.system(size: 36, weight: .semibold, design: .serif))
                    .foregroundStyle(AnimatedSplashModel.wordmarkColor(for: colorScheme))

                Text(AnimatedSplashModel.loadingCaption)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AnimatedSplashModel.captionColor(for: colorScheme))
                    .padding(.top, 4)
            }
            .scaleEffect(entered ? 1.0 : 0.92)
            .opacity(entered ? 1.0 : 0.0)
        }
        .onAppear { startSequence() }
        .onChange(of: store.harness) { _, newState in
            if AnimatedSplashModel.shouldDismiss(on: newState) {
                finish()
            }
        }
        .allowsHitTesting(false)
    }

    /// Use the `KittyMark` asset when present, fall back to a copper
    /// SF Symbol otherwise. Keeps the splash from going blank in
    /// stripped-asset builds (e.g. some unit-test hosts).
    @ViewBuilder
    private var logoView: some View {
        if UIImage(named: AnimatedSplashModel.logoAssetName) != nil {
            Image(AnimatedSplashModel.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            Image(systemName: AnimatedSplashModel.fallbackSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
        }
    }

    private func startSequence() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            entered = true
        }
        // Pulse: ease-in-out, autoreverse, repeat forever. Full beat
        // is 2 × pulsePeriod = 1.2s, which matches the audit spec.
        withAnimation(
            .easeInOut(duration: AnimatedSplashModel.pulsePeriod)
                .repeatForever(autoreverses: true)
        ) {
            pulsing = true
        }
        // Hard timeout — fires regardless of broker state so the
        // splash never lingers when the network is gone.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AnimatedSplashModel.defaultDuration
        ) {
            finish()
        }
    }

    private func finish() {
        guard !dismissed else { return }
        dismissed = true
        // Cross-fade duration is governed by the .animation modifier
        // on `showSplash` in SweKittyApp; just hand the dismissal
        // signal up so SwiftUI can run the transition.
        onFinish()
    }
}
