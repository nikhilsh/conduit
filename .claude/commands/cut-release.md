---
description: Cut a release tag from fresh origin/main (redeploy broker first if broker/ changed). Encodes the stale-main and version-ldflags footguns.
argument-hint: vX.Y.Z
allowed-tools: Bash
---

Cut release $1. ORCHESTRATOR task. Releases are tag-triggered
(.github/workflows/release.yml) and build off whatever commit the tag points at.

ORDER MATTERS:
1. If this release contains broker/ changes that must be live, /broker-redeploy
   FIRST. Tagging does NOT deploy the broker (a broker fix "released" but never
   serving burned a device cycle — broker-deploy-gap-postmortem).
2. Tag from a FRESHLY-FETCHED origin/main. Use the guard script, which refuses
   to tag anything that isn't origin/main's tip (a stale local main once shipped
   old code as v0.0.35):

   ```bash
   scripts/cut-release.sh $1        # DRY_RUN=1 to validate without tagging
   ```

3. Watch the release workflow. The Android signed-APK job runs FULL lint that PR
   CI (assembleDebug + unit tests) skips — a release-only lint error can fail the
   tag build on a green PR (release-lint-gap). A release-build failure does NOT
   roll back the tag: fix forward + cut the next patch tag.

Version-ldflags note: CI release builds inject
`-ldflags "-X main.version=$TAG"`; a hand-built (box) broker reports version
"dev" because the runbook uses plain `go build`. Harmless until the broker
self-update banner ships; add the ldflag to a hand build if truthful readiness
matters.

After: update docs/ROADMAP.md + memory; confirm the About screen shows the
expected git SHA (catches a stale ship).
