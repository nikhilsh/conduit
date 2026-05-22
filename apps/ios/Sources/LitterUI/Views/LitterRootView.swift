import SwiftUI

// MARK: - LitterRootView
//
// Top-level shell for the LitterUI tree — now the single production
// root after the litter-ui-cutover (this PR deleted the legacy
// `RootView` + its dependents). The compact size class drives
// `LitterUI.HomeView`; the regular size class (iPad / split-view)
// renders the same view — the iPad-specific split-view rebuild is a
// follow-up. Until that lands, iPad gets the iPhone surface
// stretched, which is acceptable while we're not chasing iPad design
// parity.

extension LitterUI {

    struct RootView: View {
        var body: some View {
            ZStack {
                LitterUI.Palette.surface.color
                    .ignoresSafeArea()
                LitterUI.HomeView()
            }
        }
    }
}
