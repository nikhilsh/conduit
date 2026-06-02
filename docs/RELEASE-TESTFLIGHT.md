# Releasing Conduit to TestFlight

This is a **separate, opt-in** release path. The normal `v*` tag → `release.yml`
flow is unchanged: it still builds the **ad-hoc sideload IPA** (`release-ios.yml`)
and attaches it to a GitHub Release. TestFlight only happens when you explicitly
ask for it.

## How to trigger a TestFlight build

Either:

- **Manual:** GitHub → Actions → **release-testflight** → *Run workflow*, pick the
  branch/ref, optionally type a version label (e.g. `v0.1.0`).
- **Tag:** push a `tf-v*` tag, e.g. `git tag tf-v0.1.0 && git push origin tf-v0.1.0`.
  (`tf-v*` deliberately does **not** match `release.yml`'s `v*` trigger, so the
  two flows never fire together.)

The workflow archives, signs with the **App Store** profile, exports with
`method=app-store`, and uploads straight to App Store Connect with the ASC API
key. After it finishes, Apple **processes** the build (~5–30 min) before it shows
up in TestFlight.

## Automated post-upload (no manual ASC clicking)

After the upload, the workflow runs `apps/ios/scripts/testflight-postprocess.py`
(litter-style automation) which, via the ASC API:

1. **Waits** for Apple to finish processing the build.
2. Sets the per-build **"What to Test"** from the recent commit log
   (`git log -n 8`).
3. **Assigns the build to the beta group(s)** — default `Conduit Internal` — so
   it lands for internal testers with no manual step.

Two `workflow_dispatch` inputs tune this: `beta_group_names` (comma-separated,
default `Conduit Internal`) and `wait_for_processing` (default true). Tag-triggered
runs use the defaults. External (public-link) distribution and beta-review
submission are intentionally **not** automated yet — we're internal-only until a
reviewer demo-mode exists (Conduit can't be tested without a live broker).

## One-time setup (required before the first TestFlight build)

These touch the Apple Developer / App Store Connect account, so they're done by a
human (or with explicit approval), not by CI.

### 1. Create the App record

TestFlight needs a real **App record** for `sh.nikhil.conduit` — the bundle ID
(`H5KWA98RP6`) already exists, but no App record does yet.

App Store Connect → **My Apps** → **+** → **New App**:
- Platform: iOS
- Name: a **globally-unique** App Store name. "Conduit" may be taken — if so use
  e.g. "Conduit Terminal". (Editable until first public submission.)
- Primary language: English (U.S.)
- Bundle ID: `sh.nikhil.conduit`
- SKU: `sh.nikhil.conduit`

### 2. Create an App Store provisioning profile

There's only an ad-hoc profile today (`Conduit AdHoc`). Create an **App Store**
one bound to bundle `H5KWA98RP6` and distribution cert `F7Z295M652`
(exp 2027-05-17). Web UI: Certificates, IDs & Profiles → Profiles → + → *App Store
Connect* (App Store) → App ID `sh.nikhil.conduit` → cert `F7Z295M652` → name it
e.g. `Conduit AppStore`. Download it.

(The ASC API can also create it: `POST /v1/profiles` with
`profileType: IOS_APP_STORE`, bundleId `H5KWA98RP6`, certificate `F7Z295M652`.)

### 3. Push GitHub secrets to `nikhilsh/conduit`

New secrets this flow needs (the cert/keychain/Sentry secrets are shared with the
ad-hoc flow and already set):

| Secret | Value |
|---|---|
| `IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` | `base64 -w0 Conduit_AppStore.mobileprovision` |
| `ASC_API_KEY_ID` | `75Z4CZ6SJ5` |
| `ASC_API_ISSUER_ID` | `69a6de81-788e-47e3-e053-5b8c7c11a4d1` |
| `ASC_API_KEY_P8_BASE64` | `base64 -w0 /root/.appstoreconnect/AuthKey_75Z4CZ6SJ5.p8` |

```sh
gh secret set IOS_APPSTORE_PROVISIONING_PROFILE_BASE64 -R nikhilsh/conduit < <(base64 -w0 Conduit_AppStore.mobileprovision)
gh secret set ASC_API_KEY_ID -R nikhilsh/conduit --body 75Z4CZ6SJ5
gh secret set ASC_API_ISSUER_ID -R nikhilsh/conduit --body 69a6de81-788e-47e3-e053-5b8c7c11a4d1
gh secret set ASC_API_KEY_P8_BASE64 -R nikhilsh/conduit < <(base64 -w0 /root/.appstoreconnect/AuthKey_75Z4CZ6SJ5.p8)
```

### 4. (One time) Set up testers

- **Internal** (≤100, instant, no review): App Store Connect → Users and Access →
  add people, then TestFlight → Internal Testing group → add them. They get every
  processed build immediately.
- **External** (≤10,000, public/private link): TestFlight → add an external group;
  the **first** build requires a one-time **Beta App Review** (usually <24h).

## What's already wired in code

- `ITSAppUsesNonExemptEncryption: false` is set in `apps/ios/project.yml` so
  uploads don't stall on the export-compliance prompt.
- Build numbers use `github.run_number` (monotonic) — satisfies TestFlight's
  unique-build-number requirement automatically.

## Android parity

The equivalent for Android is a **Play Console Internal testing** track (upload an
AAB signed with the upload key). Not built yet — tracked separately.
