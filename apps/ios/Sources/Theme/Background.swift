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
        // Scope to `.container` (notch / home-indicator), NOT a bare
        // `.ignoresSafeArea()` which also ignores the `.keyboard` region.
        // A bare call here leaked into the foreground layout and suppressed
        // the chat composer's `.safeAreaInset(.bottom)` keyboard avoidance —
        // the recurring "composer hides behind the keyboard on re-tap" bug
        // (device #19/#31). The outer ProjectView scopes its own background
        // the same way; this makes the canvas itself never eat the keyboard
        // band regardless of where it's mounted.
        .ignoresSafeArea(.container, edges: .all)
    }
}
