import SwiftUI

// MARK: - AppearanceColorScheme
//
// View modifier that re-applies `AppearanceStore.themeMode.colorScheme`
// to whatever it's attached to. Plug this onto each sheet's root view
// so a runtime theme swap (Settings → Appearance → Light/Dark) takes
// effect on the sheet currently presenting it.
//
// Why: `.preferredColorScheme(_:)` on the root window is enough for
// the underlying view tree, but a SwiftUI sheet is hosted in its own
// `UIHostingController` whose `traitCollection.userInterfaceStyle` is
// snapshotted when it's presented. Subsequent changes to the parent's
// preferredColorScheme don't always re-propagate into an already-
// presented sheet, so the sheet renders against the stale style — half-
// light, half-dark. `AppearanceStore.applyToWindows()` covers most of
// this (it pokes `overrideUserInterfaceStyle` on every UIWindow), but
// SwiftUI's environment `\.colorScheme` doesn't always re-read off
// that signal on the same RunLoop tick. Re-binding `.preferredColorScheme`
// inside the sheet — sourced from the `@Observable` AppearanceStore —
// forces SwiftUI to re-evaluate when `themeMode` changes.
//
// Usage at every sheet root:
//
//   var body: some View {
//       NavigationStack {
//           …
//       }
//       .appearanceColorScheme()   // <-- here
//   }
//
// The modifier reads `AppearanceStore` from the environment, so the
// presenting parent only has to inject it once (already done at
// `SweKittyApp` root). No-ops gracefully (.colorScheme nil = system)
// when the user is on `.system` mode.

struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(AppearanceStore.self) private var appearance

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.themeMode.colorScheme)
    }
}

extension View {
    /// Re-binds the SwiftUI `\.colorScheme` environment to the current
    /// `AppearanceStore.themeMode`. Apply to every sheet / fullscreen
    /// cover / dialog root that should follow the user's theme override
    /// when it changes mid-presentation.
    func appearanceColorScheme() -> some View {
        modifier(AppearanceColorSchemeModifier())
    }
}
