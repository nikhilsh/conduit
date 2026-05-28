#!/usr/bin/env bash
# Bump helper for the vendored libghostty xcframework.
#
# As of 2026-05-28 the xcframework is VENDORED at
# `apps/ios/GhosttyVT/Vendor/GhosttyKit.xcframework.zip` and consumed
# by SPM via `binaryTarget(path:)`, NOT a URL. xcodebuild does not call
# this script — it exists only to refresh the vendored blob on a bump.
#
# Background: SPM `binaryTarget(url:checksum:)` against
# Lakr233/libghostty-spm's `storage.*` release tags burned three iOS
# releases in 36 hours (2026-05-27/28) when upstream first deleted
# `storage.1.1.5` and then renamed the `GhosttyKit.xcframework.zip`
# asset under `storage.1.2.1` to a URL-encoded blob name. The repo now
# mirrors what every other Swift Ghostty consumer audited does
# (committed binary; see `docs/archive/PLAN-TERMINAL-REWRITE.md:1086`
# for the survey).
#
# Usage:
#   scripts/fetch-ghostty-kit-xcframework.sh bump <storage-tag>
#     e.g. ... bump storage.1.2.3
#     Downloads the asset, prints its sha256, replaces the vendored
#     zip. You then update the sha256 in this file and in
#     apps/ios/GhosttyVT/Package.swift's file header, and commit
#     all three changes together.
#
#   scripts/fetch-ghostty-kit-xcframework.sh verify
#     Re-hashes the vendored zip and asserts it matches the pinned
#     EXPECTED_SHA256 below. Useful in CI / a pre-commit hook to
#     catch accidental rewrites.
#
# Bump cadence: 1-2x/year per upstream Ghostty semver, not per
# Lakr233 cron. Their `storage.<version>` tags are mutable, so we
# treat them as "snapshot at the moment we vendored" not "stable
# pointer".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apps/ios/GhosttyVT/Vendor"
ZIP_PATH="$VENDOR_DIR/GhosttyKit.xcframework.zip"

# Source of truth for the currently-vendored asset. Bump together
# with the file at $ZIP_PATH.
VENDORED_TAG="storage.1.2.2"
EXPECTED_SHA256="7f712b8df5943ba02070c468de7d785abedebf207d3a3ded6515c7467309e902"

MODE="${1:-verify}"

case "$MODE" in
  bump)
    TAG="${2:-}"
    if [[ -z "$TAG" ]]; then
      echo "usage: $0 bump <storage-tag>   e.g. bump storage.1.2.3" >&2
      exit 1
    fi
    URL="https://github.com/Lakr233/libghostty-spm/releases/download/$TAG/GhosttyKit.xcframework.zip"
    TMP="$(mktemp -t ghosttykit.XXXXXX).zip"
    trap 'rm -f "$TMP"' EXIT
    echo "==> fetching $URL"
    if ! curl -fsSL "$URL" -o "$TMP"; then
      echo "  download failed — check that '$TAG' has a release asset" >&2
      echo "  named GhosttyKit.xcframework.zip (some tags do not)." >&2
      exit 2
    fi
    NEW_SHA="$(shasum -a 256 "$TMP" | awk '{print $1}')"
    mkdir -p "$VENDOR_DIR"
    mv "$TMP" "$ZIP_PATH"
    trap - EXIT
    echo "==> wrote $ZIP_PATH"
    echo "    sha256 = $NEW_SHA"
    echo
    echo "Next:"
    echo "  1. Update VENDORED_TAG + EXPECTED_SHA256 in this script."
    echo "  2. Update the sha256 + tag in apps/ios/GhosttyVT/Package.swift's"
    echo "     file-header 'Pin source — VENDORED' block."
    echo "  3. git add the zip + this script + Package.swift, single commit."
    ;;
  verify|*)
    if [[ ! -f "$ZIP_PATH" ]]; then
      echo "fetch-ghostty-kit-xcframework: vendored zip missing at $ZIP_PATH" >&2
      echo "  run: $0 bump $VENDORED_TAG" >&2
      exit 1
    fi
    ACTUAL_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA256" ]]; then
      echo "fetch-ghostty-kit-xcframework: vendored sha256 mismatch" >&2
      echo "  pinned (this script): $EXPECTED_SHA256" >&2
      echo "  actual (on disk):     $ACTUAL_SHA" >&2
      echo "  Either the zip was edited in place, or the pin is stale." >&2
      exit 2
    fi
    echo "==> OK: $ZIP_PATH"
    echo "    tag    = $VENDORED_TAG"
    echo "    sha256 = $ACTUAL_SHA"
    ;;
esac
