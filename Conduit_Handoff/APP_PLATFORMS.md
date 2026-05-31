# APP_PLATFORMS — iOS & Android migration detail

This is the platform-specific companion to `MIGRATION_PLAN.md`. It covers exactly what changes on
**iOS** and **Android** to move the app from "SWE Kitty" to **Conduit**. Conduit ships
**outside the App Store / Play Store** — iOS via over-the-air (OTA) enterprise/ad-hoc install,
Android via a directly-downloaded APK. Keep that model.

Apply `RENAME_MAP.md` everywhere; the items below are the platform touch-points that are easy to
miss.

---

## A. Shared (both platforms)
| Thing | Old → New |
|-------|-----------|
| Display name (home-screen label) | `SWE Kitty` → `Conduit` |
| Internal product/codename | `swe-kitty` / `KittyLitter` → `conduit` |
| App icon | cat-basket `icon-192.png` → `assets/AppIcon-*.png` (the daemon) |
| Splash / launch screen | cat mark → daemon on `#04050A` + soft center glow |
| Accent / theme colors | → `BRAND.md §3` tokens (cyan `#22D3EE`, green `#3EF0A0`) |
| Fonts | → JetBrains Mono (display/mono) + Space Grotesk (body) |
| Deep-link scheme | `swekitty://` → `conduit://` |
| In-app logo component | `CatMark` → `ConduitMark` (daemon vector) |

---

## B. iOS

### Identity
- **Bundle Display Name** (`CFBundleDisplayName` in `Info.plist`): `Conduit`.
- **Bundle Name** (`CFBundleName`): `Conduit`.
- **Bundle Identifier**: change `com.<org>.swekitty` → `com.<org>.conduit`. Update the matching
  App ID / provisioning profile (ad-hoc or enterprise) so OTA signing still resolves.
- **URL scheme** (`CFBundleURLTypes`): `swekitty` → `conduit`. Update any Universal Links
  `applinks:` entries + the `apple-app-site-association` file on the marketing domain.

### Icon & launch
- Replace the **App Icon asset catalog** (`AppIcon.appiconset`) using `assets/AppIcon-1024.png`
  as the 1024 marketing icon and generate the device sizes. iOS masks to a squircle — the daemon
  is already centered with margin, so it crops cleanly.
- Replace the **Launch Screen** (storyboard or SwiftUI splash): daemon mark centered on `#04050A`
  with a faint top-center cyan glow. No text.

### OTA distribution (no App Store)
- Keep the **`manifest.plist`** (itms-services) flow. After re-signing under the new bundle id,
  regenerate the `.ipa` and the `manifest.plist` so its `bundle-identifier` and `title` read
  `com.<org>.conduit` / `Conduit`.
- The website's install button points at
  `itms-services://?action=download-manifest&url=https://<domain>/ios/manifest.plist` — host the
  new `manifest.plist` + `.ipa` there and set the URL in `website/version.json` → `ios.manifestUrl`.
- Verify the **install prompt** on a real device shows `Conduit` (not the old name) and trusts via
  Settings › General › VPN & Device Management.

### Strings
- `Localizable.strings` / SwiftUI string catalogs: replace every user-facing `SWE Kitty`/`kitty`
  per `COPY_DECK.md`. Watch notification copy, Settings rows, onboarding, and the share sheet.

---

## C. Android

### Identity
- **`applicationId`** (`build.gradle`): `com.<org>.swekitty` → `com.<org>.conduit`. (Changing this
  makes it a distinct install — fine for a store-less beta; document it for existing testers.)
- **App label** (`android:label` in `AndroidManifest.xml` + `strings.xml` `app_name`): `Conduit`.
- **Intent filters / deep links**: scheme `swekitty` → `conduit`; update any `<data android:host>`
  App Links + the `assetlinks.json` on the marketing domain.

### Icon & splash
- Replace the **adaptive icon**: foreground = the daemon (use `AppIcon-512.png`, trimmed to the
  foreground safe zone), background = solid `#04050A`. Regenerate `mipmap-*` densities and the
  monochrome/themed-icon layer.
- Replace the **legacy `ic_launcher`** PNGs for old devices.
- **Splash** (Android 12+ `SplashScreen` API): `windowSplashScreenBackground` = `#04050A`,
  `windowSplashScreenAnimatedIcon` = the daemon mark.

### APK distribution (no Play Store)
- Build the **release APK** signed with your distribution keystore (keep the same keystore if you
  want in-place updates for testers; a new `applicationId` is a fresh install regardless).
- Host it and point `website/version.json` → `android.apkUrl` at it
  (e.g. `downloads/conduit-latest.apk`). The site serves it as a direct download; users enable
  "install from this source."
- Bump `versionCode` / `versionName` each build; surface `versionName` in `version.json`.

### Strings
- `res/values/strings.xml` (+ any locale variants): replace every user-facing `SWE Kitty`/`kitty`
  per `COPY_DECK.md`. Check notification channels' names, shortcuts (`shortcuts.xml`), and the
  app description used by your distribution page.

---

## D. Per-platform QA checklist
- [ ] Home-screen label reads **Conduit** on both platforms.
- [ ] App icon is the daemon, legible at the smallest launcher size.
- [ ] Splash shows the daemon on `#04050A`, no old mark, no old name.
- [ ] Deep link `conduit://…` opens the app; old `swekitty://` is gone.
- [ ] iOS OTA install prompt + Android APK install both show **Conduit** and succeed on a real device.
- [ ] `RENAME_MAP.md` verification grep is clean in the native projects too (Info.plist,
      gradle, manifests, .strings, .xml).
