import SwiftUI

// MARK: - ConduitUI namespace
//
// The ConduitUI tree is the upstream-faithful UI rebuild — a parallel view
// surface that runs entirely off the existing `SessionStore` +
// `AppearanceStore` data layer. We accumulated ~30 PRs of drift on the
// legacy `RootView` / `HomeView` and the visual feel had stopped
// resembling upstream; the cleanest path forward was to retire those
// views (kept on disk, but behind `experimentalConduitUI` defaulting
// OFF) and rebuild from scratch.
//
// Naming policy: every type that lives under `apps/ios/Sources/ConduitUI`
// is nested inside this `enum ConduitUI` so we cannot accidentally
// shadow a symbol already in use by the legacy view layer
// (`HomeView`, `ProjectView`, `SettingsSheet`, etc.) — both trees ship
// in the same binary while the flag-flip is staged.
//
// The visual layer here is an original SwiftUI implementation written
// for Conduit; no third-party UI source is carried into this tree.

enum ConduitUI {
    /// Marker so other modules can detect the namespace exists at
    /// compile time (mainly used by tests).
    static let namespaceMarker: String = "ConduitUI"
}
