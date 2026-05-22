// swift-tools-version:5.10
//
// Stage 1 wrapper package for the prebuilt `ghostty-vt.xcframework`
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
// exactly. When upstream rotates the `tip` asset, re-pin both files
// together.
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
        // Prebuilt static library + headers from the Ghostty `tip`
        // release. Module name baked into the modulemap is
        // `GhosttyVt` (lowercase t) — that's what `canImport` checks
        // against in Sources/GhosttyVT/Terminal.swift.
        .binaryTarget(
            name: "GhosttyVtKit",
            url: "https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip",
            checksum: "679ef4c585d4d9bfd27fd2f1c93494e783cf756678976bf2ab5995f6521c3544"
        ),
        // Thin Swift wrapper. Re-exports the C symbols through a
        // typed Swift API (Terminal class + TerminalSnapshot struct).
        .target(
            name: "GhosttyVT",
            dependencies: ["GhosttyVtKit"],
            path: "Sources/GhosttyVT"
        ),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            path: "Tests/GhosttyVTTests"
        ),
    ]
)
