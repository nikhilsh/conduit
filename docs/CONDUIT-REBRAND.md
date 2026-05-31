# Conduit Rebrand — Migration Plan

Rename the app from **swe-kitty** to **Conduit**, removing every reference to
"swe" and "kitty" across all four components (Rust core, Go broker, iOS,
Android) plus repo/infra. Decided **2026-05-31**.

## Locked decisions

| Decision | Choice |
|---|---|
| Depth | **Full rename** — display names, UI copy, docs, code identifiers, bundle IDs, module/crate paths, protocol identifiers |
| Bundle ID / Android applicationId | `sh.nikhil.swekitty` → **`sh.nikhil.conduit`** |
| GitHub repo + Go module | `nikhilsh/swe-kitty` → **`nikhilsh/conduit`**; module `github.com/nikhilsh/swe-kitty/broker` → `github.com/nikhilsh/conduit/broker` |
| Product display name | **Conduit** |
| Scope | App (iOS + Android), Rust core, Go broker, **and the website** (`website/`, deployed to swekitty.kaopeh.com) — full end-to-end migration |
| Execution | **Phase-by-phase, looped until done.** Each phase is its own commit/PR with its CI gate green before the next. |
| Visual design / assets | **Pending handoff** — see "New Conduit design" below. |

## New Conduit design — handoff integrated (SOURCE OF TRUTH)

The **`Conduit_Handoff/`** bundle is committed at repo root and is the source of
truth: `BRAND.md` (tokens/type/mark/voice), `RENAME_MAP.md` (find/replace + the
verification grep = **definition of done**), `MIGRATION_PLAN.md`, `APP_PLATFORMS.md`,
`COPY_DECK.md`, `CLAUDE_CODE_PROMPT.md`, `assets/` (final icons), `design-reference/`
(HTML/React prototypes + a near-ship-ready `website/`).

**Key reconciliation (what we have vs the design):**
- ✅ **Palette already matches.** Shipped `NeonTheme.swift`/`NeonTheme.kt` use the
  exact BRAND hex (`#22D3EE`/`#3EF0A0`/`#04050A`/`#0A1120`/`#EAF3FF`/`#FF9D4D`/`#FF7847`)
  and already target JetBrains Mono + Space Grotesk (system fallback today). The
  Neon work ([[project_neon_ui_rework]]) **is** the Conduit color system — not replaced.
- 🔴 **Bigger rename than first scoped.** Handoff requires erasing the *whole*
  cat-mascot codename, not just `swe-kitty`: `kitty`/`Kitty`/`litter`/`Litter`/
  `KittyLitter`/`kitten`/`paw`/`CatMark` (whole-word; never blind-replace `cat`).
  This repo is built on a **`LitterUI`** iOS module (~523 refs, ~50 `Litter*` types,
  its own dir) + Android `Litter*` (~108 refs) → must become `ConduitUI`/`Conduit*`.
- 🔴 **New mark + icons.** Replace `AnimatedBrandMark`/app icon with the **terminal
  daemon**: in-UI vector `ConduitMark` (rounded square, `>` `<` squint eyes, smile,
  cyan→green stroke, connector pills — ref `design-reference/kit.jsx`) + wire the
  provided `assets/AppIcon-*.png`/`favicon-*` into iOS asset catalog + Android
  adaptive icon (fg on `#04050A`) + web.
- 🔴 **Copy** (`COPY_DECK.md`): tagline → **"Your agents, in your pocket."**,
  wordmark `>conduit`, theme "Paper Kitty" → "Paper", strip cat/litter metaphors.
- 🟡 **Website + distribution differ.** Handoff ships a new HTML site
  (`design-reference/website/`) using **OTA `itms-services` manifest + direct APK**
  (no App Store/Play, no `brew`), reading `version.json`. Current `website/` is a
  GitHub-release static generator. → decision (see "Open decisions").

## Revised remaining phases (after mechanical Phases 1–5)
- **Phase 6 — finish the `swe-kitty` cleanup + repo/infra/docs:** repo URLs
  `nikhilsh/swe-kitty`→`nikhilsh/conduit` (coordinate w/ GitHub repo rename),
  `ci.yml`/`release.yml` repo-name refs, `memory.go` HANDOFF git URL, `.gitignore`
  paths, CLAUDE.md/README/docs sweep, `window.swekitty` terminal JS↔native bridge
  (rename both sides), core test fixtures (`swekitty-saved`, `SWEKITTY_TEST_*`),
  bare `swekitty://`/`SWE_KITTY_TOKEN` comments in core, the `.swe-kitty/` harness dir.
- **Phase 6b — kitty/litter/cat rename:** `LitterUI`→`ConduitUI` (iOS module + dir +
  ~50 types), Android `Litter*`, standalone `kitty`/`Kitty`, "Paper Kitty"→"Paper".
- **Phase 7 — visual re-skin:** `ConduitMark` daemon vector (reskin `AnimatedBrandMark`);
  app icons (iOS catalog, Android adaptive on `#04050A`, web favicons); splash; `>conduit`
  wordmark; bundle JetBrains Mono + Space Grotesk (optional fidelity); `COPY_DECK.md` copy.
- **Phase 8 — website + distribution:** per the website decision below.
- **Phase 9 — release + device verify:** provisioning under `sh.nikhil.conduit`,
  one re-pair, broker redeploy + `~/.swe-kitty`→`~/.conduit` migration, run the
  `RENAME_MAP.md` verification grep → **zero matches**, on-device QA.

## Open decisions (asked 2026-05-31)
1. **Website/distribution:** adopt the new OTA/APK handoff site wholesale vs. keep
   the current GitHub-release site + just rebrand it.
2. **`LitterUI`/`litter` rename timing:** now (own phase) vs. after the visual reskin.

## The one-time cost we're accepting

Because the **bundle ID changes**, the rebuilt app is a *new install* on device
— the old `sh.nikhil.swekitty` keychain items (pairing token, OAuth blobs) are
not visible to `sh.nikhil.conduit`. So:

- **No keychain-migration code.** Not worth writing; just rename the service
  constant to `sh.nikhil.conduit`.
- **One re-pair.** The device re-scans the QR / re-discovers the harness once.
  Acceptable for a personal sideloaded app.
- **mDNS service type, deep-link scheme, and `SWE_KITTY_TOKEN` all change in
  lockstep** — broker and client ship together, then re-pair once. No back-compat
  shims.

This is a **device-test session** (see CLAUDE.md "mobile is CI-compile-only"):
batch the whole rebrand into **one release** and verify on device once.

## Risk inventory (from the scope sweep)

| Item | Current | New | Note |
|---|---|---|---|
| iOS bundle ID | `sh.nikhil.swekitty` (+`.widgets`,`.tests`) | `sh.nikhil.conduit` | Needs a **new provisioning profile** via the ASC MCP for the release IPA |
| Android applicationId + namespace | `sh.nikhil.swekitty` | `sh.nikhil.conduit` | No Play listing to break |
| Deep-link scheme | `swekitty://` | `conduit://` | iOS `CFBundleURLSchemes` + Android intent-filter; QR pairing payload must emit the new scheme |
| mDNS service type | `_swe-kitty._tcp` | `_conduit._tcp` | Must match broker ↔ iOS `NSBonjourServices` ↔ Android NsdManager |
| Broker token env | `SWE_KITTY_TOKEN` | `CONDUIT_TOKEN` | Update broker + redeploy runbook; re-pin token on reup (see `docs/BROKER-REDEPLOY.md`) |
| Go module path | `github.com/nikhilsh/swe-kitty/broker` | `…/conduit/broker` | Touches every broker import |
| Rust crate | `swe-kitty-core` / lib `swe_kitty_core` | `conduit-core` / `conduit_core` | Regenerates UniFFI bindings; renames iOS `SweKittyCore.xcframework` + Android jniLib |
| Keychain service | `sh.nikhil.swekitty` | `sh.nikhil.conduit` | No migration (new install) |
| Sentry projects | `SENTRY_PROJECT_IOS/ANDROID` secrets | new Conduit projects | Old crash history orphaned; update CI secrets |
| GitHub repo | `swe-kitty` | `conduit` | GitHub 301-redirects old clones |
| Agent config dir | `~/.swe-kitty/agents` | `~/.conduit/agents` | Makefile + install.sh help text |

## Phased execution (ordered to keep CI green per commit)

CI gate per phase: `broker` = gofmt/vet/test; `core` = fmt/clippy/test;
Android = `:app:testDebugUnitTest`; iOS = CI `xcodebuild test`. Run local gates
(core + broker) before pushing each phase.

### Phase 1 — Rust core (`conduit-core`) + regenerate bindings
Coupled change — the generated module/package names that iOS & Android import
change here, so consuming import sites move with it.
- `core/Cargo.toml`: `name = "conduit-core"`, lib `name = "conduit_core"`, description.
- Rename `core/src/swe_kitty_core.udl` → `conduit_core.udl`; update `build.rs` / any `include_scaffolding!`.
- Update `Makefile` `bindings`/`ios` targets and `core/generated/*` output names (`conduit_core.swift`, `conduitCore.kt`).
- `apps/ios/build-rust.sh`: framework name `SweKittyCore.xcframework` → `ConduitCore.xcframework`; rename `apps/ios/SweKittyCore/` dir.
- `apps/android/build-rust.sh`: jniLib name; Kotlin import package `uniffi.swe_kitty_core` → `uniffi.conduit_core`.
- Regenerate bindings; fix iOS `import` + Android `import uniffi.…` sites.
- **Gate:** core test + clippy; both apps compile in CI.

### Phase 2 — Go broker (`conduit`)
- `broker/go.mod` module path → `github.com/nikhilsh/conduit/broker`; rewrite all internal imports.
- Rename `broker/cmd/swe-kitty-broker/` → `broker/cmd/conduit-broker/`; binary name in build/install.
- `discovery/mdns.go`: `ServiceType = "_conduit._tcp"`, hostname fallback.
- `main.go`: `SWE_KITTY_TOKEN` → `CONDUIT_TOKEN`; help text.
- `scripts/install.sh`, `Makefile` (`~/.conduit/agents`), `docs/BROKER-REDEPLOY.md`.
- **Gate:** `gofmt -l . && go vet ./... && go test ./...`.

### Phase 3 — iOS identifiers
- `apps/ios/project.yml`: project `name: Conduit`; targets `Conduit`/`ConduitWidgets`/`ConduitTests`; bundle IDs `sh.nikhil.conduit[.widgets|.tests]`; `CFBundleDisplayName: Conduit`; usage-description strings; `NSBonjourServices: _conduit._tcp`; `CFBundleURLName`/`CFBundleURLSchemes: conduit`; `ConduitCore.xcframework` dep path.
- Rename `apps/ios/Tests/SweKittyTests/` → `ConduitTests/`.
- `Keychain.swift`: `defaultService = "sh.nikhil.conduit"`, `.oauth` service.
- Any in-app UI copy ("SweKitty" → "Conduit").
- **Gate:** CI `xcodebuild test` of `ConduitTests`.

### Phase 4 — Android identifiers
- `build.gradle.kts`: `namespace`/`applicationId = "sh.nikhil.conduit"`; theme `Theme.Conduit`.
- `AndroidManifest.xml`: intent-filter `android:scheme="conduit"` (both filters); theme ref.
- `res/values/strings.xml`: `app_name = "Conduit"`; rename `Theme.SweKitty` style + any `R` refs.
- NsdManager service type `_conduit._tcp`; package moves if `com.…swekitty` exists.
- **Gate:** `:app:testDebugUnitTest`.

### Phase 5 — Website (`website/`)
- `build.mjs`: `<title>`/`<h1>` `SweKitty` → `Conduit`; hero tagline from the design handoff copy; IPA asset name `SweKitty.ipa` → `Conduit.ipa` (must match the renamed iOS artifact); `manifest.plist` bundle id → `sh.nikhil.conduit`; build user-agent `swe-kitty-website-build` → `conduit-website-build`; GitHub repo default → `nikhilsh/conduit`.
- `public/` icons/favicon: swap for the new Conduit icon from the handoff (Phase 7 dependency for the final art).
- `.deploy.yaml` / `fyra push` target: decide whether the site domain moves off `swekitty.kaopeh.com` (user call — see open questions).
- **Gate:** `npm run build` produces a clean `out/`.

### Phase 6 — Repo / infra / docs
- Rename GitHub repo to `nikhilsh/conduit` (relies on 301 redirect; update `origin` locally). **Needs user — external action.**
- `.github/workflows/*`: any repo/binary/artifact name refs (IPA/APK/broker artifact names → Conduit); new Sentry project secrets.
- README + `docs/**` product-name pass; `scripts/cut-release.sh` if it embeds names.
- Pairing QR payload / OAuth callback: confirm emitted scheme is `conduit://`.

### Phase 7 — Visual design (awaiting handoff)
Reconcile against the new design handoff — **neon-focused, compare-don't-replace**.
First diff the handoff against the current Neon theme + screens and list deltas,
then apply only the deltas. Copy strings come from the handoff.
- New app icon (iOS `AppIcon` asset set + Android adaptive icon / `ic_launcher`).
- Accent palette / theme tokens (ties into existing Neon theme work — see
  `[[project_neon_ui_rework]]` / `[[project_neon_v2_design_handoff]]`).
- Splash / launch screen, any screen-layout changes from the handoff.
- About screen: name + git SHA (SHA check stays — catches stale-tag releases).

### Phase 8 — Release + device verify
- Provision new `sh.nikhil.conduit` profile via ASC MCP; push as new GH secrets.
- Cut **one** tag from fresh `origin/main` (`scripts/cut-release.sh`).
- On device: install, **re-pair once**, smoke-test terminal + chat + LAN discovery + deep-link, read Sentry under the new project.
- **Flag everything UI/render/keyboard as needs-on-device-verify until confirmed.**

## Open questions for the asset drop
- The design-handoff **instructions + asset path** (the kickoff paste was empty).
- Website **domain**: keep `swekitty.kaopeh.com`, or move to a `conduit.*` host?
- Anything in the handoff that changes screen layout vs. just theme/icon/copy.

## Execution log (looped, phase-by-phase)
- **Phase 1 — Rust core: DONE (local gate green).** Crate `swe-kitty-core`→`conduit-core`, lib/UDL/namespace/`include_scaffolding`→`conduit_core`, inner FFI module→`conduit_coreFFI`, API symbols `SweKitty{Client,Delegate,Error}`→`Conduit{Client,Delegate,Error}`. Regenerated bindings (`conduit_core.swift`/`conduitCore.kt`), updated both `build-rust.sh` + Makefile, moved Android `uniffi.swe_kitty_core` imports + the 3 API call sites in iOS/Android. `cargo fmt/clippy/test` green. iOS/Android compile = CI-only. Outer `SweKittyCore.xcframework` dir + app-internal `SweKitty{App,Theme,Palette,Tests,Widgets}` deferred to Phases 3/4.
- **Phase 2 — Go broker: DONE (local gate green).** Module path `…/swe-kitty/broker`→`…/conduit/broker` + all imports; cmd dir `swe-kitty-broker`→`conduit-broker`; mDNS `_conduit._tcp` + hostname fallback; `SWE_KITTY_*`→`CONDUIT_*` env (incl. `CONDUIT_TOKEN`); state dirs `~/.swe-kitty/*`→`~/.conduit/*` + XDG; systemd `conduit.service` / user `conduit` / `/opt/conduit` / `conduit-mirror-auth`; replay title; sidecar pkg `conduit-sidecar`; release-broker.yml + release.yml broker artifact names; install.sh + remote-bootstrap.sh. `gofmt`/`go vet`/`go test ./...` all green. **Assumption:** embedded agent TOMLs' bare `swe-kitty memory` → `conduit-broker memory` (no `swe-kitty` symlink existed; matches `memory.go` usage). **Deferred to Phase 8 (live, needs user):** redeploy the running broker, migrate the on-box `~/.swe-kitty`→`~/.conduit` state (OAuth creds + saved sessions), swap the systemd unit, relaunch with `CONDUIT_TOKEN`, re-pair. **Kept for Phase 6:** `github.com/nikhilsh/swe-kitty` repo URLs + `ci.yml` `/swe-kitty/` checkout-path seds + release.yml title.
- **Phase 3 — iOS identifiers: DONE (CI-only verify).** Bundle IDs→`sh.nikhil.conduit[.widgets|.tests]`, `CFBundleDisplayName: Conduit`, project/targets/scheme `Conduit`, Bonjour `_conduit._tcp`, URL scheme `conduit://`, keychain `sh.nikhil.conduit(.oauth)`, all `swekitty.*` UserDefaults/keychain keys→`conduit.*` (fresh-install, no migration). Swift types `SweKitty{Theme,Palette,Typography,App,Widgets,Core,Tests}`→`Conduit*` (single `s/SweKitty/Conduit/g`). Dir/file renames: `ConduitApp.swift`, `ConduitWidgetsBundle.swift`, `Tests/ConduitTests/`, `ConduitCore/`. Updated `build-rust.sh` (ConduitCore.xcframework), Makefile, `ci.yml` scheme/test refs. `project.yml` valid YAML; `@main struct ConduitApp` matches. iOS compile = **CI verdict pending**. Repo URL in `LitterLicensesView.swift` kept for Phase 6.
- **Phase 4 — Android identifiers: DONE (CI-only verify).** `namespace`/`applicationId`→`sh.nikhil.conduit`; source package moved `sh/nikhil/swekitty/`→`sh/nikhil/conduit/` (127 files, all `package`/`import` decls); `Theme.Conduit`; deep-link scheme `conduit://` (both intent-filters); `app_name`→Conduit; `swekitty.*` DataStore/prefs keys→`conduit.*` (fresh install); mDNS `_conduit._tcp`; Kotlin types `SweKitty{Theme,Palette,Tests}`→`Conduit*`. Manifest relative `.MainActivity` resolves against new namespace. Android compile/unit-test = **CI verdict pending**. Repo URL in `LicensesScreen.kt` kept for Phase 6.
- **Phase 5 — Website + iOS/Android release workflows: DONE.** Website `build.mjs`/`package.json`: title/`<h1>` Conduit, `Conduit.ipa` (×2), manifest `sh.nikhil.conduit`, UA `conduit-website-build`, pkg `conduit-website`; `build.mjs` syntax OK. `release-ios.yml`: `APP_NAME`/`SCHEME`=Conduit, `BUNDLE_ID`=sh.nikhil.conduit, `Conduit.xcodeproj`, `Conduit.ipa` artifact. `release-android.yml`: keystore dname Conduit. **Kept for Phase 6:** repo `nikhilsh/swe-kitty`, domain `swekitty.kaopeh.com`, deploy `slug: swekitty` (domain is an open question). Full `npm run build` gated on a live Conduit release (Phase 8).
- _Phase 6 — Repo/infra/docs:_ next (some items need user — see below).
