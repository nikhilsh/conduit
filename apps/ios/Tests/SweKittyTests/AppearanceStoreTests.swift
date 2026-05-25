import Testing
import Foundation
@testable import SweKitty

/// Defends the theme-switcher fix from PR #11 and the serif-default
/// from PR #15. Catches: persistence round-trips, the new `.serif`
/// being default on fresh installs, and `applyToWindows()` being a
/// no-op when no UIWindowScenes are connected (which is the case in
/// a test process).
@Suite("AppearanceStore")
struct AppearanceStoreTests {

    // MARK: - Persistence round-trip

    @Test func persistsAndRestoresFontFamily() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.fontFamily = .monospaced

        let second = AppearanceStore(defaults: defaults)
        #expect(second.fontFamily == .monospaced)
    }

    @Test func persistsAndRestoresThemeMode() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.themeMode = .dark

        let second = AppearanceStore(defaults: defaults)
        #expect(second.themeMode == .dark)
    }

    @Test func persistsCollapseTurns() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.collapseTurns = true

        let second = AppearanceStore(defaults: defaults)
        #expect(second.collapseTurns == true)
    }

    @Test func persistsExperimentalLitterUI() {
        // Trash-rebuild feature flag for the parallel `LitterUI/` view
        // tree. PR #119 cutover flipped the default to ON — LitterUI
        // is now the only UI; the flag is kept for one cycle as an
        // emergency revert. This test pins persistence: flipping it
        // OFF survives a relaunch.
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        #expect(first.experimentalLitterUI == true)
        first.experimentalLitterUI = false

        let second = AppearanceStore(defaults: defaults)
        #expect(second.experimentalLitterUI == false)
    }

    @Test func persistsExperimentalNativeTerminal() {
        // Stage 0 feature flag for the Ghostty-libghostty rewrite.
        // Persistence is the only behavior we can lock down at this
        // stage — the actual `GhosttyTerminalView` is a placeholder
        // until Stage 1 wires libghostty. See
        // docs/PLAN-TERMINAL-REWRITE.md.
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.experimentalNativeTerminal = true

        let second = AppearanceStore(defaults: defaults)
        #expect(second.experimentalNativeTerminal == true)
    }

    // MARK: - Defaults

    @Test func freshInstallDefaultsToSerif() {
        // The Claude-style refresh (PR #15) moved the default from
        // .monospaced to .serif. If someone "tightens" the init
        // fallback in the future, this test catches the visual
        // regression that would follow.
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.fontFamily == .serif)
    }

    @Test func freshInstallDefaultsToSystemTheme() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.themeMode == .system)
    }

    @Test func freshInstallDoesNotCollapseTurns() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.collapseTurns == false)
    }

    @Test func freshInstallHasExperimentalNativeTerminalOff() {
        // The xterm.js path is still the production renderer; flipping
        // this default to `true` would unconditionally swap it for the
        // Stage 0 placeholder, which is not what we want.
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.experimentalNativeTerminal == false)
    }

    // MARK: - bodyPointSize (PLAN-LITTER-VISUAL-PARITY PR 1)

    @Test func freshInstallBodyPointSizeIsDefault() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.bodyPointSize == AppearanceStore.defaultBodyPointSize)
    }

    @Test func persistsBodyPointSize() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.bodyPointSize = 16

        let second = AppearanceStore(defaults: defaults)
        #expect(second.bodyPointSize == 16)
    }

    @Test func bodyPointSizeClampsAboveRange() {
        let store = AppearanceStore(defaults: freshDefaults())
        store.bodyPointSize = 99
        #expect(store.bodyPointSize == AppearanceStore.bodyPointSizeRange.upperBound)
    }

    @Test func bodyPointSizeClampsBelowRange() {
        let store = AppearanceStore(defaults: freshDefaults())
        store.bodyPointSize = 4
        #expect(store.bodyPointSize == AppearanceStore.bodyPointSizeRange.lowerBound)
    }

    @Test func corruptedBodyPointSizeFallsBackToDefault() {
        // Defaults could carry an out-of-range value from a future
        // build / corrupted plist; hydrate should clamp rather than
        // ship a layout-breaking 200pt body.
        let defaults = freshDefaults()
        defaults.set(99.0, forKey: "swekitty.appearance.bodyPointSize")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.bodyPointSize == AppearanceStore.bodyPointSizeRange.upperBound)
    }

    // MARK: - Ghostty native-terminal font size + theme

    @Test func freshInstallGhosttyFontSizeIsDefault() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.ghosttyFontSize == AppearanceStore.defaultGhosttyFontSize)
    }

    @Test func persistsGhosttyFontSize() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.ghosttyFontSize = 16

        let second = AppearanceStore(defaults: defaults)
        #expect(second.ghosttyFontSize == 16)
    }

    @Test func ghosttyFontSizeClampsAboveRange() {
        let store = AppearanceStore(defaults: freshDefaults())
        store.ghosttyFontSize = 99
        #expect(store.ghosttyFontSize == AppearanceStore.ghosttyFontSizeRange.upperBound)
    }

    @Test func ghosttyFontSizeClampsBelowRange() {
        let store = AppearanceStore(defaults: freshDefaults())
        store.ghosttyFontSize = 1
        #expect(store.ghosttyFontSize == AppearanceStore.ghosttyFontSizeRange.lowerBound)
    }

    @Test func corruptedGhosttyFontSizeFallsBackToClamp() {
        let defaults = freshDefaults()
        defaults.set(999.0, forKey: "swekitty.appearance.ghosttyFontSize")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.ghosttyFontSize == AppearanceStore.ghosttyFontSizeRange.upperBound)
    }

    @Test func freshInstallGhosttyThemeIsGhosttyDark() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.ghosttyTerminalTheme == .ghosttyDark)
    }

    @Test func persistsGhosttyTerminalTheme() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.ghosttyTerminalTheme = .dracula

        let second = AppearanceStore(defaults: defaults)
        #expect(second.ghosttyTerminalTheme == .dracula)
    }

    // MARK: - Backwards-compat for existing installs

    @Test func legacyMonospacedPreferenceSurvives() {
        // Users who picked Monospaced before the serif-default
        // change must continue to see Monospaced after the update.
        let defaults = freshDefaults()
        defaults.set(AppearanceStore.FontFamily.monospaced.rawValue,
                     forKey: "swekitty.appearance.font")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.fontFamily == .monospaced)
    }

    @Test func legacySystemPreferenceSurvives() {
        let defaults = freshDefaults()
        defaults.set(AppearanceStore.FontFamily.system.rawValue,
                     forKey: "swekitty.appearance.font")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.fontFamily == .system)
    }

    // MARK: - ColorScheme mapping

    @Test func systemModeMapsToNilColorScheme() {
        #expect(AppearanceStore.ThemeMode.system.colorScheme == nil)
    }

    @Test func lightAndDarkMapToConcreteSchemes() {
        #expect(AppearanceStore.ThemeMode.light.colorScheme == .light)
        #expect(AppearanceStore.ThemeMode.dark.colorScheme == .dark)
    }

    // MARK: - applyToWindows is a no-op without scenes

    @Test func applyToWindowsWithoutScenesDoesNotCrash() {
        // In a unit-test process there are no connected UIWindowScenes.
        // The fix from PR #11 relies on this being a safe no-op so we
        // can call it from .onAppear at startup before the scene tree
        // is up. If somebody refactors the loop and accidentally force-
        // unwraps a window, this catches it.
        let store = AppearanceStore(defaults: freshDefaults())
        store.themeMode = .dark
        store.applyToWindows()
        // Survival of the function call is the assertion.
        #expect(Bool(true))
    }

    // MARK: - Helpers

    /// A UserDefaults instance scoped to a unique suite name so each
    /// test sees a clean slate and tests don't fight over the global
    /// `.standard` defaults.
    private func freshDefaults() -> UserDefaults {
        let suite = "swekitty.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
