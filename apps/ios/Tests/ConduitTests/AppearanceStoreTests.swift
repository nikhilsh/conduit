import Testing
import Foundation
@testable import Conduit

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
        first.fontFamily = .plex

        let second = AppearanceStore(defaults: defaults)
        #expect(second.fontFamily == .plex)
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

    @Test func persistsExperimentalConduitUI() {
        // Trash-rebuild feature flag for the parallel `ConduitUI/` view
        // tree. PR #119 cutover flipped the default to ON — ConduitUI
        // is now the only UI; the flag is kept for one cycle as an
        // emergency revert. This test pins persistence: flipping it
        // OFF survives a relaunch.
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        #expect(first.experimentalConduitUI == true)
        first.experimentalConduitUI = false

        let second = AppearanceStore(defaults: defaults)
        #expect(second.experimentalConduitUI == false)
    }

    // MARK: - Defaults

    @Test func freshInstallDefaultsToTerminal() {
        // The §4 pairing redesign leads the picker with Terminal (Space
        // Grotesk · JetBrains Mono — the shipped baseline / brand identity).
        // If someone "tightens" the init fallback later, this catches the
        // regression.
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.fontFamily == .terminal)
    }

    @Test func freshInstallDefaultsToSystemTheme() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.themeMode == .system)
    }

    @Test func freshInstallDoesNotCollapseTurns() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.collapseTurns == false)
    }

    // MARK: - bodyPointSize (PLAN-CONDUIT-VISUAL-PARITY PR 1)

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

    @Test func persistedBodyPointSizeWinsOverDefaultOnLaunch() {
        // Revert-bug guard (handoff Part A): a stored value DIFFERENT from
        // the default must survive relaunch — the store must not re-seed
        // from `defaultBodyPointSize` on init. Pick a value that is both
        // in-range and not the default so a "re-seed" regression fails here.
        let defaults = freshDefaults()
        let chosen: CGFloat = 13
        #expect(chosen != AppearanceStore.defaultBodyPointSize)
        let first = AppearanceStore(defaults: defaults)
        first.bodyPointSize = chosen

        let second = AppearanceStore(defaults: defaults)
        #expect(second.bodyPointSize == chosen)
    }

    @Test func freshInstallBodyPointSizeIs18() {
        // Handoff Part A bumped the default to 18pt.
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.bodyPointSize == 18)
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
        defaults.set(99.0, forKey: "conduit.appearance.bodyPointSize")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.bodyPointSize == AppearanceStore.bodyPointSizeRange.upperBound)
    }

    // MARK: - Backwards-compat for existing installs

    @Test func legacySerifPreferenceMigratesToEditorial() {
        // Original `serif` → Editorial (Newsreader serif prose, the calmest
        // voice) rather than snapping to the baseline.
        let defaults = freshDefaults()
        defaults.set("serif", forKey: "conduit.appearance.font")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.fontFamily == .editorial)
    }

    @Test func legacyMonospacedPreferenceMigratesToTerminal() {
        // `monospaced` has no prose equivalent, so it lands on the baseline.
        let defaults = freshDefaults()
        defaults.set("monospaced", forKey: "conduit.appearance.font")
        let store = AppearanceStore(defaults: defaults)
        #expect(store.fontFamily == .terminal)
    }

    @Test func priorSingleFacePreferencesMigrateByProse() {
        // The prior single-face enum maps to the pairing whose PROSE face
        // matches: spaceGrotesk→terminal, ibmPlexSans→plex, newsreader→
        // editorial, system→terminal.
        let cases: [(String, AppearanceStore.FontFamily)] = [
            ("spaceGrotesk", .terminal),
            ("ibmPlexSans", .plex),
            ("newsreader", .editorial),
            ("system", .terminal),
        ]
        for (raw, expected) in cases {
            let defaults = freshDefaults()
            defaults.set(raw, forKey: "conduit.appearance.font")
            let store = AppearanceStore(defaults: defaults)
            #expect(store.fontFamily == expected)
        }
    }

    @Test func newChatFontsPersist() {
        for family in AppearanceStore.FontFamily.allCases {
            let defaults = freshDefaults()
            let first = AppearanceStore(defaults: defaults)
            first.fontFamily = family
            let second = AppearanceStore(defaults: defaults)
            #expect(second.fontFamily == family)
        }
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
        let suite = "conduit.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
