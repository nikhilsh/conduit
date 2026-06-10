# conduit-push — stateless push relay (Cloudflare Worker)

The vendor relay from [`docs/archive/PLAN-PUSH.md`](../docs/archive/PLAN-PUSH.md) (WS-P.2). It
holds the Apple APNs `.p8` key and a minimal-role Firebase service account, and
pass-throughs the broker's `{token, payload}` to Apple / Google. It is
**stateless**: no device tokens are stored — the only KV state is a per-install
daily rate counter and a first-use auth pin. **Payload contents are never
logged** (privacy).

Why a relay at all: an APNs `.p8` is Apple-account-wide (max 2 keys, no per-app
scope), so it can't ship inside the distributed self-hosted broker — one
extraction would let anyone push to every install, and revocation breaks push
for everyone at once. Bitwarden / Home Assistant / ntfy all converged on the
same thin-vendor-relay shape. See the plan doc for the full rationale.

## API

`POST /v1/send`

```jsonc
{
  "install_id": "deadbeefdeadbeef",      // 16–64 hex, minted by the broker
  "install_secret": "<>=32 chars>",       // minted by the broker, pinned on first use
  "platform": "apns",                     // "apns" | "fcm"
  "token": "<device token>",
  "env": "production",                     // optional; "production" (default) | "sandbox"
  "payload": {
    "title": "Conduit",
    "body": "a session needs you",
    "session_id": "abc123",               // optional — deep-link target
    "box": "my-box",                       // optional — deep-link target
    "category": "alert"                    // optional; "alert" (default) | "liveactivity"
  }
}
```

Responses:

| Status | Meaning |
|--------|---------|
| 200 | delivered to the upstream provider |
| 400 | malformed request / credentials |
| 401 | `install_secret` doesn't match the pin for this `install_id` |
| 410 | token permanently gone (APNs `Unregistered` / FCM `UNREGISTERED`) — the broker maps this to `push.ErrTokenGone` and prunes the token |
| 429 | over the daily cap (300/install/day) |
| 502 | other upstream error (terse JSON, no payload contents) |

> **APNs environment:** AdHoc / TestFlight builds use the **production** APNs
> environment, so `env` defaults to `production`. Only debug builds run against
> `sandbox`.

> **Live Activities** ride the same relay: `category: "liveactivity"` switches
> the APNs topic to `<topic>.push-type.liveactivity` and sets
> `apns-push-type: liveactivity`.

## Real-world IDs (for provisioning)

- Apple Team ID: `EHW7L3679R`
- APNs topic (bundle id): `sh.nikhil.conduit`

---

## Provisioning runbook (human-gated)

Everything below is a **one-time human step**. The agent that built this only
compiles + tests; it does **not** deploy and never handles key material.

### 1. Create the APNs `.p8` key (Apple Developer portal)

1. Sign in at <https://developer.apple.com/account> → **Certificates,
   Identifiers & Profiles** → **Keys**.
2. Click **+** (Create a key). Give it a name (e.g. `conduit-push`).
3. Enable **Apple Push Notifications service (APNs)**. Continue → Register.
4. **Download** the `.p8` file — you can only download it **once**. Store it
   securely (a password manager).
5. Note the **Key ID** (10 chars) shown on the key's page, and your **Team ID**
   (`EHW7L3679R`, top-right of the portal).
6. The APNs **topic** is the app bundle id: `sh.nikhil.conduit`.

> An Apple account allows a maximum of **2** APNs keys. Reuse the existing key
> across environments — the same key signs for both production and sandbox.

### 2. Create the Firebase project + minimal-role service account (FCM fallback)

1. <https://console.firebase.google.com> → **Add project** (or reuse one).
   Note the **Project ID**.
2. Add an Android app with package name `sh.nikhil.conduit` (FCM v1 needs the
   project; the relay reads `project_id` from the service-account JSON).
3. In the Google Cloud console → **IAM & Admin → Service Accounts** → **Create
   service account**. Grant the single role **Firebase Cloud Messaging API
   Admin** (`roles/firebasecloudmessaging.admin`) — nothing broader.
4. On the new service account → **Keys → Add key → Create new key → JSON**.
   Download the JSON. This is the `FCM_SERVICE_ACCOUNT` secret (full file
   contents).

### 3. Authenticate wrangler

Interactive:

```bash
npx wrangler login
```

Non-interactive (CI / headless): create a Cloudflare API token with the
**Edit Cloudflare Workers** template, then:

```bash
export CLOUDFLARE_API_TOKEN=...      # and CLOUDFLARE_ACCOUNT_ID if multi-account
```

### 4. Create the KV namespace

```bash
cd relay
npx wrangler kv namespace create RATE_LIMIT
```

Copy the printed `id` into `wrangler.toml`, replacing
`REPLACE_WITH_KV_NAMESPACE_ID`.

### 5. Set the secrets

Five secrets — secrets are **never** committed to the repo:

```bash
cd relay
# .p8 PEM contents (paste the whole file, multi-line; Ctrl-D to end):
npx wrangler secret put APNS_KEY
npx wrangler secret put APNS_KEY_ID      # 10-char key id from step 1
npx wrangler secret put APNS_TEAM_ID     # EHW7L3679R
npx wrangler secret put APNS_TOPIC       # sh.nikhil.conduit
# Firebase service-account JSON (paste the whole file):
npx wrangler secret put FCM_SERVICE_ACCOUNT
```

### 6. Deploy

```bash
cd relay
npx wrangler deploy
```

Point a route / custom domain (e.g. `push.conduit.nikhil.sh`) at the Worker in
the Cloudflare dashboard, matching the broker's default
`CONDUIT_PUSH_RELAY_URL`.

### 7. Smoke test

```bash
curl -sS -X POST https://push.conduit.nikhil.sh/v1/send \
  -H 'content-type: application/json' \
  -d '{
        "install_id":"deadbeefdeadbeef",
        "install_secret":"0123456789abcdef0123456789abcdef",
        "platform":"apns",
        "token":"<a real device token>",
        "env":"production",
        "payload":{"title":"Conduit","body":"hello from the relay","session_id":"test"}
      }'
```

Expect `{"ok":true}` (200) for a live token, `410` for a dead one, `429` once
over the daily cap.

---

## Local development

No Cloudflare login is needed to build or test:

```bash
cd relay
npm ci
npm run typecheck   # tsc --noEmit
npm test            # vitest, mocked fetch + generated crypto fixtures
```

Tests generate a throwaway EC P-256 / RSA key at runtime to exercise the JWT
signing path — **no key material is ever committed**.

`npx wrangler dev` runs the Worker locally, but you must provide secrets (via a
`.dev.vars` file, git-ignored) and a KV preview namespace first.
