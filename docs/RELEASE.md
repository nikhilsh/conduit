# Release Runbook

This is the release path for publishing:

- signed iOS IPA
- signed Android APK
- broker binaries
- updated static website on Fyra

The website reads the latest GitHub Release at build time, so the release assets must exist before the Fyra deploy.

## Preconditions

GitHub repo secrets must be configured.

### iOS secrets

- `IOS_CERTIFICATE_P12_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_KEYCHAIN_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `IOS_TEAM_ID`

### Android secrets

For test-only Android releases, no secrets are required.

The workflow now falls back to generating an ephemeral test keystore in CI and produces an installable APK suitable for direct download and local testing.

Optional secrets for a persistent Android signing key:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Use those only if you want builds to stay signed with the same key across releases, which allows upgrade-in-place instead of uninstall/reinstall.

### Website deploy secrets

Required for automated website deploy after a successful tagged release:

- `FYRA_TOKEN`

Optional:

- `FYRA_SERVER`

If omitted, the deploy workflow uses the default `server.fyra.sh:50051`.

## Cutting a release

**Always cut tags from a freshly-fetched `origin/main`.** The release workflow
builds whatever commit the tag points at. We once tagged `v0.0.35` from a stale
local `main` — the tag captured old code, CI shipped it, and an on-device test
cycle was wasted. (The About screen now shows the git SHA so a stale ship is at
least visible.)

Use the guard script — it fetches origin, refuses to tag if `HEAD` isn't
`origin/main`'s tip, refuses on a dirty tree or an existing tag, then tags and
pushes:

```sh
scripts/cut-release.sh v0.0.X
```

Set `DRY_RUN=1` to validate without tagging. Only fall back to the manual
`git tag` / `git push` dance below if the script is unavailable — and even then,
verify `git rev-parse HEAD` equals `git rev-parse origin/main` first.

As a server-side backstop, the `prepare` job in `release.yml` also fails fast on
a tag push if the tagged commit isn't contained in `origin/main` — so a
hand-tagged stale commit can't slip through CI either.

## Release flow

1. Make sure `main` contains the code you want to ship.
2. Create and push a new tag (prefer `scripts/cut-release.sh v0.0.X`, see above):

```sh
git checkout main
git pull --ff-only
git tag v0.0.X
git push origin main
git push origin v0.0.X
```

3. The tag triggers a single workflow, `release.yml`, which orchestrates everything as one DAG:

```
prepare ──┬── ios ─────┐
          ├── android ─┼── deploy-website (Fyra)
          └── broker ─┘
```

- `prepare` resolves the tag and ensures the GitHub Release exists
- `ios`, `android`, `broker` are reusable workflows (`./.github/workflows/release-*.yml`) called in parallel via `workflow_call`
- `deploy-website` verifies all required assets are present and then pushes the static site to Fyra

Manual release without a git tag (e.g. to ship `main` HEAD):

```sh
gh workflow run release.yml -f release_tag=manual-$(date -u +%Y-%m-%d)
gh run watch --exit-status   # picks the latest run automatically
```

Or watch a specific run:

```sh
gh run list --workflow release --limit 5
gh run watch <run-id> --exit-status
```

4. Verify the GitHub Release has the expected assets:

- `Conduit.ipa`
- Android `*.apk`
- broker binaries

Example:

```sh
gh release view v0.0.X -R nikhilsh/conduit --json assets,tagName,url,name
```

5. The website deploy is automatic after successful tagged releases.

Manual fallback if `deploy-website` fails after release assets are already present:

```sh
cd website
npm install
npm run build
cd out
rm -f .deploy.yaml
fyra link conduit
fyra push
```

Live site:

- `https://conduit.kaopeh.com`

The website generates:

- a direct IPA download link
- an iOS OTA `manifest.plist`
- an `itms-services` install button
- a direct APK link when the latest release actually contains an APK asset

## Validation checklist

### iOS

- `release-ios` succeeded
- `Conduit.ipa` exists on the release
- OTA install works from Safari on an enrolled device
- direct IPA link downloads correctly

### Android

- `release-android` succeeded
- APK exists on the release
- APK downloads from the website correctly
- APK installs on a test device
- If CI used the ephemeral test keystore, expect reinstall behavior between releases instead of seamless upgrades

### Website

- landing page loads
- current release tag is correct
- `Install on iPhone or iPad` opens OTA install flow
- `Download IPA` works
- `Download APK` appears only when the latest release has an APK

## Failure modes

### Android release fails during signing

If you are using repo-provided Android secrets, confirm the four secret names exist and are valid:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Check with:

```sh
gh secret list -R nikhilsh/conduit
```

### Website shows no APK button

The latest GitHub Release used by the site does not yet contain an APK asset. Re-run the failed `android` job from the `release` workflow, or rebuild the site manually.

### `deploy-website` job fails

Check:

- `FYRA_TOKEN` exists in repo secrets
- The `ios`, `android`, and `broker` jobs in the same `release` run all succeeded
- The GitHub Release has:
  - `Conduit.ipa`
  - `app-release.apk`
  - the four broker binaries (`conduit-broker-{linux,darwin}-{amd64,arm64}`)

To re-run just the website deploy without rebuilding the apps, use "Re-run failed jobs" on the `release` workflow run — `prepare`, `ios`, `android`, `broker` are skipped if green and only `deploy-website` re-runs.

### Fyra push fails from `website/out`

Relink the export directory:

```sh
cd website/out
rm -f .deploy.yaml
fyra link conduit
fyra push
```
