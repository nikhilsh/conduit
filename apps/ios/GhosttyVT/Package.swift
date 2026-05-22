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
        //
        // PR #88 history: this binaryTarget was disabled because
        // xcodebuild emitted
        //   "Multiple commands produce
        //    Debug-iphonesimulator/include/module.modulemap"
        // BOTH ghostty-vt.xcframework AND SweKittyCore.xcframework
        // were "-library + -headers"-style xcframeworks (see the old
        // `apps/ios/build-rust.sh`). For that flavor Xcode's
        // ProcessXCFramework extracts the bundled `module.modulemap`
        // to a SHARED, target-agnostic path
        // `$BUILT_PRODUCTS_DIR/include/module.modulemap` — when two
        // such xcframeworks land in the same build their outputs
        // collide and the build system halts. PR #89 documented this
        // diagnosis but left the fix to a follow-up.
        //
        // This PR (swekittycore-framework-rewrap) ships the fix:
        // `apps/ios/build-rust.sh` now packages SweKittyCore as a
        // `.framework`-flavored xcframework — each arch slice contains
        // a per-arch `swe_kitty_coreFFI.framework/` with its module
        // map under `Modules/module.modulemap` (scoped to the
        // framework, no shared path collision). The Ghostty
        // binaryTarget is therefore re-enabled and libghostty actually
        // loads at runtime.
        // GhosttyVtKit binaryTarget RE-DISABLED — upstream's
        // `ghostty-vt.xcframework.zip` only ships an `ios-arm64`
        // slice (real device); no `ios-arm64-simulator` or `x86_64`
        // slice. xcodebuild for the iOS simulator can't link the
        // arm64 device archive against a simulator target host. The
        // fix needs ghostty-org/ghostty to ship a multi-arch
        // xcframework OR us to cross-compile libghostty from source
        // on CI for each target slice (Zig, complex).
        // Track upstream + revisit when a multi-arch tagged release
        // exists. Until then, Stage 2's CoreText renderer paints
        // whatever cells `Terminal.snapshot()` returns (empty grid).
        // .binaryTarget(
        //     name: "GhosttyVtKit",
        //     url: "https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip",
        //     checksum: "0c29329a2e1012d8a6ebf05f164c589aeeaba5d417dd93e075c073ad3fa44ba7"
        // ),
        // Thin Swift wrapper. Re-exports the C symbols through a
        // typed Swift API (Terminal class + TerminalSnapshot struct).
        // The `#if canImport(GhosttyVt)` guard in Terminal.swift +
        // GhosttyTerminalView.swift keeps the iOS app building even
        // if the upstream `tip` asset rotates and SPM resolve fails
        // with a stale-checksum error.
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
