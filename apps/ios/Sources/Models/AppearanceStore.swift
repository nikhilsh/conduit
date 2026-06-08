import Foundation
import Observation
import SwiftUI
import UIKit
import GhosttyVT

/// User-tunable appearance settings: chat body font, theme override,
/// and turn-collapse preference. Persisted to `UserDefaults.standard`
/// so the choice survives relaunch.
///
/// Lives at app root, injected as an `@Environment` value into any
/// view that needs to honour it (currently `ConversationView` for the
/// monospaced body font, `SettingsSheet`/`AppearanceSheet` for the UI).
@Observable
final class AppearanceStore {
    /// Chat / reading body font (handoff Part A "Chat font"). This is the
    /// conversation font, NOT the terminal-native one — the terminal keeps
    /// its own `GhosttyFont`. The pre-redesign enum was serif/system/mono;
    /// the type-forward redesign replaces it with four curated faces. Old
    /// persisted `serif`/`monospaced` values are migrated on load (see
    /// `decodeFontFamily`).
    enum FontFamily: String, CaseIterable, Identifiable {
        case system
        case spaceGrotesk
        case ibmPlexSans
        case newsreader

        var id: String { rawValue }
        var label: String {
            switch self {
            case .system:       return "System"
            case .spaceGrotesk: return "Space Grotesk"
            case .ibmPlexSans:  return "IBM Plex Sans"
            case .newsreader:   return "Newsreader"
            }
        }

        /// Short qualifier shown beneath the name on the picker card.
        var note: String {
            switch self {
            case .system:       return "native"
            case .spaceGrotesk: return "brand"
            case .ibmPlexSans:  return "humanist"
            case .newsreader:   return "serif · easy read"
            }
        }

        /// Registered CoreText family name for the bundled face, or `nil`
        /// when the family is the system face (resolved via `.system(...)`).
        var customFontName: String? {
            switch self {
            case .system:       return nil
            case .spaceGrotesk: return "Space Grotesk"
            case .ibmPlexSans:  return "IBM Plex Sans"
            case .newsreader:   return "Newsreader"
            }
        }

        /// Resolve a SwiftUI `Font` for this family at an explicit point
        /// size. Custom families fall back to the system face when the
        /// bundled TTF isn't registered (mirrors `NeonTheme.sans(_:)`'s
        /// defensive probe) so a bad `UIAppFonts` edit degrades to system
        /// rather than silently mis-rendering.
        func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            guard let name = customFontName, FontFamilyAvailability.isAvailable(self) else {
                return .system(size: size, weight: weight)
            }
            return .custom(name, fixedSize: size).weight(weight)
        }

        /// Resolve a `Font` against a Dynamic Type text style (caption /
        /// footnote / etc.) for the secondary ramps that scale with the
        /// OS text-size setting rather than the body-size slider.
        func font(textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            guard let name = customFontName, FontFamilyAvailability.isAvailable(self) else {
                return .system(textStyle).weight(weight)
            }
            return .custom(name, size: Self.pointSize(for: textStyle), relativeTo: textStyle)
                .weight(weight)
        }

        /// Nominal point size per text style — used only to seed
        /// `.custom(_:size:relativeTo:)` for the custom faces; the
        /// `relativeTo:` argument keeps it scaling with Dynamic Type.
        private static func pointSize(for style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 34
            case .title:      return 28
            case .title2:     return 22
            case .title3:     return 20
            case .headline:   return 17
            case .body:       return 17
            case .callout:    return 16
            case .subheadline: return 15
            case .footnote:   return 13
            case .caption:    return 12
            case .caption2:   return 11
            @unknown default: return 17
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
        /// Palette choice for the Neon Terminal theme system
        /// (`NeonPaletteChoice` rawValue). Resolved into tokens by
        /// `NeonTheme.resolve(...)` and injected via `\.neonTheme`.
        static let neonPalette = "conduit.appearance.neonPalette"
        /// Glow on/off toggle for the Neon Terminal theme system.
        static let neonGlow = "conduit.appearance.neonGlow"
        /// Color theme rawValue for the native (libghostty) terminal.
        static let terminalTheme = "conduit.appearance.terminalTheme"
        /// Font rawValue for the native (libghostty) terminal.
        static let terminalFont = "conduit.appearance.terminalFont"
    }

    /// Clamp range for [bodyPointSize]. Lower bound keeps captions
    /// readable; upper bound prevents headings from blowing out the
    /// composer / list rows.
    static let bodyPointSizeRange: ClosedRange<CGFloat> = 12...20
    /// New default bumped to **18pt** (handoff Part A): the shipped 14pt
    /// read small on device. 18 sits ~¾ up the 12…20 slider — visible
    /// headroom on either side, not pinned to an end.
    static let defaultBodyPointSize: CGFloat = 18

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

    /// Trash-rebuild flag — when true, the app boots into the parallel
    /// `ConduitUI` view tree rather than the legacy `RootView`. Default
    /// `false`; users opt in via Settings → Experimental → "Conduit UI
    /// (preview)". See `apps/ios/Sources/ConduitUI/` and
    /// `docs/PLAN-CONDUIT-UI.md`.
    var experimentalConduitUI: Bool {
        didSet { defaults.set(experimentalConduitUI, forKey: Keys.experimentalConduitUI) }
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

    /// Color theme for the native (libghostty) terminal. Persisted by rawValue;
    /// applied live by `GhosttyTerminalView` (colors-only config update).
    var terminalTheme: GhosttyTheme {
        didSet { defaults.set(terminalTheme.rawValue, forKey: Keys.terminalTheme) }
    }

    /// Font for the native (libghostty) terminal. Persisted by rawValue; a change
    /// rebuilds the surface (re-rasterizes glyphs) via `GhosttyTerminalView`.
    var terminalFont: GhosttyFont {
        didSet { defaults.set(terminalFont.rawValue, forKey: Keys.terminalFont) }
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
        // Default is now System (matches the redesigned Chat-font strip,
        // which leads with System selected). Legacy `serif`/`monospaced`
        // rawValues from before the redesign are migrated rather than reset.
        self.fontFamily = Self.decodeFontFamily(defaults.string(forKey: Keys.font))
        self.themeMode = (defaults.string(forKey: Keys.theme)
            .flatMap(ThemeMode.init(rawValue:))) ?? .system
        self.collapseTurns = defaults.object(forKey: Keys.collapseTurns) as? Bool ?? false
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
        // Revert-bug fix (handoff Part A): the PERSISTED value must win on
        // launch. We read it back here and only fall back to the default
        // when nothing is stored — we never re-seed from the default on an
        // install that already has a value. (Assigning in `init` does not
        // fire the `didSet` observer, so this read-back is authoritative and
        // isn't immediately overwritten.) The clamp only guards a corrupted
        // / out-of-range stored value; an in-range stored value passes
        // through untouched.
        let storedBody = defaults.object(forKey: Keys.bodyPointSize) as? Double
        self.bodyPointSize = CGFloat(storedBody ?? Double(Self.defaultBodyPointSize))
            .clamped(to: Self.bodyPointSizeRange)
        self.neonPalette = (defaults.string(forKey: Keys.neonPalette)
            .flatMap(NeonPaletteChoice.init(rawValue:))) ?? .ice
        self.neonGlow = defaults.object(forKey: Keys.neonGlow) as? Bool ?? true
        self.terminalTheme = (defaults.string(forKey: Keys.terminalTheme)
            .flatMap(GhosttyTheme.init(rawValue:))) ?? .ghosttyDark
        self.terminalFont = (defaults.string(forKey: Keys.terminalFont)
            .flatMap(GhosttyFont.init(rawValue:))) ?? .jetBrainsMono
    }

    /// SwiftUI `.font` value to use for chat body text.
    func bodyFont() -> Font {
        fontFamily.font(textStyle: .body)
    }

    /// Decode the persisted chat-font rawValue, migrating the pre-redesign
    /// `serif` / `monospaced` values so existing installs don't snap to an
    /// unrelated face. Serif maps to Newsreader (the new easy-read serif);
    /// monospaced has no chat equivalent (mono is terminal-only now) so it
    /// lands on System.
    private static func decodeFontFamily(_ raw: String?) -> FontFamily {
        guard let raw else { return .system }
        if let family = FontFamily(rawValue: raw) { return family }
        switch raw {
        case "serif":      return .newsreader
        case "monospaced": return .system
        default:           return .system
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

/// One-time availability probe for the bundled chat-font faces. Probes by
/// the SAME CoreText family name that `FontFamily.customFontName` (and
/// hence `.custom(_:size:)`) resolves against — so a registered face is
/// never a false negative, and a dropped `UIAppFonts` entry degrades to
/// the system face instead of silently mis-rendering. Cached statically so
/// the check costs one lookup per launch.
enum FontFamilyAvailability {
    private static func registered(_ family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    private static let spaceGrotesk = registered("Space Grotesk")
    private static let ibmPlexSans = registered("IBM Plex Sans")
    private static let newsreader = registered("Newsreader")

    static func isAvailable(_ family: AppearanceStore.FontFamily) -> Bool {
        switch family {
        case .system:       return true
        case .spaceGrotesk: return spaceGrotesk
        case .ibmPlexSans:  return ibmPlexSans
        case .newsreader:   return newsreader
        }
    }
}
