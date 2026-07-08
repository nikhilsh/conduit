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
    /// Chat / reading font (handoff §4 "Fonts"). This is the conversation
    /// font, NOT the terminal-native one — the terminal keeps its own
    /// `GhosttyFont`. Each case is a curated **pairing** that names BOTH a
    /// prose face (markdown / what the agent *says*) and a mono face (the
    /// `$` commands, identifiers, exit codes, branch tokens — what the
    /// machine *does*), because Conduit's soul is the mono. All five are
    /// free Google fonts embedded via `project.yml` `UIAppFonts`.
    ///
    /// The pairing applies to CHAT PROSE only — a single switch reflows the
    /// transcript's markdown body + inline code. UI chrome (nav, buttons,
    /// labels, everything `NeonTheme.sans(_:)`/`mono(_:)` render) is
    /// BRAND-LOCKED to the `.terminal` pairing and never follows this
    /// setting, so the app never renders in a serif face.
    ///
    /// The pre-redesign enums (serif/system/monospaced, then
    /// system/spaceGrotesk/ibmPlexSans/newsreader) are migrated on load —
    /// see `decodeFontFamily`.
    enum FontFamily: String, CaseIterable, Identifiable {
        /// Space Grotesk · JetBrains Mono — the shipped baseline. Default.
        case terminal
        /// IBM Plex Sans · IBM Plex Mono — one superfamily, prose+code related.
        case plex
        /// Geist · Geist Mono — clean, modern, developer-native.
        case geist
        /// Newsreader · Spline Sans Mono — serif prose, the calmest voice.
        case editorial
        /// IBM Plex Sans · Spline Sans Mono — warm, rounded mono.
        case soft

        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal:  return "Terminal"
            case .plex:      return "Plex"
            case .geist:     return "Geist"
            case .editorial: return "Editorial"
            case .soft:      return "Soft"
            }
        }

        /// "Prose · Mono" face names — shown beneath the name on the picker card.
        var note: String {
            switch self {
            case .terminal:  return "Space Grotesk · JetBrains Mono"
            case .plex:      return "IBM Plex Sans · IBM Plex Mono"
            case .geist:     return "Geist · Geist Mono"
            case .editorial: return "Newsreader · Spline Sans Mono"
            case .soft:      return "IBM Plex Sans · Spline Sans Mono"
            }
        }

        /// One-line personality blurb (from `imp-fonts.jsx`).
        var blurb: String {
            switch self {
            case .terminal:  return "Sharp, techy, a little futurist. The baseline."
            case .plex:      return "Engineered and neutral. Prose and code feel related."
            case .geist:     return "Clean, modern, developer-native. Disappears behind the work."
            case .editorial: return "Serif prose + humanist mono — the calmest, most Claude-like voice."
            case .soft:      return "Rounded, friendly mono. Reads warm without losing the machine."
            }
        }

        /// Registered CoreText family for the PROSE face, or `nil` when the
        /// pairing's prose is the system face (none currently — every pairing
        /// names a bundled prose face).
        var proseFamilyName: String? {
            switch self {
            case .terminal:  return "Space Grotesk"
            case .plex:      return "IBM Plex Sans"
            case .geist:     return "Geist"
            case .editorial: return "Newsreader"
            case .soft:      return "IBM Plex Sans"
            }
        }

        /// Registered CoreText family for the MONO face, or `nil` to fall
        /// back to the system monospaced face.
        var monoFamilyName: String? {
            switch self {
            case .terminal:  return "JetBrains Mono"
            case .plex:      return "IBM Plex Mono"
            case .geist:     return "Geist Mono"
            case .editorial: return "Spline Sans Mono"
            case .soft:      return "Spline Sans Mono"
            }
        }

        /// Resolve the PROSE `Font` at an explicit point size. Falls back to
        /// the system face when the bundled TTF isn't registered (mirrors
        /// `NeonTheme.sans(_:)`'s defensive probe) so a bad `UIAppFonts` edit
        /// degrades to system rather than silently mis-rendering.
        func proseFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            guard let name = proseFamilyName, FontFamilyAvailability.isProseAvailable(self) else {
                return .system(size: size, weight: weight)
            }
            return .custom(name, fixedSize: size).weight(weight)
        }

        /// Resolve the MONO `Font` at an explicit point size. Falls back to
        /// the system *monospaced* face when the bundled TTF isn't registered.
        func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            guard let name = monoFamilyName, FontFamilyAvailability.isMonoAvailable(self) else {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return .custom(name, fixedSize: size).weight(weight)
        }

        /// Back-compat alias — `font(size:)` resolves the PROSE face. Existing
        /// call sites (markdown body, list rows) expect prose.
        func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            proseFont(size: size, weight: weight)
        }

        /// Resolve the PROSE `Font` against a Dynamic Type text style for the
        /// secondary ramps that scale with the OS text-size setting rather
        /// than the body-size slider.
        func font(textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            guard let name = proseFamilyName, FontFamilyAvailability.isProseAvailable(self) else {
                return .system(textStyle).weight(weight)
            }
            return .custom(name, size: Self.pointSize(for: textStyle), relativeTo: textStyle)
                .weight(weight)
        }

        /// Resolve the MONO `Font` against a Dynamic Type text style.
        func monoFont(textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            guard let name = monoFamilyName, FontFamilyAvailability.isMonoAvailable(self) else {
                return .system(textStyle).weight(weight).monospaced()
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
        // Default is now `.terminal` (Space Grotesk · JetBrains Mono — the
        // shipped baseline / brand identity, leading the picker). Legacy
        // rawValues from before the §4 pairing redesign are migrated rather
        // than reset (see `decodeFontFamily`).
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

    // MARK: - Demo snapshot/restore

    /// A value-type capture of all persisted appearance properties. Used
    /// by the demo mode shell to snapshot on entry and restore on exit so
    /// theme / font changes made by an App Store reviewer do not leak into
    /// the real app after they leave the demo.
    struct Snapshot {
        var fontFamily: FontFamily
        var themeMode: ThemeMode
        var collapseTurns: Bool
        var bodyPointSize: CGFloat
        var neonPalette: NeonPaletteChoice
        var neonGlow: Bool
        var terminalTheme: GhosttyTheme
        var terminalFont: GhosttyFont
    }

    /// Capture the current state as a `Snapshot`.
    func snapshot() -> Snapshot {
        Snapshot(
            fontFamily: fontFamily,
            themeMode: themeMode,
            collapseTurns: collapseTurns,
            bodyPointSize: bodyPointSize,
            neonPalette: neonPalette,
            neonGlow: neonGlow,
            terminalTheme: terminalTheme,
            terminalFont: terminalFont
        )
    }

    /// Restore all persisted properties from a previously captured `Snapshot`.
    /// Each assignment fires the property's `didSet`, which persists to
    /// `UserDefaults` — this is intentional: the pre-demo values are the
    /// real ones that must survive.
    func apply(_ s: Snapshot) {
        fontFamily = s.fontFamily
        themeMode = s.themeMode
        collapseTurns = s.collapseTurns
        bodyPointSize = s.bodyPointSize
        neonPalette = s.neonPalette
        neonGlow = s.neonGlow
        terminalTheme = s.terminalTheme
        terminalFont = s.terminalFont
    }

    /// SwiftUI `.font` value to use for chat body text.
    func bodyFont() -> Font {
        fontFamily.font(textStyle: .body)
    }

    /// Decode the persisted chat-font rawValue, migrating the two prior enum
    /// generations so existing installs don't snap to an unrelated face:
    ///   - The §4 pairing rawValues (`terminal`/`plex`/`geist`/`editorial`/
    ///     `soft`) decode directly.
    ///   - The prior single-face enum (`system`/`spaceGrotesk`/`ibmPlexSans`/
    ///     `newsreader`) maps to the pairing whose PROSE face matches.
    ///   - The original enum (`serif`/`monospaced`) maps by character.
    /// Anything unknown lands on `.terminal` (the default baseline).
    private static func decodeFontFamily(_ raw: String?) -> FontFamily {
        guard let raw else { return .terminal }
        if let family = FontFamily(rawValue: raw) { return family }
        switch raw {
        case "spaceGrotesk": return .terminal   // Space Grotesk prose
        case "ibmPlexSans":  return .plex        // IBM Plex Sans prose
        case "newsreader":   return .editorial   // Newsreader serif prose
        case "serif":        return .editorial   // calmest serif voice
        case "system":       return .terminal    // baseline
        case "monospaced":   return .terminal    // baseline
        default:             return .terminal
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
/// the SAME CoreText family name that `FontFamily.proseFamilyName` /
/// `monoFamilyName` (and hence `.custom(_:size:)`) resolve against — so a
/// registered face is never a false negative, and a dropped `UIAppFonts`
/// entry degrades to the system face instead of silently mis-rendering.
/// Cached statically so the check costs one lookup per launch.
enum FontFamilyAvailability {
    private static func registered(_ family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    /// Prose faces (one probe per distinct family across the five pairings).
    private static let spaceGrotesk = registered("Space Grotesk")
    private static let ibmPlexSans = registered("IBM Plex Sans")
    private static let geist = registered("Geist")
    private static let newsreader = registered("Newsreader")

    /// Mono faces.
    private static let jetBrainsMono = registered("JetBrains Mono")
    private static let ibmPlexMono = registered("IBM Plex Mono")
    private static let geistMono = registered("Geist Mono")
    private static let splineSansMono = registered("Spline Sans Mono")

    /// Whether the pairing's PROSE face is registered.
    static func isProseAvailable(_ family: AppearanceStore.FontFamily) -> Bool {
        switch family {
        case .terminal:  return spaceGrotesk
        case .plex:      return ibmPlexSans
        case .geist:     return geist
        case .editorial: return newsreader
        case .soft:      return ibmPlexSans
        }
    }

    /// Whether the pairing's MONO face is registered.
    static func isMonoAvailable(_ family: AppearanceStore.FontFamily) -> Bool {
        switch family {
        case .terminal:  return jetBrainsMono
        case .plex:      return ibmPlexMono
        case .geist:     return geistMono
        case .editorial: return splineSansMono
        case .soft:      return splineSansMono
        }
    }
}
