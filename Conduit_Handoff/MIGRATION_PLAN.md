# MIGRATION_PLAN — move the product to the Conduit design

This plan rebrands and re-skins **two surfaces**: the **mobile/tablet app** and the **marketing
website**. Work top-to-bottom; each phase ends in a state you can build/preview.

The design references in `design-reference/` are **HTML/React prototypes** that show the intended
look and behavior. They are **not** the production codebase — recreate their look in the target
app's real environment (React Native / Swift / Kotlin / whatever the app actually uses), reusing
its existing component library, navigation, and state patterns. Lift exact tokens (hex, type,
spacing, radii) from `BRAND.md`, not from memory.

---

## Phase 0 — Inventory & safety (½ day)
1. Branch: `rebrand/conduit`.
2. Run the **Verification grep** in `RENAME_MAP.md` to enumerate every old-brand hit. Save the
   list — it's your checklist.
3. Locate where the app defines: app name/display name, bundle id / applicationId, deep-link
   scheme, app icon set, splash screen, theme/color tokens, font registration, the logo
   component. Note each file path.

## Phase 1 — Identity & tokens (1 day)
1. **Rename** per `RENAME_MAP.md` (strings, symbols, files, bundle ids, scheme). Use
   word-boundary regex; do **not** mass-replace the substring `cat`. Apply the user-facing
   wording from `COPY_DECK.md`.
2. **Color tokens:** create/replace the theme with the table in `BRAND.md §3`. If the app has a
   design-token file, this is the one place hex values live; everything else references tokens.
3. **Fonts:** register `JetBrains Mono` (display/mono) + `Space Grotesk` (body). Map headings →
   mono, body → Space Grotesk per `BRAND.md §4`.
4. **Gradient + glow helpers:** add a cyan→green gradient util and a "glow" shadow util used by
   accents, CTAs, and the mark.

## Phase 2 — The mark & app icon (½ day)

> Native specifics for **iOS and Android** (bundle id, asset catalog / adaptive icon, splash,
> deep-link scheme, OTA/APK install, native string files) are in **`APP_PLATFORMS.md`** — do both
> platforms. All user-facing wording is in **`COPY_DECK.md`**.
1. Drop the raster icons from `assets/` into the platform icon sets:
   - iOS: `AppIcon-1024.png` into the asset catalog (generate required sizes).
   - Android: use `AppIcon-512.png` as the adaptive-icon foreground on the `#04050A` background;
     ship `favicon-*` equivalents only for web.
   - Web/PWA: `favicon-16/32/64.png`, `apple-touch-icon` = `AppIcon-256.png`,
     manifest icons = 512/1024.
2. **In-UI mark:** implement `ConduitMark` (rounded-square daemon, `>` `<` squint eyes, smile,
   cyan→green gradient stroke, top/bottom connector pills) as a vector component. Reference:
   `design-reference/kit.jsx` → `ConduitMark`. Use it in the nav/header and as the tinted avatar
   in session lists (pass a flat agent color to tint).
3. Replace the splash screen with the daemon on `#04050A` + soft center glow.

## Phase 3 — App screens re-skin (2–4 days)
Re-skin each screen to the reference. Screens present in the prototype:

| Screen | Component (reference) | Notes |
|--------|----------------------|-------|
| Home / sessions | `HomeScreen` (`screens.jsx`) | Connected-server card, Active Sessions list with daemon avatars tinted per agent, "New session". Header = `>conduit` wordmark + `ConduitMark`. |
| Live session — Chat | `NeonChatScreen` (`neon-screens.jsx`) | Segmented **Chat / Terminal / Browser** control; progress ring; user bubbles; assistant messages with code + diff cards + pending/approval cards. |
| Live session — Terminal | `TerminalScreen` (`screens2.jsx`) | Streamed stdout, exit codes, esc/tab/arrow accessory bar. |
| Live session — Browser | `BrowserScreen` (`screens2.jsx`) | In-app live preview with a "hot reload" pill. |
| History | `HistoryScreen` (`screens2.jsx`) | Fuzzy-searchable past sessions; rows surface diffs/PRs/tests. |
| Settings | `NeonSettingsScreen` (`palette.jsx`) | Theme/palette/glow toggles; the wordmark/CLI line reads `conduit`. |
| Tablet | `tablet.jsx` / `tablet-sections.jsx` | Same feature set, two-pane layout, left rail uses `ConduitMark`. |

For each: match layout, spacing, radii, the glassy `--panel` cards, hairline `--line` borders,
mono labels, glow on accents. Pull exact values from `BRAND.md`. Keep all interaction behavior
the app already has — this is a visual rebrand, not a behavior change.

## Phase 4 — Website (1 day)
The finished marketing site is in `design-reference/website/` and is essentially ship-ready.
1. Host `website/index.html` + `website/assets/`. It already: uses the Conduit icon + favicons,
   reads **live release data** from `website/version.json`, and offers **iOS over-the-air
   install** + **Android APK download** (no App Store / Play Store, no `brew` line).
2. Wire real distribution:
   - Set `ios.manifestUrl` to your real `itms-services://…/manifest.plist` (must be HTTPS; the
     `.plist` points at your signed `.ipa`).
   - Set `android.apkUrl` to your hosted `.apk` (e.g. `downloads/conduit-latest.apk`).
   - Update `version`, `channel`, `updated`, and sizes in `version.json` each release — the page
     re-reads it; no redeploy needed for copy.
3. **Content note:** the reference still has three feature rows titled **Remote / Voice /
   Generative UI** with placeholder phone images cropped from the *old* app. Replace those three
   images with fresh screenshots of the **rebranded** app (Phase 3). If the shipping app does not
   yet have Voice / Generative UI, retitle those rows to real screens (Terminal, Live Preview
   Browser) so every claim maps to a real screenshot.

## Phase 5 — QA & cutover (½ day)
1. Run the `RENAME_MAP.md` verification grep → **zero** matches in shipped src.
2. Visual pass against `BRAND.md` on phone + tablet + web.
3. Check app icon on a real home screen at small size (the daemon must read clearly).
4. Confirm OTA install (iOS) and APK download (Android) from the live site on real devices.
5. Merge `rebrand/conduit`.

---

### Definition of done
- No "kitty/cat/litter/swe-kitty" anywhere in shipped app, site, repo, or assets.
- App icon, splash, in-UI mark, colors, and fonts all match `BRAND.md`.
- Website live with working OTA + APK install and accurate screenshots.
