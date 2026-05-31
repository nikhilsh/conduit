#!/usr/bin/env bash
set -euo pipefail

# cut-release.sh — tag-provenance guard for conduit releases.
#
# Why this exists:
#   Releases are tag-triggered (.github/workflows/release.yml). The build runs
#   off whatever commit the tag points at. We once tagged v0.0.35 from a STALE
#   local `main` — the tag captured old code, CI happily shipped it, and a whole
#   on-device test cycle was wasted chasing a "fix" that was never in the build.
#   (The About screen now shows the git SHA so a stale ship is at least visible.)
#
#   This script refuses to create a release tag unless the commit being tagged
#   is exactly origin/main's tip, the working tree is clean, and the tag doesn't
#   already exist. It fetches origin first so the comparison is fresh.
#
# Usage:
#   scripts/cut-release.sh vX.Y.Z
#
# Env:
#   DRY_RUN=1   Run all checks but do NOT create or push the tag (for testing).

usage() {
  echo "usage: scripts/cut-release.sh vX.Y.Z" >&2
  echo "  (set DRY_RUN=1 to validate without tagging)" >&2
}

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "error: missing version argument" >&2
  usage
  exit 2
fi

# Tags must look like vMAJOR.MINOR.PATCH — the release workflow listens on 'v*'.
if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: version '$VERSION' must look like vX.Y.Z" >&2
  exit 2
fi

# Must be inside the repo.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git work tree" >&2
  exit 1
fi

# Refuse if the tag already exists locally...
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "error: tag '$VERSION' already exists locally" >&2
  exit 1
fi

# Refuse on a dirty working tree (uncommitted changes would NOT be in the tag).
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree is dirty — commit or stash before cutting a release" >&2
  git status --short >&2
  exit 1
fi

echo "fetching origin..."
git fetch origin

# ...and refuse if the tag already exists on the remote.
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "error: tag '$VERSION' already exists on origin" >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
MAIN_SHA="$(git rev-parse origin/main)"

# The whole point: the tagged commit must BE origin/main's tip. No stale ships.
if [ "$HEAD_SHA" != "$MAIN_SHA" ]; then
  echo "error: HEAD is not origin/main's tip — refusing to tag a stale commit." >&2
  echo "  HEAD        $HEAD_SHA" >&2
  echo "  origin/main $MAIN_SHA" >&2
  echo "  Fast-forward to origin/main (git switch main && git pull --ff-only) and retry." >&2
  exit 1
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "DRY_RUN=1: all checks passed; would tag $VERSION at $HEAD_SHA and push to origin."
  exit 0
fi

git tag "$VERSION" "$HEAD_SHA"
git push origin "$VERSION"

echo "tagged $VERSION at $HEAD_SHA and pushed to origin."
