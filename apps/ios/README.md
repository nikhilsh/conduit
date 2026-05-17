# apps/ios — scaffold mode

This directory is **placeholder scaffold**, not the iOS shell described in
`docs/PLAN.md` Part B4 / Part D step 6.

Its only purpose is to exercise `.github/workflows/release-ios.yml`
end-to-end (signing, archive, export) so the release pipeline is proven
before the real app lands. The produced IPA is a launch-screen-only
SwiftUI app, ~20 KB.

## Do not

- Tag `v0.0.1` (or any `v*`) until this directory matches PLAN.md step 6:
  - `project.yml` declares the `SweKittyCore.xcframework` dependency
  - `build-rust.sh` actually builds the xcframework from `../../core/`
  - `Sources/` contains `SessionStore.swift` and the `Views/` tree
    (`ProjectListView`, `ProjectView`, `TerminalTab`, `ChatTab`,
    `BrowserTab`) with SwiftTerm wired
- Treat `Sources/ContentView.swift` or `SweKittyApp.swift` as the basis
  for the real app — they will be replaced wholesale.

## When step 6 starts

Rewrite `project.yml`, replace `Sources/`, implement `build-rust.sh`
(see `docs/PLAN.md` Part B6 for the xcframework targets). The workflow
itself should not need changes — it's parameterized by `project.yml`.

See memory `project-ios-release-resume` for ASC artifact IDs and the
"adding a new tester" steady-state loop.
