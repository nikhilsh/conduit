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
    func applyToWindows() {
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
