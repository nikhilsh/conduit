import Foundation
import Observation
import SwiftUI
import UIKit

/// User-tunable appearance settings: chat body font, theme override,
/// and turn-collapse preference. Persisted to `UserDefaults.standard`
/// so the choice survives relaunch.
///
/// Lives at app root, injected as an `@Environment` value into any
/// view that needs to honour it (currently `ConversationView` for the
/// monospaced body font, `SettingsSheet`/`AppearanceSheet` for the UI).
@Observable
final class AppearanceStore {
    enum FontFamily: String, CaseIterable, Identifiable {
        case serif
        case system
        case monospaced

        var id: String { rawValue }
        var label: String {
            switch self {
            case .serif:      return "Serif"
            case .system:     return "System"
            case .monospaced: return "Monospaced"
            }
        }
    }

    /// Color theme for the experimental native (libghostty) terminal.
    /// Self-contained mirror of `GhosttyVT.GhosttyTheme` — same rawValues
    /// so `GhosttyTerminalView` can map across the module boundary with a
    /// plain `init(rawValue:)`. Kept here (rather than re-exporting the
    /// GhosttyVT enum) so the model layer + its tests don't have to link
    /// libghostty. Only applies on the `experimentalNativeTerminal` path.
    enum GhosttyTerminalTheme: String, CaseIterable, Identifiable {
        case ghosttyDark
        case solarizedDark
        case nord
        case dracula
        case gruvboxDark

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ghosttyDark:   return "Ghostty Dark"
            case .solarizedDark: return "Solarized Dark"
            case .nord:          return "Nord"
            case .dracula:       return "Dracula"
            case .gruvboxDark:   return "Gruvbox Dark"
            }
        }
    }

    /// Palette choice for the "Neon Terminal" theme system. RawValues
    /// are the stable persistence ids and match `NeonPalette` /
    /// Android `NeonPalette.id` one-for-one. The resolved tokens live in
    /// `NeonTheme.resolve(...)`; the effective dark/light comes from
    /// `themeMode` (reused — there is no separate neon mode setting).
    enum NeonPaletteChoice: String, CaseIterable, Identifiable {
        case ice
        case synth
        case matrix
        case amber

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ice:    return "Ice"
            case .synth:  return "Synthwave"
            case .matrix: return "Matrix"
            case .amber:  return "Amber CRT"
            }
        }

        /// Bridge to the resolved-token enum in `NeonTheme.swift`. Kept
        /// as a 1:1 rawValue mapping so the model layer (+ its tests)
        /// doesn't have to depend on the Theme layer's type.
        var neonPalette: NeonPalette { NeonPalette(rawValue: rawValue) ?? .ice }
    }

    enum ThemeMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    private enum Keys {
        static let font = "conduit.appearance.font"
        static let theme = "conduit.appearance.theme"
        static let collapseTurns = "conduit.appearance.collapseTurns"
        /// Stage 0 feature flag for the Ghostty-libghostty native
        /// terminal path. See docs/PLAN-TERMINAL-REWRITE.md. Defaults
        /// off; xterm.js stays the production renderer until Stage 2.
        static let experimentalNativeTerminal = "conduit.experimental.nativeTerminal"
        /// Trash-rebuild feature flag for the parallel `ConduitUI/` view
        /// tree. When on, `ConduitApp` renders `ConduitUI.RootView`
        /// instead of the current `RootView`. Off by default for this
        /// PR — follow-up PRs flip the default and delete the old
        /// views. See `docs/PLAN-CONDUIT-UI.md`.
        static let experimentalConduitUI = "conduit.experimental.conduitUI"
        /// Body point size for the typography ramp
        /// (`ConduitTypography`). User-tunable within
        /// [bodyPointSizeRange]; everything in the ramp scales off this.
        static let bodyPointSize = "conduit.appearance.bodyPointSize"
        /// Font size (points) libghostty renders the native terminal grid
        /// at. Only consumed on the `experimentalNativeTerminal` path.
        static let ghosttyFontSize = "conduit.appearance.ghosttyFontSize"
        /// Color theme rawValue for the native (libghostty) terminal.
        /// Only consumed on the `experimentalNativeTerminal` path.
        static let ghosttyTerminalTheme = "conduit.appearance.ghosttyTerminalTheme"
        /// Palette choice for the Neon Terminal theme system
        /// (`NeonPaletteChoice` rawValue). Resolved into tokens by
        /// `NeonTheme.resolve(...)` and injected via `\.neonTheme`.
        static let neonPalette = "conduit.appearance.neonPalette"
        /// Glow on/off toggle for the Neon Terminal theme system.
        static let neonGlow = "conduit.appearance.neonGlow"
    }

    /// Clamp range for the native-terminal font size. Lower bound keeps a
    /// dense grid legible on iPhone; upper bound stops the grid collapsing
    /// to a few columns. Stepper steps by 1.
    static let ghosttyFontSizeRange: ClosedRange<Double> = 8...24
    /// Default native-terminal font size. The 13pt default tested too
    /// large on device; 10pt gives a denser, real-terminal feel while
    /// staying legible on iPhone. Users can still adjust via the 8–24
    /// Settings slider.
    static let defaultGhosttyFontSize: Double = 10

    /// Clamp range for [bodyPointSize]. Lower bound keeps captions
    /// readable; upper bound prevents headings from blowing out the
    /// composer / list rows.
    static let bodyPointSizeRange: ClosedRange<CGFloat> = 12...18
    /// Default chosen to match upstream's `ConduitFont.conversationBodyPointSize`
    /// starting value at the centre of the slider's range.
    static let defaultBodyPointSize: CGFloat = 14

    var fontFamily: FontFamily {
        didSet { defaults.set(fontFamily.rawValue, forKey: Keys.font) }
    }

    var themeMode: ThemeMode {
        didSet {
            defaults.set(themeMode.rawValue, forKey: Keys.theme)
            applyToWindows()
        }
    }

    var collapseTurns: Bool {
        didSet { defaults.set(collapseTurns, forKey: Keys.collapseTurns) }
    }

    /// Stage 0 feature flag — when on, the Terminal tab renders via the
    /// experimental Ghostty-libghostty path (`GhosttyTerminalView`)
    /// instead of the production xterm.js path (`TerminalTabXterm`).
    /// See `docs/PLAN-TERMINAL-REWRITE.md`. The xterm.js path stays
    /// the default until Stage 2 of that plan ships.
    var experimentalNativeTerminal: Bool {
        didSet { defaults.set(experimentalNativeTerminal, forKey: Keys.experimentalNativeTerminal) }
    }

    /// Trash-rebuild flag — when true, the app boots into the parallel
    /// `ConduitUI` view tree rather than the legacy `RootView`. Default
    /// `false`; users opt in via Settings → Experimental → "Conduit UI
    /// (preview)". See `apps/ios/Sources/ConduitUI/` and
    /// `docs/PLAN-CONDUIT-UI.md`.
    var experimentalConduitUI: Bool {
        didSet { defaults.set(experimentalConduitUI, forKey: Keys.experimentalConduitUI) }
    }

    /// Font size libghostty renders the native terminal at. Setter
    /// clamps into [ghosttyFontSizeRange] and persists. A change here is
    /// picked up live by `GhosttyTerminalView` (config update + PTY-grid
    /// resync). Only applies on the `experimentalNativeTerminal` path.
    var ghosttyFontSize: Double = AppearanceStore.defaultGhosttyFontSize {
        didSet {
            let clamped = ghosttyFontSize.clamped(to: Self.ghosttyFontSizeRange)
            if clamped != ghosttyFontSize {
                ghosttyFontSize = clamped
                return
            }
            defaults.set(ghosttyFontSize, forKey: Keys.ghosttyFontSize)
        }
    }

    /// Color theme for the native (libghostty) terminal. Persisted by
    /// rawValue; applied live by `GhosttyTerminalView`. Only applies on
    /// the `experimentalNativeTerminal` path.
    var ghosttyTerminalTheme: GhosttyTerminalTheme {
        didSet { defaults.set(ghosttyTerminalTheme.rawValue, forKey: Keys.ghosttyTerminalTheme) }
    }

    /// Neon Terminal palette choice. Persisted by rawValue; resolved
    /// into a `NeonTheme` at the app root and injected via the
    /// `\.neonTheme` environment. The effective dark/light is taken
    /// from `themeMode` (no separate neon mode setting).
    var neonPalette: NeonPaletteChoice {
        didSet { defaults.set(neonPalette.rawValue, forKey: Keys.neonPalette) }
    }

    /// Neon Terminal glow on/off. Persisted; flows into
    /// `NeonTheme.resolve(...)` so later card work can render (or skip)
    /// the layered glow shadows.
    var neonGlow: Bool {
        didSet { defaults.set(neonGlow, forKey: Keys.neonGlow) }
    }

    /// Base point size the typography ramp (`ConduitTypography`)
    /// scales off. Setter clamps into [bodyPointSizeRange] so an
    /// out-of-range value (corrupted defaults, future migration) can't
    /// blow out the layout. Persisted on every set.
    var bodyPointSize: CGFloat = AppearanceStore.defaultBodyPointSize {
        didSet {
            let clamped = bodyPointSize.clamped(to: Self.bodyPointSizeRange)
            if clamped != bodyPointSize {
                bodyPointSize = clamped
                return
            }
            defaults.set(Double(bodyPointSize), forKey: Keys.bodyPointSize)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // New default is serif (matches the Claude iOS chat reference);
        // existing installs that explicitly chose monospaced/system keep
        // their preference because the persisted rawValue still resolves.
        self.fontFamily = (defaults.string(forKey: Keys.font)
            .flatMap(FontFamily.init(rawValue:))) ?? .serif
        self.themeMode = (defaults.string(forKey: Keys.theme)
            .flatMap(ThemeMode.init(rawValue:))) ?? .system
        self.collapseTurns = defaults.object(forKey: Keys.collapseTurns) as? Bool ?? false
        self.experimentalNativeTerminal =
            defaults.object(forKey: Keys.experimentalNativeTerminal) as? Bool ?? false
        // Default flipped to `true` in the upstream-ui-cutover (this PR):
        // ConduitUI is now the production tree. The flag is kept around
        // (rather than being deleted entirely) so an emergency revert
        // is one line — flip the default back to `false` and ship a
        // hotfix. The legacy view tree itself is gone, so flipping the
        // flag without restoring `Sources/Views/` would just render a
        // blank screen; we'll delete the flag in the next PR once the
        // cutover has soaked.
        self.experimentalConduitUI =
            defaults.object(forKey: Keys.experimentalConduitUI) as? Bool ?? true
        let storedBody = defaults.object(forKey: Keys.bodyPointSize) as? Double
        self.bodyPointSize = CGFloat(storedBody ?? Double(Self.defaultBodyPointSize))
            .clamped(to: Self.bodyPointSizeRange)
        let storedGhosttySize = defaults.object(forKey: Keys.ghosttyFontSize) as? Double
        self.ghosttyFontSize = (storedGhosttySize ?? Self.defaultGhosttyFontSize)
            .clamped(to: Self.ghosttyFontSizeRange)
        self.ghosttyTerminalTheme = (defaults.string(forKey: Keys.ghosttyTerminalTheme)
            .flatMap(GhosttyTerminalTheme.init(rawValue:))) ?? .ghosttyDark
        self.neonPalette = (defaults.string(forKey: Keys.neonPalette)
            .flatMap(NeonPaletteChoice.init(rawValue:))) ?? .ice
        self.neonGlow = defaults.object(forKey: Keys.neonGlow) as? Bool ?? true
    }

    /// SwiftUI `.font` value to use for chat body text.
    func bodyFont() -> Font {
        switch fontFamily {
        case .serif:      return .system(.body, design: .serif)
        case .system:     return .system(.body)
        case .monospaced: return .system(.body, design: .monospaced)
        }
    }

    /// Force every active UIWindow to honour the current `themeMode`.
    /// Belt-and-suspenders alongside `.preferredColorScheme` — that
    /// modifier alone was flaky on runtime swaps (light↔dark and back-
    /// to-system would silently no-op when triggered from inside a
    /// sheet). Setting `overrideUserInterfaceStyle` on the window is the
    /// UIKit-native mechanism and propagates to every modally-presented
    /// VC, which is what Settings → Appearance needs.
    ///
    /// Hops to the main actor before touching UIKit. `themeMode.didSet`
    /// can fire from any context (e.g. a Swift Testing task pool that
    /// is not the main thread); without this hop, Main Thread Checker
    /// trips even when the test logic itself is fine, and the test
    /// process exits non-zero despite all assertions passing.
    func applyToWindows() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyToWindowsOnMain() }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyToWindowsOnMain()
            }
        }
    }

    @MainActor
    private func applyToWindowsOnMain() {
        let style: UIUserInterfaceStyle
        switch themeMode {
        case .system: style = .unspecified
        case .light:  style = .light
        case .dark:   style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
