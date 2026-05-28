// swift-tools-version:5.10
//
// Stage 2 unblock — pin Lakr233/libghostty-spm's multi-arch
// `GhosttyKit.xcframework.zip` release asset. The previous pin
// (ghostty-org/ghostty's `tip` `ghostty-vt.xcframework.zip`) was
// disabled in PR #94 because upstream's lib-vt build only ships an
// `ios-arm64/` slice — no `ios-arm64_x86_64-simulator` slice —
// so xcodebuild for the iOS simulator linker fails with
// "building for 'iOS-simulator', but linking in object file built
// for 'iOS'". See `docs/PLAN-TERMINAL-REWRITE.md` →
// "Stage 2 unblock — how others build the xcframework" (PR #96) for
// the full survey of upstream + community options that lead to this
// pick.
//
// Lakr233's pipeline (`.github/workflows/build.yml` in
// libghostty-spm) cross-compiles libghostty for the full
// {ios-arm64, ios-arm64-simulator, ios-x86_64-simulator,
//  macos-arm64, macos-x86_64, ios-arm64-macabi, ios-x86_64-macabi}
// matrix on `macos-15`, stitches with
// `xcodebuild -create-xcframework`, and publishes the zip as
// `storage.<version>` immutable release tags downstream of upstream
// Ghostty semver tags. License: MIT (the SPM wrapper); Ghostty
// itself is MIT.
//
// **API surface bridged (Stage 4, ghostty-bridge-app-surface-v3).**
// The xcframework's module is named `libghostty` (per its umbrella
// modulemap: `framework module libghostty { umbrella header
// "ghostty.h" export * }`) and exposes the full Ghostty `App` /
// `Surface` / `Inspector` C API surface (`ghostty_app_new`,
// `ghostty_surface_new`, `ghostty_surface_write_buffer`, …) — NOT
// the slim VT-only surface the original `Terminal.swift` wrapper
// drove (`ghostty_terminal_new`, `ghostty_terminal_vt_write`,
// `ghostty_terminal_grid_ref`, …; those symbols do NOT exist in
// Lakr233's build). The Stage 4 rewrite at
// `Sources/GhosttyVT/Terminal.swift` now bridges the App/Surface
// shape: `GhosttyApp` singleton over `ghostty_app_t`,
// `GhosttySurface` host-managed viewport over `ghostty_surface_t`
// fed via `ghostty_surface_write_buffer`. The `Terminal` façade
// keeps the public Swift API stable so the iOS CoreText renderer
// in `GhosttyTerminalView.swift` compiles + paints unchanged.
//
// The wrapper gates every `libghostty` symbol behind
// `#if canImport(libghostty)` — the correct module name per the
// umbrella modulemap above. Pre-Stage 4 the guard read
// `canImport(GhosttyVt)` (lowercase `Vt`) and was permanently
// false, which is why `Terminal.isAvailable` reported `false` and
// the experimental terminal flag rendered an empty grid. That
// regression is fixed in this PR.
//
// **Pin source — VENDORED.** The xcframework now lives at
// `Vendor/GhosttyKit.xcframework.zip` in this repo (not a URL).
//   Tag at vendor time:  storage.1.2.2  (Lakr233/libghostty-spm)
//   sha256:              7f712b8df5943ba02070c468de7d785abedebf207d3a3ded6515c7467309e902
//
// Why vendored: storage.* tags on libghostty-spm are mutable —
// `storage.1.1.5` was deleted upstream on 2026-05-27 and
// `storage.1.2.1` had its `GhosttyKit.xcframework.zip` asset renamed
// on 2026-05-28 (canonical URL → 404). Three CI breakages in 36 hours
// burned three iOS releases. SPM `binaryTarget(url:checksum:)` has no
// hedge against publisher mutation, so we mirror what every other
// Swift Ghostty consumer audited (OmniWM, muxy, supacode, kooky, mori,
// devhaven, axel — see `docs/archive/PLAN-TERMINAL-REWRITE.md:1086`)
// does: commit the binary in-tree.
//
// Bump cadence (1-2x/year per upstream Ghostty semver):
//   scripts/fetch-ghostty-kit-xcframework.sh bump <new-storage-tag>
// which downloads the new asset, prints the new sha256, and writes
// `Vendor/GhosttyKit.xcframework.zip`. Then update the sha256 in this
// file and the script. No URL is ever resolved at build time.
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
        // Multi-arch xcframework from Lakr233's libghostty-spm
        // pipeline — see file header for full attribution + the
        // rationale for picking this over upstream's `tip` asset.
        // Slices included (verified by extracting Info.plist of the
        // 2026-05-22 storage.1.1.5 asset):
        //   ios-arm64
        //   ios-arm64_x86_64-simulator
        //   ios-arm64_x86_64-maccatalyst
        //   macos-arm64_x86_64
        // The xcodebuild iOS-simulator linker now finds matching
        // slices (this was PR #94's blocker against upstream's
        // arm64-only `tip` build).
        //
        // 2026-05-28: switched from URL-pinned to vendored. Three
        // breakages in 36h on Lakr233's storage.* tags (1.1.5 deleted,
        // 1.2.1 asset renamed) confirmed the URL-pinned approach isn't
        // viable. Now points at a local zip under `Vendor/` so a
        // network-fetch can never break the iOS build. See file header
        // for bump instructions.
        .binaryTarget(
            name: "libghostty",
            path: "Vendor/GhosttyKit.xcframework.zip"
        ),
        // Thin Swift wrapper. Re-exports the libghostty App/Surface
        // C symbols through a typed Swift API
        // (`GhosttyApp` singleton, `GhosttySurface` host-managed
        // viewport, `Terminal` legacy façade for the iOS CoreText
        // renderer). The Stage 4 PR (ghostty-bridge-app-surface-v3)
        // flipped the wrapper's gate from `canImport(GhosttyVt)`
        // (never true; wrong module name) to `canImport(libghostty)`
        // (matches the xcframework's umbrella modulemap) so
        // `Terminal.isAvailable` finally reports `true` at runtime
        // and the experimental terminal flag actually exercises
        // libghostty's parser instead of rendering an empty grid.
        .target(
            name: "GhosttyVT",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyVT",
            linkerSettings: [
                // libghostty's CoreText/Metal renderer pulls in
                // CoreGraphics + CoreText + Metal + AppKit (macOS)
                // / UIKit (iOS) symbols. Match Lakr233's GhosttyKit
                // target's c++ STL link + add the iOS-side frameworks
                // that libghostty's compiled .o files reference.
                //
                // IOSurface is the Metal renderer's GPU-shared-buffer
                // path (libghostty's GPU surface backs Metal textures
                // with `IOSurfaceCreate` + `kIOSurface*` keys). PR #134
                // shipped the CoreGraphics / CoreText / Metal / c++
                // frameworks but missed IOSurface, so the iOS simulator
                // link still failed with `Undefined symbol:
                // _IOSurfaceCreate` and ~10 sibling symbols. Adding it
                // here closes the last gap from the #129 bridge.
                .linkedLibrary("c++"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            path: "Tests/GhosttyVTTests"
        ),
    ]
)
