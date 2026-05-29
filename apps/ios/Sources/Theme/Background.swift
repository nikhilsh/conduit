import SwiftUI

/// App-wide background sitting behind the navigation stack. Paints the
/// resolved Neon Terminal canvas — `neon.appBg` (the radial gradient that
/// approximates the CSS `radial-gradient` stops) with a faint `NeonGrid`
/// overlay. Type name preserved so existing call sites in `RootView` keep
/// working.
struct GlassAppBackground: View {
    @Environment(\.neonTheme) private var neon

    var body: some View {
        ZStack {
            neon.appBg
            NeonGrid()
        }
        .ignoresSafeArea()
    }
}
