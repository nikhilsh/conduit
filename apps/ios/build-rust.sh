#!/usr/bin/env bash
# Build SweKittyCore.xcframework + Swift bindings from core/.
#
# Output (all under apps/ios/SweKittyCore/):
#   SweKittyCore.xcframework            consumed by xcodegen via project.yml
#   Sources/SweKittyCore.swift          UniFFI-generated Swift API
#
# Triple coverage (litter pattern):
#   - aarch64-apple-ios       device       (one slice)
#   - aarch64-apple-ios-sim   sim arm64    \ lipo'd into one slice
#   - x86_64-apple-ios        sim x86_64   /
#
# Layout: `.framework`-flavored xcframework. Each arch slice contains a
# per-arch `swe_kitty_coreFFI.framework/` directory tree:
#
#   <slice>/swe_kitty_coreFFI.framework/
#     swe_kitty_coreFFI            (the static archive, renamed without `lib`)
#     Info.plist                   (minimal CFBundleExecutable=swe_kitty_coreFFI)
#     Headers/swe_kitty_coreFFI.h  (UniFFI-generated C header)
#     Modules/module.modulemap     (`framework module swe_kitty_coreFFI ...`)
#
# Why framework-flavored: the previous `-library + -headers` layout
# made Xcode's `ProcessXCFramework` write its `module.modulemap` to
# `$BUILT_PRODUCTS_DIR/include/module.modulemap`. The Ghostty
# `ghostty-vt.xcframework` is also `-library + -headers`-shaped, so two
# different xcframeworks competed for the same path and the build
# failed with "Multiple commands produce include/module.modulemap"
# (PR #88, PR #89). A framework-flavored xcframework keeps its module
# map inside the per-arch framework's `Modules/` dir — no shared path
# collision, both xcframeworks can be consumed by the same target.
#
# Module name MUST stay `swe_kitty_coreFFI`: the UniFFI-generated Swift
# wrapper hardcodes `import swe_kitty_coreFFI` and relies on its C
# typedefs (RustBuffer, RustCallStatus, ForeignBytes) being in scope.
# A framework's Swift module name is the framework's directory name,
# so the per-arch framework directory is also `swe_kitty_coreFFI.framework`.
# The outer xcframework directory stays `SweKittyCore.xcframework`
# (consumed by project.yml) — only the inner per-arch framework
# matches the import name.
#
# `--legacy` flag: emit the old `-library + -headers` xcframework shape
# (one shared `include/module.modulemap`) for A/B comparison if the new
# framework shape breaks something subtle. Default is the new shape.
set -euo pipefail

LEGACY=0
DEBUG=0
for arg in "$@"; do
  case "$arg" in
    --legacy) LEGACY=1 ;;
    --debug)  DEBUG=1 ;;
    *) echo "build-rust.sh: unknown arg '$arg' (use --legacy or --debug)" >&2; exit 1 ;;
  esac
done
[[ "$DEBUG" -eq 1 ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
OUT_DIR="$SCRIPT_DIR/SweKittyCore"
XCFW="$OUT_DIR/SweKittyCore.xcframework"
BINDINGS_DIR="$OUT_DIR/Sources"

LIB_NAME="libswe_kitty_core.a"
# Module name MUST match the UDL namespace ("swe_kitty_core") + "FFI" suffix:
# the UniFFI-generated Swift wrapper hardcodes `import swe_kitty_coreFFI` and
# relies on its C typedefs (RustBuffer, RustCallStatus, ForeignBytes) being in
# scope. Renaming the module breaks `canImport(swe_kitty_coreFFI)` silently.
MODULE_NAME="swe_kitty_coreFFI"
UDL="$CORE_DIR/src/swe_kitty_core.udl"

PROFILE="${RUST_PROFILE:-release}"
CARGO_PROFILE_FLAG=$([ "$PROFILE" = "release" ] && echo "--release" || echo "")

echo "==> build-rust.sh: profile=$PROFILE core=$CORE_DIR out=$OUT_DIR legacy=$LEGACY"

if [[ ! -f "$CORE_DIR/Cargo.toml" ]]; then
  echo "build-rust.sh: core/Cargo.toml missing" >&2
  exit 1
fi

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)

for t in "${TARGETS[@]}"; do
  echo "==> cargo build --target $t"
  ( cd "$CORE_DIR" && cargo build $CARGO_PROFILE_FLAG --target "$t" --lib )
done

WORK="$OUT_DIR/.build"
rm -rf "$WORK" "$XCFW"
mkdir -p "$WORK/sim" "$WORK/device" "$BINDINGS_DIR"

# Fat simulator slice (arm64 + x86_64).
lipo -create \
  "$CORE_DIR/target/aarch64-apple-ios-sim/$PROFILE/$LIB_NAME" \
  "$CORE_DIR/target/x86_64-apple-ios/$PROFILE/$LIB_NAME" \
  -output "$WORK/sim/$LIB_NAME"

cp "$CORE_DIR/target/aarch64-apple-ios/$PROFILE/$LIB_NAME" "$WORK/device/$LIB_NAME"

# UniFFI Swift bindings: emits swe_kitty_core.swift + swe_kitty_coreFFI.{h,modulemap}.
BINDGEN_OUT="$WORK/bindings"
mkdir -p "$BINDGEN_OUT"
( cd "$CORE_DIR" && cargo run --quiet --bin uniffi-bindgen -- \
    generate "$UDL" \
    --language swift \
    --out-dir "$BINDGEN_OUT" )

# Move the Swift wrapper out (renamed for Xcode niceties; content is unchanged
# so its `import swe_kitty_coreFFI` line still matches the C module below).
mv "$BINDGEN_OUT/swe_kitty_core.swift" "$BINDINGS_DIR/SweKittyCore.swift"

if [[ "$LEGACY" -eq 1 ]]; then
  # ---- Legacy `-library + -headers` shape (PR #88-era). ----
  # Kept behind --legacy so we can A/B against the new framework shape
  # if it breaks something subtle. Note this shape conflicts with
  # ghostty-vt.xcframework at link time ("Multiple commands produce
  # include/module.modulemap") — see header comment.
  HEADERS="$WORK/headers"
  mkdir -p "$HEADERS"
  cp "$BINDGEN_OUT/swe_kitty_coreFFI.h" "$HEADERS/"
  cp "$BINDGEN_OUT/swe_kitty_coreFFI.modulemap" "$HEADERS/module.modulemap"

  xcodebuild -create-xcframework \
    -library "$WORK/device/$LIB_NAME" -headers "$HEADERS" \
    -library "$WORK/sim/$LIB_NAME"    -headers "$HEADERS" \
    -output "$XCFW"

  rm -rf "$WORK"
  echo "==> done (LEGACY -library shape): $XCFW"
  echo "==> bindings: $BINDINGS_DIR/SweKittyCore.swift"
  exit 0
fi

# ---- New `.framework`-flavored shape (default). ----
#
# For each slice, build a per-arch `swe_kitty_coreFFI.framework/`
# directory tree. The framework's binary is the renamed static archive
# (Mach-O `ar` archive — Xcode accepts this as the framework's
# executable just like SPM binaryTargets do).
build_framework_slice() {
  local slice_dir="$1"   # $WORK/device or $WORK/sim
  local lib_path="$slice_dir/$LIB_NAME"
  local fw_dir="$slice_dir/$MODULE_NAME.framework"

  rm -rf "$fw_dir"
  mkdir -p "$fw_dir/Headers" "$fw_dir/Modules"

  # Executable: static archive renamed without the `lib` prefix.
  cp "$lib_path" "$fw_dir/$MODULE_NAME"

  # Headers: UniFFI's generated C header.
  cp "$BINDGEN_OUT/$MODULE_NAME.h" "$fw_dir/Headers/$MODULE_NAME.h"

  # module.modulemap: framework-style, points at the UniFFI header as
  # the umbrella. `export *` keeps RustBuffer / RustCallStatus visible
  # to the generated Swift wrapper's `import swe_kitty_coreFFI`.
  cat > "$fw_dir/Modules/module.modulemap" <<EOF
framework module $MODULE_NAME {
    umbrella header "$MODULE_NAME.h"
    export *
    module * { export * }
}
EOF

  # Minimal Info.plist. CFBundleExecutable must match the binary
  # filename inside the framework dir, otherwise dyld / Xcode's
  # `ProcessXCFramework` rejects the slice.
  cat > "$fw_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$MODULE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>sh.nikhil.swekitty.${MODULE_NAME//_/-}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$MODULE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>17.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
</dict>
</plist>
EOF
}

build_framework_slice "$WORK/device"
build_framework_slice "$WORK/sim"

# Bundle the per-arch frameworks into one xcframework. xcodebuild
# emits an Info.plist at the xcframework root listing each slice's
# `LibraryIdentifier` and `LibraryPath` (== framework dir name).
xcodebuild -create-xcframework \
  -framework "$WORK/device/$MODULE_NAME.framework" \
  -framework "$WORK/sim/$MODULE_NAME.framework" \
  -output "$XCFW"

rm -rf "$WORK"

echo "==> done: $XCFW"
echo "==> bindings: $BINDINGS_DIR/SweKittyCore.swift"
echo "==> layout: per-arch <slice>/$MODULE_NAME.framework/ (framework-flavored)"
