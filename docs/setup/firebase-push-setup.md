# Conduit — Android push via Firebase / FCM (Nikhil's runbook)

A read-later runbook of **the human-only steps**. Everything here is yours to do
once; the agent picks up the rest. Plain-markdown twin of
[`firebase-push-setup.html`](firebase-push-setup.html) (the HTML has a saved
checklist + copy buttons).

**What you'll need:** a Google account, ~15 minutes, and the ability to run two
terminal commands on this box (the relay secret + the gh secret). No credit
card. No Play Console. Cloudflare Workers free tier covers the relay.

---

## 0 · Why Firebase at all? (read this first)

Conduit's push design (`docs/PLAN-PUSH.md`) is **self-hosted-first**. The primary
Android path is **UnifiedPush** — your own ntfy/Sunup distributor on the same VPS
as the broker, with *zero* vendor involvement and *zero* Firebase. That path
already works today (shipped in PR #442).

**FCM is only the fallback** — for Android users who don't run a distributor. You
only need this setup if you want that fallback to work. If you (and your users)
are happy running ntfy, you can skip this entire document.

When the fallback fires, the broker never touches Google directly. It POSTs to
our stateless Cloudflare relay (`conduit-push` at `push.conduit.nikhil.sh`),
which holds the service-account key and forwards to the FCM HTTP v1 endpoint. The
relay code already exists (`relay/src/fcm.ts`); it just needs the
`FCM_SERVICE_ACCOUNT` secret you'll create below.

---

## Part 1 · Firebase project + Android app → google-services.json

**Outcome:** a Firebase project and a `google-services.json` config file. This
file is **not a secret** — it ships inside the public APK and only contains
non-secret project/app identifiers.

1. **Create (or reuse) a Firebase project.** Go to
   <https://console.firebase.google.com> → **Add project**. Name it e.g.
   `conduit`. Google Analytics is optional — you can disable it (FCM works
   without it; Analytics only adds delivery reporting). Note the **Project ID**.

2. **Add an Android app.** In the project, click the Android icon (*Add app →
   Android*). For **Android package name** enter exactly:

   ```
   sh.nikhil.conduit
   ```

   (Verified against `apps/android/app/build.gradle.kts` — both `namespace` and
   `applicationId` are `sh.nikhil.conduit`.) App nickname and the debug SHA-1 are
   **optional** — leave SHA blank. **FCM messaging does not use the SHA
   fingerprint** (see FAQ). Click *Register app*.

3. **Download `google-services.json`.** The wizard offers it on the next screen.
   You can re-download later: [Project settings → General](https://console.firebase.google.com/project/_/settings/general/)
   → your Android app card → *google-services.json*. Save it somewhere you can
   scp/upload to this box. Its final home is `apps/android/app/google-services.json`.

4. **Skip the SDK/gradle wizard steps in the console.** The console will walk you
   through adding the gradle plugin and the messaging dependency. **Don't do that
   by hand** — the agent applies those exact edits (the stub from PR #442 is
   already in the tree). Just grab the JSON and move on.

**Part 1 checklist**

- [ ] Firebase project created; Project ID noted
- [ ] Android app added with package `sh.nikhil.conduit`
- [ ] `google-services.json` downloaded

---

## Part 2 · Minimal service account + JSON key (the relay secret)

**Outcome:** a JSON key for a **dedicated, least-privilege** service account. This
**is** a secret — it's the credential the relay uses to send. Treat it like a
password.

> **Use a dedicated minimal account — not the default Firebase Admin SDK
> account.** The default *firebase-adminsdk* account can do far more than send
> messages (Realtime DB, Auth admin, Storage…). A dedicated account scoped to
> just FCM sending limits the blast radius if the key ever leaks, and you can
> disable/rotate it independently.

1. **Open IAM Service Accounts** for your project (same Google project that backs
   Firebase): <https://console.cloud.google.com/iam-admin/serviceaccounts> →
   make sure the project picker (top bar) is set to your Firebase project.

2. **Create service account.** Click *+ Create service account*. Name it e.g.
   `conduit-fcm-relay`. Click *Create and continue*.

3. **Grant the single minimal role.** Add one role:

   ```
   Firebase Cloud Messaging API Admin
   (role id: roles/firebasecloudmessaging.admin)
   ```

   This is the minimal *predefined* role that grants
   `cloudmessaging.messages.create` (the FCM v1 send permission). Per Google's
   IAM reference there is no narrower predefined "send-only" role — this is the
   floor unless you author a custom role granting only
   `cloudmessaging.messages.create`. Click *Continue → Done*.

4. **Generate a JSON key.** Click the new account → *Keys* tab → *Add key →
   Create new key → JSON → Create*. A `*.json` file downloads. **This is the only
   copy** — Google won't show it again. The relay reads `client_email`,
   `private_key`, and `project_id` from it (see `relay/src/fcm.ts`).

**Part 2 checklist**

- [ ] Dedicated service account `conduit-fcm-relay` created
- [ ] Role `roles/firebasecloudmessaging.admin` granted (and nothing broader)
- [ ] JSON key downloaded and kept somewhere safe

---

## Part 3 · Land the credentials on this box

Two files, two homes. Run these from this dev box, or hand the files to the agent
and let it run the commands.

### 3a · The secret service-account JSON

Store it locally (chmod 600), matching the existing token convention
(`/root/.cloudflare-token`):

```bash
mkdir -p /root/.firebase
mv ~/Downloads/conduit-fcm-relay-*.json /root/.firebase/fcm-service-account.json
chmod 600 /root/.firebase/fcm-service-account.json
```

Push it to the Cloudflare relay as the `FCM_SERVICE_ACCOUNT` secret (the exact
name `relay/src/fcm.ts` reads). Run from `relay/`; paste the *whole file
contents* when prompted:

```bash
cd relay && npx wrangler secret put FCM_SERVICE_ACCOUNT < /root/.firebase/fcm-service-account.json
```

> Needs wrangler auth first: `npx wrangler login`, or
> `export CLOUDFLARE_API_TOKEN=$(cat /root/.cloudflare-token)`. Full relay
> provisioning (APNs key, KV namespace, deploy) is in `relay/README.md`.

Optionally also stash it as a GitHub repo secret (mirrors how `APNS_KEY_ID` et
al. are stored):

```bash
gh secret set FCM_SERVICE_ACCOUNT < /root/.firebase/fcm-service-account.json
```

### 3b · The non-secret google-services.json

This one ships in the APK, so it lives *in the repo* at the app module root. Hand
it to the agent, or drop it yourself:

```bash
mv ~/Downloads/google-services.json apps/android/app/google-services.json
```

The agent wires the gradle plugin + dependency that consume it (Part 4).

**Part 3 checklist**

- [ ] JSON saved at `/root/.firebase/fcm-service-account.json` (chmod 600)
- [ ] `wrangler secret put FCM_SERVICE_ACCOUNT` run against the relay
- [ ] (optional) `gh secret set FCM_SERVICE_ACCOUNT`
- [ ] `google-services.json` at `apps/android/app/google-services.json`

---

## Part 4 · Hand off to the agent (what we automate)

Once the JSON files land, tell the agent: **"FCM credentials are in place — flip
the Android FCM stub live."** Here is exactly what we automate (no human steps
inside this part):

1. **Relay:** confirm `FCM_SERVICE_ACCOUNT` is set and redeploy the worker if
   needed (`cd relay && npx wrangler deploy`); smoke-test `/v1/send` with
   `platform:"fcm"`.

2. **Android build wiring** (the enable steps baked into PR #442's
   `FcmPushProvider` stub):
   - add `id("com.google.gms.google-services")` to the `plugins {}` block in
     `apps/android/app/build.gradle.kts` (+ the classpath/plugin declaration at
     the project level);
   - add `implementation("com.google.firebase:firebase-messaging:<current>")`;
   - replace `FcmPushProvider.isAvailable = false` with the real
     `FirebaseMessaging.getInstance().token` logic. `PushProviders.forContext()`
     already prefers UnifiedPush and falls back to FCM automatically.

3. **PR:** open a build-wiring PR; CI verifies it compiles. (Reminder: per repo
   policy, on-device push delivery still needs a real device test — CI green ≠
   runtime verified.)

The seam (PushProvider / FcmPushProvider / UnifiedPushProvider / PushStore /
receiver) already merged in PR #442; only the four edits above flip FCM from
"unavailable" to live.

---

## Part 5 · Google Play specifics (only when you ship there)

**FCM itself needs nothing from Play.** Push works identically for a
Play-installed app and a sideloaded APK — there is no Play Console requirement
for FCM. The server side authenticates with the service-account key (Part 2); the
client side just needs `google-services.json` baked into the build. Neither
depends on how the app was distributed.

**The Play App Signing nuance:** when you publish on Play, Google re-signs the app
with its own managed key, so the delivered APK's signature differs from your
upload key. This *only* matters for Firebase services that authenticate the
client by certificate fingerprint — **Google Sign-In, App Check, Dynamic Links,
phone auth** (per Google's client-auth guide). **FCM messaging is not one of
them** — it doesn't check the app's SHA. So you can leave SHA fingerprints out of
Firebase entirely for a push-only integration. (If you later add Sign-In etc.,
register the Play App Signing SHA-256 from Play Console → App Integrity, plus
your debug/upload SHAs.)

**Data safety form (does matter on Play):** the `firebase-messaging` SDK collects
a **Firebase Installation ID** and device metadata (OS version, model, SDK
versions) — see Firebase's Play data-disclosure guidance. When you fill the Play
Console *Data safety* form you'll declare a **Device or other IDs** data type,
collected (not shared with third parties beyond Google subprocessors), purpose:
*app functionality* (delivering notifications). Note the 2025+ policy treating
Android-ID-class identifiers explicitly as device identifiers. If you don't enable
Analytics or BigQuery delivery export, that's the extent of it.

---

## FAQ

**Do I even need Firebase? What's the UnifiedPush alternative?**
No, not strictly. UnifiedPush (ntfy/Sunup distributor on your VPS) is the
primary, vendor-free path and ships already. FCM is purely the fallback for users
with no distributor. If your audience runs ntfy, skip all of this. See
`docs/PLAN-PUSH.md` and the "purity ladder": UnifiedPush → relay→FCM (Android) /
relay→APNs (iOS).

**What's secret here, and what isn't?**

| Artifact | Secret? | Where it lives |
|---|---|---|
| `google-services.json` | **Not secret** — ships in the APK; non-secret identifiers only | In the repo: `apps/android/app/google-services.json` |
| Service-account JSON key | **Secret** — full send credential | `/root/.firebase/` (chmod 600) + Cloudflare secret + optional gh secret. **Never** committed. |

**Why a dedicated service account instead of the default one?**
Least privilege. The default *firebase-adminsdk* account can administer most of
Firebase. A dedicated account with only `roles/firebasecloudmessaging.admin` can
do nothing but send messages, so a leaked key can't touch your data, and you can
disable/rotate it without affecting anything else.

**Why route through a relay instead of giving the broker the key?**
The broker is self-hosted and distributed; embedding a send credential in it
means one extraction lets anyone push to every install, and revoking breaks push
for everyone at once. The stateless Cloudflare relay holds the key centrally
(like Bitwarden / Home Assistant / ntfy do). The broker only ever sends
`{token, payload}` to the relay. See `relay/README.md`.

**Does sideloading vs Play change FCM behaviour?**
No. FCM delivery is identical either way. The only distribution-dependent thing is
the app's signing certificate fingerprint, which FCM messaging doesn't use (Part 5).

**Can I rotate or kill the key later?**
Yes. In IAM → the service account → Keys, delete the key (kills it everywhere) and
create a new one, then re-run `wrangler secret put FCM_SERVICE_ACCOUNT`. The relay
caches OAuth tokens keyed by `client_email`, so a rotation invalidates the cache
automatically.

---

## Sources (verified June 2026)

Repo ground truth:

- Package `sh.nikhil.conduit` — `apps/android/app/build.gradle.kts`
- Relay secret name `FCM_SERVICE_ACCOUNT` + FCM v1 endpoint + service-account
  field usage — `relay/src/fcm.ts`, `relay/README.md`
- Android FCM stub enable steps — PR #442 (branch `ws-p-3-android-push`)
- Push architecture — `docs/PLAN-PUSH.md`

External (console flows, current as of June 2026):

- [Add Firebase to your Android project](https://firebase.google.com/docs/android/setup)
- [Download Firebase config file (google-services.json is non-secret)](https://support.google.com/firebase/answer/7015592?hl=en)
- [Get started with FCM in Android apps](https://firebase.google.com/docs/cloud-messaging/android/get-started)
- [Send a message using FCM HTTP v1 API](https://firebase.google.com/docs/cloud-messaging/send/v1-api)
- [Firebase Cloud Messaging IAM roles & permissions](https://docs.cloud.google.com/iam/docs/roles-permissions/firebasecloudmessaging)
- [Client authentication — which services need a SHA fingerprint](https://developers.google.com/android/guides/client-auth)
- [Add a SHA fingerprint](https://support.google.com/firebase/answer/9137403?hl=en)
- [Prepare for Google Play's data disclosure requirements (FCM data types)](https://firebase.google.com/docs/android/play-data-disclosure)
- [Provide information for Google Play's Data safety section](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
