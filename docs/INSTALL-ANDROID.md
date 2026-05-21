# Installing SweKitty on Android (sideload)

SweKitty Android is distributed as a **signed release APK** on each
GitHub Release. No Play Store; no Internal Testing track.

## Prerequisites

- Android 8.0 (API 26) or later (`apps/android/app/build.gradle.kts`
  sets `minSdk = 26`).
- "Install unknown apps" enabled for the source you'll install from
  (Files app, Chrome, etc.).

## Get the APK

From <https://github.com/nikhilsh/swe-kitty/releases>:

```
SweKitty-vX.Y.Z.apk
```

## Install — direct sideload (recommended)

1. Open the GitHub release on the phone, tap the APK link to download.
2. Tap the downloaded file. Android will prompt "Install unknown app";
   grant the permission to the browser/Files app, then tap *Install*.
3. After install, you may want to **revoke** the "install unknown apps"
   permission you just granted.

## Install — adb

```bash
adb install -r SweKitty-vX.Y.Z.apk
```

`-r` reinstalls over an existing version without losing state.

## First launch

- Launch SweKitty → drawer opens → tap *Settings*.
- Either type the broker endpoint + bearer manually, or tap **Scan QR**.
  Android prompts for camera permission on the first scan; grant it.
- The QR is the one printed when you ran `swe-kitty-broker up`.

State (endpoint + bearer in EncryptedSharedPreferences, scrollback in
ViewModel state) is preserved across upgrades because the application id
`sh.nikhil.swekitty` is stable.

## Troubleshooting

- **"App not installed"** when sideloading — usually a signature
  mismatch with a previously installed copy. Uninstall first, then
  install fresh.
- **Camera permission denied for QR** — *Settings → Apps → SweKitty →
  Permissions → Camera → Allow*.
- **Cleartext traffic blocked** for a `ws://…` endpoint — the app's
  `AndroidManifest.xml` sets `android:usesCleartextTraffic="true"`
  globally for v0.x; if you've side-modified that, restore it.

See also: `docs/SELF-HOST.md` to put the broker behind TLS so you can
use `wss://`.
