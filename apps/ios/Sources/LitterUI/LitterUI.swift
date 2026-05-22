import SwiftUI

// MARK: - LitterUI namespace
//
// The LitterUI tree is the litter-faithful UI rebuild — a parallel view
// surface that runs entirely off the existing `SessionStore` +
// `AppearanceStore` data layer. We accumulated ~30 PRs of drift on the
// legacy `RootView` / `HomeView` and the visual feel had stopped
// resembling litter; the cleanest path forward was to retire those
// views (kept on disk, but behind `experimentalLitterUI` defaulting
// OFF) and rebuild from scratch.
//
// Naming policy: every type that lives under `apps/ios/Sources/LitterUI`
// is nested inside this `enum LitterUI` so we cannot accidentally
// shadow a symbol already in use by the legacy view layer
// (`HomeView`, `ProjectView`, `SettingsSheet`, etc.) — both trees ship
// in the same binary while the flag-flip is staged.
//
// License posture: litter (`https://github.com/dnakov/litter`) is
// GPLv3 with an App Store additional permission (LICENSE checked
// 2026-05-22 via `gh api repos/dnakov/litter/contents/LICENSE`).
// Because SweKitty is not GPLv3, we cannot copy litter source into
// this tree. Every visual decision below is a clean-room
// reimplementation: we studied litter's structural layout (Views,
// Models/LitterPalette, Extensions glass modifiers) via the
// `dnakov/litter` GitHub API + raw.githubusercontent.com source
// reads, then wrote our own SwiftUI. File-level headers document
// the litter file each new view structurally mirrors.

enum LitterUI {
    /// Marker so other modules can detect the namespace exists at
    /// compile time (mainly used by tests).
    static let namespaceMarker: String = "LitterUI"
}
