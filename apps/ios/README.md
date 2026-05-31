# apps/ios — Conduit iOS app

Native SwiftUI shell for the conduit harness. Implements the v0.1 surface
from `docs/PLAN.md` Part B4 / Part D step 6: project switcher + per-project
multi-view (Terminal wired; Chat / Browser stubbed for task 007).

## Layout

```
apps/ios/
├── project.yml                 xcodegen spec — generates Conduit.xcodeproj
├── build-rust.sh               builds ConduitCore.xcframework from ../../core/
├── Sources/
│   ├── ConduitApp.swift       @main
│   ├── SessionStore.swift      @Observable wrapper around ConduitClient
│   ├── Info.plist
│   └── Views/
│       ├── RootView.swift
│       ├── SettingsSheet.swift     manual endpoint+token entry (task 009 → QR)
│       ├── ProjectListView.swift   sidebar / project switcher
│       ├── ProjectView.swift       segmented picker, agent badge
│       ├── TerminalTab.swift       SwiftTerm-backed
│       ├── ChatTab.swift           stub
│       └── BrowserTab.swift        stub
└── ConduitCore/               populated by build-rust.sh (gitignored)
    ├── ConduitCore.xcframework
    └── Sources/ConduitCore.swift
```

## Build & run

Requires Xcode 16+, Rust with iOS targets, `xcodegen`.

```bash
# from repo root
make ios               # ./build-rust.sh + xcodegen generate
open apps/ios/Conduit.xcodeproj
# Run on iPhone 16 simulator → Settings sheet → enter ws://<host>:1977 + bearer
```

## CI

`.github/workflows/ci.yml` `ios sim build` runs the same `build-rust.sh` +
`xcodegen generate` + `xcodebuild build` against `iPhone 16` on `macos-15`,
no signing.

## Release

Tag `v*` to trigger `.github/workflows/release-ios.yml` — produces an ad-hoc
signed IPA on a GitHub Release. See `docs/RELEASE-IOS.md` for ASC setup.
