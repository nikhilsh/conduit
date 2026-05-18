# Release Runbook

This is the release path for publishing:

- signed iOS IPA
- signed Android APK
- harness binaries
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

## Release flow

1. Make sure `main` contains the code you want to ship.
2. Create and push a new tag:

```sh
git checkout main
git pull --ff-only
git tag v0.0.X
git push origin main
git push origin v0.0.X
```

3. Watch the three release workflows:

```sh
gh run list --limit 10
gh run watch <release-ios-run-id> --exit-status
gh run watch <release-android-run-id> --exit-status
gh run watch <release-harness-run-id> --exit-status
```

4. Verify the GitHub Release has the expected assets:

- `SweKitty.ipa`
- Android `*.apk`
- harness binaries

Example:

```sh
gh release view v0.0.X -R nikhilsh/swe-kitty --json assets,tagName,url,name
```

5. Rebuild and deploy the website after the release assets are present:

```sh
cd website
npm install
npm run build
cd out
rm -f .deploy.yaml
fyra link swekitty
fyra push
```

Live site:

- `https://swekitty.kaopeh.com`

The website generates:

- a direct IPA download link
- an iOS OTA `manifest.plist`
- an `itms-services` install button
- a direct APK link when the latest release actually contains an APK asset

## Validation checklist

### iOS

- `release-ios` succeeded
- `SweKitty.ipa` exists on the release
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
gh secret list -R nikhilsh/swe-kitty
```

### Website shows no APK button

The latest GitHub Release does not contain an APK asset. Fix the Android release first, then rebuild and push the website again.

### Fyra push fails from `website/out`

Relink the export directory:

```sh
cd website/out
rm -f .deploy.yaml
fyra link swekitty
fyra push
```
