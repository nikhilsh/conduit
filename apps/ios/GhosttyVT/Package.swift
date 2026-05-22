// swift-tools-version:5.10
//
// Stage 1+2 wrapper package for the prebuilt `ghostty-vt.xcframework`
// release asset published by ghostty-org/ghostty (see
// `scripts/fetch-ghostty-vt-xcframework.sh` and
// `docs/PLAN-TERMINAL-REWRITE.md`).
//
// We host the binaryTarget here rather than referencing it directly
// from xcodegen's `packages:` block because xcodegen accepts SPM
// packages (path + product) but does not expose `binaryTarget` URLs
// directly. Wrapping the binaryTarget in a tiny local SPM package
// gives us the URL+checksum pin we want and a single Swift module
// name (`GhosttyVT`) for the iOS app to import.
//
// The Swift wrapper (`Sources/GhosttyVT/Terminal.swift`) re-exports
// the `GhosttyVt` C module (umbrella header `ghostty/vt.h`) through a
// `#if canImport(GhosttyVt)` guard so the file still compiles if SPM
// fails to resolve the binary asset — the iOS app keeps building
// against the placeholder path even when the framework is missing.
//
// URL + checksum MUST match `scripts/fetch-ghostty-vt-xcframework.sh`
// exactly. Upstream rotates the `tip` asset on every nightly cut, so
// when SPM resolve starts failing with a checksum mismatch, re-pin
// both files together. There is no stable tagged release as of
// 2026-05-22 — only `tip` — so this pin will go stale on the next
// upstream nightly. See `docs/PLAN-TERMINAL-REWRITE.md` Stage 2
// status for the periodic-refresh discipline.
import PackageDescription

let package = Package(
    name: "GhosttyVT",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GhosttyVT", targets: ["GhosttyVT"]),
    ],
    targets: [
        // Stage 2: re-pin the prebuilt `ghostty-vt.xcframework`
        // release asset. The sha256 was captured against the live
        // `tip` asset on 2026-05-22. When the nightly rotates and
        // SPM starts failing with a checksum mismatch, fetch the
        // new asset, recompute its sha256, and bump both this entry
        // and `scripts/fetch-ghostty-vt-xcframework.sh` together.
        //
        // The wrapper code in `Sources/GhosttyVT/Terminal.swift` and
        // the iOS app's `GhosttyTerminalView.swift` both stay
        // `#if canImport(GhosttyVt)`-gated so a stale-checksum
        // resolve failure degrades to the Stage 0 placeholder
        // instead of breaking the iOS build outright.
        // Stage 2 binaryTarget commented out — xcodebuild emits
        //   "Multiple commands produce
        //    Debug-iphonesimulator/include/module.modulemap"
        // because BOTH ghostty-vt.xcframework AND SweKittyCore.xcframework
        // are "-library + -headers" style xcframeworks (see
        // `apps/ios/build-rust.sh`'s `xcodebuild -create-xcframework
        // -library ... -headers ...` invocation). For that flavor Xcode's
        // ProcessXCFramework task extracts the bundled `module.modulemap`
        // to a SHARED, target-agnostic path
        // `$BUILT_PRODUCTS_DIR/include/module.modulemap` — when two
        // such xcframeworks land in the same build their outputs collide
        // and the build system halts. PR #88's diagnostic blamed the
        // SweKittyWidgets extension target; that was wrong. The widget
        // target has no `dependencies:` block at all (project.yml ~L135),
        // so xcodegen never adds GhosttyVT to it. The collision is
        // SweKittyCore <-> ghostty-vt, not host <-> widget. Re-enabling
        // the binaryTarget requires fixing the xcframework packaging,
        // not the project-level link graph. Two options for the next
        // agent:
        //   1. Repackage SweKittyCore.xcframework as a `.framework`-flavored
        //      xcframework (xcodebuild -create-xcframework -framework ...
        //      with a modulemap inside a `Modules/` subdir per arch slice)
        //      so its module map no longer lands at the shared
        //      `include/module.modulemap` path. Touches `build-rust.sh`
        //      and requires the framework bundle to embed
        //      `swe_kitty_coreFFI.h` + a per-framework Info.plist.
        //   2. Wait for upstream Ghostty to ship a framework-flavored
        //      xcframework asset (currently they only publish the
        //      static-lib flavor) and ride option 1 once it lands.
        // Until then leave the binaryTarget commented out; the
        // `#if canImport(GhosttyVt)`-gated wrapper paints the Stage 0
        // placeholder and keeps the iOS build green. sha256 below stays
        // pinned (re-verified against the live `tip` asset on
        // 2026-05-22 — still
        // `0c29329a2e1012d8a6ebf05f164c589aeeaba5d417dd93e075c073ad3fa44ba7`)
        // so option 1 can re-enable with no checksum bump if it lands
        // before the next upstream nightly rotation.
        // .binaryTarget(
        //     name: "GhosttyVtKit",
        //     url: "https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip",
        //     checksum: "0c29329a2e1012d8a6ebf05f164c589aeeaba5d417dd93e075c073ad3fa44ba7"
        // ),
        // Thin Swift wrapper. Re-exports the C symbols through a
        // typed Swift API (Terminal class + TerminalSnapshot struct).
        // Builds clean without GhosttyVtKit because every libghostty
        // touch is gated by `#if canImport(GhosttyVt)`.
        .target(
            name: "GhosttyVT",
            dependencies: [],
            path: "Sources/GhosttyVT"
        ),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            path: "Tests/GhosttyVTTests"
        ),
    ]
)
