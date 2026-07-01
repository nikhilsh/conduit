---
description: Cut a release tag from fresh origin/main (redeploy broker first if broker/ changed). Encodes the stale-main and version-ldflags footguns.
argument-hint: vX.Y.Z
allowed-tools: Bash
---

Cut release $1. ORCHESTRATOR task. Releases are tag-triggered
(.github/workflows/release.yml) and build off whatever commit the tag points at.

Before anything else: `git fetch origin` so your local refs are current.
The guard script (`scripts/cut-release.sh`) enforces this, but explicit
fetch first avoids a stale-main footgun (bit us once — v0.0.35).

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
`-ldflags "-X main.version=$TAG"`; the manual redeploy runbook (docs/BROKER-REDEPLOY.md)
and /broker-redeploy skill now also inject the ldflag via
`-ldflags "-X main.version=$(git -C $TMP describe --tags --always)"` so
/api/capabilities reports the real tag (or short SHA) instead of "dev".

After: update pipeline docs. In VERIFY-CHECKLIST.md, this is where the version
is finally stamped: rename the single **Next release (pending)** heading to `$1`
(everything accumulated under it is exactly what ships in this tag) and add a
fresh empty **Next release (pending)** section above it for the next round. Do
NOT create version headings anywhere else — merges only ever land under the
pending section (that phantom-version drift, v0.0.205–211 with only 204 live, is
what this prevents). Update memory; confirm the About screen shows the
expected git SHA (catches a stale ship). Any worktrees whose PRs shipped in
this release should be cleaned up now if not already:
`git worktree remove --force <path>`, `git branch -D <branch>`,
`git worktree prune`.
