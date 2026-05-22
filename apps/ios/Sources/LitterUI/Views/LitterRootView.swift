import SwiftUI

// MARK: - LitterRootView
//
// Top-level shell for the LitterUI tree. Mirrors `RootView` but uses
// LitterHomeView for the compact size class and the legacy
// `NavigationSplitView` path for regular size class (iPad). The full
// iPad rebuild is deferred (see PR body); the compact / iPhone path
// is the one user-facing focus of this PR.

extension LitterUI {

    struct RootView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ZStack {
                LitterUI.Palette.surface.color
                    .ignoresSafeArea()

                if horizontalSizeClass == .compact {
                    LitterUI.HomeView()
                } else {
                    // iPad: keep the legacy split-view for now. The
                    // LitterUI rebuild prioritizes the iPhone surface;
                    // the iPad path falls back to the legacy view tree
                    // until the litter-faithful split is built. (Users
                    // who flip the flag on iPad still see the new
                    // visual language for the compact size class
                    // when run in slide-over / split-view.)
                    SweKitty_LegacyRoot()
                }
            }
        }
    }
}

/// Thin wrapper around the legacy `RootView` so the LitterUI namespace
/// can compose it without shadowing.
private struct SweKitty_LegacyRoot: View {
    var body: some View {
        // This is the legacy non-LitterUI tree. We intentionally call
        // it here for the iPad fallback only; the compact-class path
        // uses pure LitterUI views.
        RootView()
    }
}
