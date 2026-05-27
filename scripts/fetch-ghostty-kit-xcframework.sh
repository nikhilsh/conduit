#!/usr/bin/env bash
# Fetch Lakr233/libghostty-spm's prebuilt multi-arch
# `GhosttyKit.xcframework.zip` release asset and extract it under
# apps/ios/GhosttyVT/. The Xcode build does NOT consume this directly
# — SPM does, via the `.binaryTarget` in
# apps/ios/GhosttyVT/Package.swift — but the script is kept around so
# the wiring is documented, the checksum is reproducible from
# `curl ... | shasum -a 256`, and CI runners can pre-warm the asset
# during the iOS build setup phase if we ever need to.
#
# Why Lakr233's pin (vs. upstream's `tip`):
# upstream's `ghostty-vt.xcframework.zip` release asset ships only an
# `ios-arm64/` slice — no `ios-arm64_x86_64-simulator/`, so xcodebuild
# linking the iOS simulator target produces
# "building for 'iOS-simulator', but linking in object file built for
# 'iOS'". Lakr233's `libghostty-spm` pipeline cross-compiles libghostty
# for the full {ios-arm64, ios-arm64-simulator, ios-x86_64-simulator,
#  macos-arm64, macos-x86_64, ios-arm64-macabi, ios-x86_64-macabi}
# matrix on `macos-15` and publishes the stitched xcframework as
# immutable `storage.<version>` release tags downstream of upstream
# Ghostty semver tags. License: MIT (wrapper + Ghostty itself). See
# `docs/PLAN-TERMINAL-REWRITE.md` -> "Stage 2 unblock - how others
# build the xcframework" for the full survey + alternative options.
#
# Usage:
#   scripts/fetch-ghostty-kit-xcframework.sh           # fetch + verify
#   scripts/fetch-ghostty-kit-xcframework.sh --check   # verify only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/apps/ios/GhosttyVT"
ZIP_PATH="$OUT_DIR/GhosttyKit.xcframework.zip"
XCFW_PATH="$OUT_DIR/GhosttyKit.xcframework"

# Pin: Lakr233's `storage.1.2.1` release tag. Checksum = sha256 of the
# .zip artifact, verified by `curl -fsSL "$ASSET_URL" | sha256sum` on
# 2026-05-27.
#
# NOTE these `storage.*` tags are NOT immutable — upstream DELETED
# `storage.1.1.5` (asset + tag → 404 on 2026-05-27), which broke every
# iOS build at SPM dependency resolution. So the pin must track whatever
# the publisher currently hosts, not a tag we assume is permanent.
#
# When bumping: pull the new sha from the release notes or
# `https://raw.githubusercontent.com/Lakr233/libghostty-spm/main/Package.swift`
# and update BOTH this script and apps/ios/GhosttyVT/Package.swift in
# the same commit.
ASSET_URL="https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.2.1/GhosttyKit.xcframework.zip"
EXPECTED_SHA256="8333a035ae372ef39f7dff26affaa1f3dac4129a52251aa3264828700b784071"

MODE="${1:-fetch}"

mkdir -p "$OUT_DIR"

case "$MODE" in
  --check|check)
    if [[ ! -f "$ZIP_PATH" ]]; then
      echo "fetch-ghostty-kit-xcframework: zip not present at $ZIP_PATH" >&2
      exit 1
    fi
    ;;
  fetch|*)
    echo "==> fetching $ASSET_URL"
    curl -fsSL "$ASSET_URL" -o "$ZIP_PATH"
    ;;
esac

ACTUAL_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "fetch-ghostty-kit-xcframework: sha256 mismatch" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  echo "  (Lakr233 may have rotated the storage.<version> tag, or the" >&2
  echo "   asset on disk is stale; re-pin against the latest release.)" >&2
  exit 2
fi

if [[ ! -d "$XCFW_PATH" || "$MODE" != "check" ]]; then
  rm -rf "$XCFW_PATH"
  ( cd "$OUT_DIR" && /usr/bin/unzip -q "$ZIP_PATH" )
fi

echo "==> done: $XCFW_PATH"
echo "    sha256(zip) = $ACTUAL_SHA256"
echo
echo "SPM's binaryTarget in apps/ios/GhosttyVT/Package.swift fetches the"
echo "same URL during \`xcodebuild ... -resolvePackageDependencies\`; this"
echo "script exists for documentation + CI pre-warm + manual debugging."
