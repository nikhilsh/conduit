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
// **Pin source** (matches `scripts/fetch-ghostty-kit-xcframework.sh`):
//   URL:      https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.1.5/GhosttyKit.xcframework.zip
//   sha256:   a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405
//   Source:   Lakr233's published `Package.swift` (binaryTarget
//             checksum field) + verified against the live asset by
//             `curl -fsSL <url> | shasum -a 256` on 2026-05-22.
//   Tag:      `storage.1.1.5` (downstream of upstream Ghostty
//             `v1.3.1`, sha 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28).
//
// Bump cadence: Lakr233's pipeline cron is weekly Mondays; pin once
// per upstream Ghostty semver tag, not per upstream cut. If Lakr233
// ever stops publishing, fall back to Option A in §"Stage 2 unblock"
// — copy their build matrix into our own GitHub Actions job.
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
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.1.5/GhosttyKit.xcframework.zip",
            checksum: "a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405"
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
