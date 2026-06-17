---
title: Release gotchas — lint gap, broker deploy gap, website deploy
tags: [release, android, lint, broker, website, CI]
scope: repo
source: release-lint-gap, broker-deploy-gap-postmortem, website-deploy-and-broker-page
status: active
---

# Release gotchas

## Android release runs lint that PR CI does not

PR CI (`.github/workflows/ci.yml`) runs `assembleDebug` and
`testDebugUnitTest`. It does NOT run lint. The signed-APK release workflow
(`.github/workflows/release-android.yml`) DOES run the full lint. Release-only
lint errors slip past green PRs.

**How it bit us (v0.0.132):** `MainActivity.kt` triggered
`InvalidFragmentVersionForActivityResult` (introduced by adding
`registerForActivityResult` for push permission). Every PR CI passed;
the tag build failed. The tag was not rolled back — fix forward and cut the
next patch.

**How to apply:**
- When a PR adds Android APIs that lint scrutinizes (activity-result,
  permissions, fragments), assume the release lint may catch what PR CI misses.
- Fix pattern: pin the transitively-resolved dep version explicitly, or add a
  targeted `@SuppressLint` for genuine false-positives (Compose-only app with
  no `FragmentActivity`). Never use blanket `abortOnError false`.
- A release build failure does NOT roll back the tag — fix forward and cut
  the next patch.

**Candidate improvement:** add a lint step to PR CI (`./gradlew lint`) so this
is caught pre-merge.

## A tagged release does NOT deploy the broker

Tagging a release triggers the app build and store upload. It does NOT restart
the live broker on the box. Broker fixes that ship in a release are not live
until you follow `docs/BROKER-REDEPLOY.md`.

**How it bit us (v0.0.113–v0.0.116):** broker-side fixes were merged across four
releases but the box kept serving the old binary for hours. The visible symptom
was "fixes didn't work" reports.

**Rule:** any release that includes `broker/` changes requires an explicit
redeploy. Make broker redeploy a release-ritual gate. See
[BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md) and `docs/BROKER-REDEPLOY.md`.

**Broker version in readiness:** the broker runbook builds with plain `go build`,
which reports `"dev"` for `readiness.broker_version`. Add
`-ldflags "-X main.version=$(git describe --tags)"` to the build step if you
need the version to report truthfully (relevant once the broker self-update
banner ships).

## Relay must deploy before a broker that emits new push categories

See [BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md) — relay deploy order.

## Deploying the website without cutting a release

The marketing site (`website/`) deploys to Fyra at `conduit.kaopeh.com`.
The Fyra secrets live only in GitHub Actions — you cannot `fyra push` from the
dev box.

**Standalone deploy:** `gh workflow run website-deploy.yml --ref main`
(workflow added to `.github/workflows/website-deploy.yml`). Optional input
`broker_password` overrides the default password for the gated `/broker` page.

**Gated /broker page:** `website/broker.template.html` is AES-GCM encrypted by
`build.mjs buildGatedPage()` (PBKDF2 SHA-256, 200k iterations, 16B salt, 12B
IV). The plaintext never ships; the browser decrypts in-page. Default password
is `nikhil123` (or env `BROKER_PAGE_PASSWORD`). To update content: edit
`broker.template.html` and re-run the deploy workflow.
