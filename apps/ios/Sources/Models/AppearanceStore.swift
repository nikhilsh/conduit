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
        static let font = "swekitty.appearance.font"
        static let theme = "swekitty.appearance.theme"
        static let collapseTurns = "swekitty.appearance.collapseTurns"
        /// Stage 0 feature flag for the Ghostty-libghostty native
        /// terminal path. See docs/PLAN-TERMINAL-REWRITE.md. Defaults
        /// off; xterm.js stays the production renderer until Stage 2.
        static let experimentalNativeTerminal = "swekitty.experimental.nativeTerminal"
        /// Trash-rebuild feature flag for the parallel `LitterUI/` view
        /// tree. When on, `SweKittyApp` renders `LitterUI.RootView`
        /// instead of the current `RootView`. Off by default for this
        /// PR — follow-up PRs flip the default and delete the old
        /// views. See `docs/PLAN-LITTER-UI.md`.
        static let experimentalLitterUI = "swekitty.experimental.litterUI"
    }

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
    /// `LitterUI` view tree rather than the legacy `RootView`. Default
    /// `false`; users opt in via Settings → Experimental → "Litter UI
    /// (preview)". See `apps/ios/Sources/LitterUI/` and
    /// `docs/PLAN-LITTER-UI.md`.
    var experimentalLitterUI: Bool {
        didSet { defaults.set(experimentalLitterUI, forKey: Keys.experimentalLitterUI) }
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
        // Default flipped to `true` in the litter-ui-cutover (this PR):
        // LitterUI is now the production tree. The flag is kept around
        // (rather than being deleted entirely) so an emergency revert
        // is one line — flip the default back to `false` and ship a
        // hotfix. The legacy view tree itself is gone, so flipping the
        // flag without restoring `Sources/Views/` would just render a
        // blank screen; we'll delete the flag in the next PR once the
        // cutover has soaked.
        self.experimentalLitterUI =
            defaults.object(forKey: Keys.experimentalLitterUI) as? Bool ?? true
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
