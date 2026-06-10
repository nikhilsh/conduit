# PLAN: Push notifications — self-hosted-first delivery

> ARCHIVED 2026-06-10 — shipped; see docs/ROADMAP.md.

Status: approved plan, 2026-06-10. Owner: Nikhil. Independent of
`docs/archive/PLAN-AGENT-PLATFORM.md`; can run in parallel.

Events to deliver: **turn complete** and **agent needs your input** (approval card /
AskUserQuestion pending). Low volume, user-personal, latency target: seconds.

## Research verdict (2026-06-10, sourced — see PR description for citations)

**iOS:** there is no safe way for the user's VPS to talk to APNs directly. An APNs
`.p8` key is Apple-account-wide (max 2 keys, no per-app scoping); embedding it in the
distributed broker binary means one extraction → push spam across every app on the
account, and the only remediation (revoke) breaks push for every installed broker at
once. **No self-hosted product ships an embedded key.** Bitwarden (self-host →
push.bitwarden.com relay, installation-id auth), Home Assistant (vendor push proxy,
500/day/device rate limit), and ntfy (self-hosted server relays a content-free
poll-ID through ntfy.sh → APNs; device then fetches the real payload from the user's
server) all converged on the same shape: **a thin vendor relay that holds the key;
content can stay on the user's box.**

**Android:** genuinely vendor-free options exist. **UnifiedPush** lets the user run
their own distributor (ntfy server or Sunup) — on the same VPS as the broker — and the
broker delivers by POSTing to the distributor endpoint URL the app registered. FCM is
only needed as a fallback for users with no distributor, and the FCM service-account
key has the same don't-distribute problem as APNs (slightly better: per-key IAM
disable) → route the fallback through the same vendor relay.

**Non-options:** BGAppRefreshTask polling (15min–6h+, often never — useless for
"agent finished"), iOS Web Push (PWA-only, install friction — keep as purist opt-out,
not the main path). Live Activities updates ride APNs too (`.push-type.liveactivity`)
→ same relay, just an extra topic/payload shape.

## Architecture

```
                         ┌─────────────────────────────┐
 user's VPS              │  vendor relay (CF Worker)   │     Apple APNs
 ┌─────────────┐  HTTPS  │  stateless; holds .p8 +     │ ──► api.push.apple.com
 │ conduit-    │ ──────► │  min-scope FCM svc account; │     FCM (fallback only)
 │ broker      │         │  pass-through {token,payload}│ ──► fcm.googleapis.com
 │             │         └─────────────────────────────┘
 │  Dispatcher │
 │   ├─ relaySender (iOS APNs + FCM-fallback via relay)
 │   └─ unifiedPushSender (Android: POST direct to the user's own
 │      distributor endpoint — ZERO vendor involvement)
 └─────────────┘
```

- The broker's `push.Dispatcher`/`Registry`/`Sender` seam **already exists**
  (`broker/internal/push/dispatch.go` — fan-out, ErrTokenGone pruning, per-platform
  senders). Only the transports + wiring are missing.
- **Privacy mode (default on):** relay payloads are content-free
  (`"Conduit: a session needs you"` + session id); the app fetches details from the
  broker on tap. ntfy's poll-ID pattern, applied to our relay. A settings toggle can
  opt into full content in the push.
- **Purity ladder per platform:**
  - Android + self-hosted UnifiedPush distributor → no vendor hop at all.
  - Android without distributor → relay → FCM (embedded-FCM-key never shipped).
  - iOS → relay → APNs (only credible option; precedent: Bitwarden/HA/ntfy).

## Workstreams

### WS-P.1 Broker senders + registration API — `sonnet`

- `relaySender` implementing `push.Sender`: POST
  `{platform, token, payload, topic}` to `CONDUIT_PUSH_RELAY_URL`
  (default `https://push.conduit.nikhil.sh`, overridable/disable-able), auth =
  per-install random id+secret minted on first use, stored under `~/.conduit/`.
  Map relay 410 → `ErrTokenGone`. Timeouts, single retry, breadcrumbs.
- `unifiedPushSender`: the "token" IS the distributor endpoint URL; POST the payload
  to it directly (UnifiedPush spec body), `ErrTokenGone` on permanent 4xx.
- HTTP API: `POST /api/push/register {platform: apns|fcm|unifiedpush, token}` +
  `DELETE` (bearer-authed, identity = bearer, reuse Registry).
  Capabilities: `features.push = true`.
- Wire `Dispatcher.Notify` into the two event sites: turn-complete (where the status
  frame flips to idle after a turn) and pending-input (AskUserQuestion card emit /
  codex approval request). Only notify when no client socket is currently attached
  to the session (don't push at a user who's watching).
- Tests: stub relay HTTP server; registry pruning on 410; no-socket-attached gating.

### WS-P.2 The relay — `opus`

- New top-level dir `relay/` (Cloudflare Worker, TypeScript):
  `POST /v1/send {platform, token, payload, topic}` → APNs (JWT-signed with the
  vendor `.p8`, lib: `@fivesheepco/cloudflare-apns2` or hand-rolled WebCrypto JWT)
  or FCM HTTP v1 (service-account OAuth).
  - Stateless: no token storage; secrets via Worker secrets.
  - Per-install auth: accept any well-formed install id+secret pair, KV-store a
    counter per install for rate limiting (e.g. 300/day/install — HA precedent),
    410 pass-through from APNs/FCM.
  - `apns-push-type: alert` + `liveactivity` support (topic suffix) for later LA use.
- Deploy docs + `wrangler.toml`; secrets NEVER in the repo.
- Tests: vitest with mocked APNs/FCM endpoints; JWT shape golden.
- NOTE for the agent: build + tests only; actual deploy + key provisioning
  (Apple Developer portal, Firebase project) is a human step — document it in
  `relay/README.md` step-by-step.

### WS-P.3 App-side registration — `sonnet` ×2 (iOS, Android)

- iOS: request notification permission post-onboarding (not before first session —
  onboarding is accounts-free by design); register APNs token → broker
  `/api/push/register` for the active box (re-register on box switch/token rotation);
  handle tap → open the session. Foreground sockets already exist; nothing else.
- Android: integrate the UnifiedPush client lib; if a distributor is present,
  register its endpoint with the broker (`platform: unifiedpush`); else fall back to
  FCM token (`platform: fcm`). Settings row showing the active path
  ("via your ntfy server" / "via conduit relay") — honest-state rule.
- Both: deep-link payload `{session_id, box}` → session screen. Needs on-device
  verification; CI compile only.

### WS-P.4 Onboarding the self-hosted distributor (Android purist path) — `opus`, later

- Extend the SSH bootstrap (`scripts/remote-bootstrap.sh`) with an optional
  `--with-ntfy` that drops a ntfy server binary next to the broker and prints the
  topic URL; app detects it and auto-configures UnifiedPush via the ntfy app.
  (Stretch: document manual setup first; automate only if users ask.)

## Sequencing

WS-P.1 and WS-P.2 in parallel (contract: the `/v1/send` body above) → WS-P.3 after
both → WS-P.4 opportunistic. Human gates: Apple key + Firebase project provisioning,
relay deploy, broker redeploy (runbook), and a device-test session for the end-to-end
tap path.

## Costs & limits

- Relay at conduit's volume: Cloudflare Workers free tier covers it comfortably
  (pushes/user/day is single-digit); paid tier $5/mo if exceeded. KV for rate
  counters: negligible.
- Rate limit 300/day/install at the relay (HA uses 500); broker locally coalesces
  bursts (one push per session per idle-transition).
