# Per-user in-app OAuth for Claude + Codex agents

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).**
> OAuth v2 (server-side login manager, providers openai + anthropic) is the live
> path on both platforms. The only residue — deleting the dead v1
> `OAuthClient` / `set_agent_credentials` code once v2 is device-verified — is
> tracked in `ROADMAP.md` "In progress". Preserved for the v1→v2 history.

## Status (2026-05-23)

**Approach v2 (litter-faithful) — current.** v1 (PKCE on the phone,
custom-scheme redirect, see "v1 archive" sections below) shipped
through PRs #100/#104/#110/#112 and **does not work end-to-end** —
both Anthropic and OpenAI reject the `swekitty://` custom-scheme
redirect URI at the authorize endpoint. The v1 code paths
(`apps/ios/Sources/Models/OAuthClient.swift`,
`apps/android/.../auth/OAuthClient.kt`) are retained as the current
production fallback until v2 closes end-to-end. They will be removed
in Stage 4 below.

**Where v2 is right now**:

- Broker (#114): authorize-URL parser + WS handlers + per-session
  HOME materialization (#126) — done.
- iOS inbound: sheet renders the broker-issued URL, calls
  `ASWebAuthenticationSession`, captures the loopback callback — done.
- iOS outbound: `start_agent_login` / `agent_login_callback` /
  `cancel_agent_login` are not yet wired through `core/`'s UDL, so
  the sheet's "Start login" button surfaces a TODO toast. **This is
  the single open blocker for end-to-end Codex login on iOS.**
- Android (#144): pure-data coordinator + parser + tests landed; UI
  is still on the v1 PKCE flow.
- Anthropic: `claude auth login` flow not investigated end-to-end yet.

## Approach v2 — litter-faithful server-side login

litter (`dnakov/litter`) — the reference impl that already ships
working ChatGPT OAuth on iOS — does **not** run the OAuth flow on the
phone. It runs the agent CLI's own `login` subcommand on the server
and tunnels the loopback callback port back to the phone. PR #99's
research confirmed this pattern; we diverged in v1 to "ship the token
over WS" and the diverge broke the flow at the provider edge.

v2 follows litter:

1. Phone tells broker `{ "type": "start_agent_login", "provider":
   "openai" | "anthropic" }` over the existing authenticated WS.
2. Broker spawns the agent CLI's login subcommand:
   - **codex**: `codex login` — binds `127.0.0.1:1455` on the broker
     and prints `https://auth.openai.com/oauth/authorize?...&redirect_uri=http://localhost:1455/auth/callback&...`
     on stdout. Fallback port `1457` if `1455` is taken (per
     `codex-rs/login/src/server.rs` `FALLBACK_PORT`).
   - **claude**: `claude auth login` — uses Anthropic's own
     server-side bounce (`https://platform.claude.com/oauth/code/callback`,
     displays the code for the user to paste back into the CLI). No
     loopback port. Investigation note in §K below.
3. Broker captures the printed authorize URL **and** the loopback
   port (parsed from the URL's `redirect_uri`) + a `session_token` it
   minted for this attempt + the live CLI process handle.
4. Broker emits `{ "type": "view_event", "view": "status", "event": {
   "agent_login_url": { "provider": ..., "url": "<authorize>",
   "loopback_port": 1455, "session_token": "..." } } }` to the phone.
5. Phone receives the URL, starts a tiny local HTTP listener bound to
   `127.0.0.1:<loopback_port>` (matching what the provider thinks is
   the redirect destination) **before** it opens the browser, then
   presents `url` in `ASWebAuthenticationSession` (iOS) /
   `CustomTabsIntent` (Android).
6. User completes OAuth in browser. Provider redirects to
   `http://localhost:1455/auth/callback?code=...&state=...`. Because
   the phone is the device the browser runs on, the redirect lands on
   the **phone's** local loopback listener — never leaves the device.
7. Phone reads the query string, sends `{ "type":
   "agent_login_callback", "session_token": "...", "query_string":
   "code=...&state=..." }` over WS.
8. Broker forwards the query string to the still-running CLI process
   via the CLI's **own** loopback on the broker side — i.e. the
   broker does `GET http://127.0.0.1:1455/auth/callback?code=...` on
   localhost. The CLI sees this exactly as it would see a browser
   redirect on the same machine.
9. CLI receives the code, performs its own token exchange, writes
   `~/.codex/auth.json` (or `~/.claude/.credentials.json`) and exits.
10. Broker emits `{ "type": "view_event", "view": "status", "event":
    { "agent_login_complete": { "provider": ..., "ok": true } } }`.
11. Existing per-session HOME materialization (#106) reads the
    on-disk credentials at agent spawn time.

**Why this works where v1 didn't.** Both providers whitelist their
redirect URIs at the authorize endpoint. The codex CLI's
`app_EMoamEEZ73f0CkXaXp7hrann` client_id permits exactly
`http://localhost:1455/auth/callback` — never `swekitty://...`. By
having the broker spawn the CLI's own `login`, the authorize URL is
generated by the CLI itself with a redirect_uri the provider accepts.
We never invent params; we proxy the redirect.

**Why this is safer than v1.** Tokens never traverse our wire — the
CLI does the token exchange locally on the broker and writes the
on-disk file directly. The phone only ferries the `?code=...` query
string, which is single-use, time-bound, and useless without the
CLI's in-memory PKCE verifier.

**Wire shapes (v2).**

Client → broker:

```json
{ "type": "start_agent_login",
  "provider": "openai" | "anthropic" }

{ "type": "agent_login_callback",
  "session_token": "<server-issued>",
  "query_string": "code=...&state=..." }

{ "type": "cancel_agent_login",
  "session_token": "<server-issued>" }
```

Broker → client (typed `view_event`):

```json
{ "type": "view_event", "view": "status",
  "event": { "agent_login_url": {
    "provider": "openai",
    "url": "https://auth.openai.com/oauth/authorize?...",
    "loopback_port": 1455,
    "session_token": "<server-issued>" } } }

{ "type": "view_event", "view": "status",
  "event": { "agent_login_complete": {
    "provider": "openai",
    "ok": true } } }

{ "type": "view_event", "view": "status",
  "event": { "agent_login_failed": {
    "provider": "openai",
    "reason": "human-readable" } } }
```

**Stages (v2).**

- **Stage 0 (PR #114, shipped 2026-05-22)**: design doc + broker
  `internal/oauth/login_session.go` package with table tests for
  stdout-URL parsing + port detection, WS control-message handlers
  for `start_agent_login` / `agent_login_callback` /
  `cancel_agent_login`, iOS `AgentLoginLoopbackServer.swift` +
  `AgentLoginCoordinator.swift` skeletons. Followed by PR #126
  (broker per-session HOME isolation) so refresh races no longer
  corrupt the host operator's credentials.
- **Stage 1 — iOS end-to-end (PARTIALLY SHIPPED)**:
  - **Inbound side wired**: `LitterAgentLoginSheet` consumes
    `agent_login_url` / `agent_login_complete` / `agent_login_failed`
    view_events via `SessionStore.dispatchAgentLogin*`.
  - **Outbound side NOT wired**: `SessionStore.startAgentLogin(...)` /
    `sendAgentLoginCallback(...)` / `cancelAgentLogin(...)` currently
    surface a "not yet bridged through UDL" toast at
    `apps/ios/Sources/SessionStore.swift:1766` — the
    `start_agent_login` / `agent_login_callback` /
    `cancel_agent_login` control messages have **no UniFFI surface**
    in `core/src/swe_kitty_core.udl` yet. **Next concrete action**:
    add the three methods to the UDL, route them through
    `core/src/transport.rs` as JSON control messages, regenerate
    bindings.
- **Stage 2 — Anthropic via `claude auth login`**: not started. §K
  flags that Claude's flow may be web-display-only (paste-code, not
  loopback) — investigation gated on Stage 1 closing end-to-end on
  Codex first.
- **Stage 3 — Android port (PARTIALLY SHIPPED via #144)**: pure-data
  `AgentLoginCoordinator` state machine + `AgentLoginLoopbackServer`
  + `AgentLoginLoopbackParser` landed with 13+ unit tests; no UI
  wiring yet. `apps/android/.../ui/AgentLoginSheet.kt` exists but
  still drives the deprecated v1 PKCE-on-phone flow. **Next concrete
  action**: swap `AgentLoginSheet.kt` to call the new coordinator,
  add `CustomTabsIntent` launch + `java.net.ServerSocket` loopback
  binding, mirror the iOS UDL bridge once Stage 1 lands.
- **Stage 4 — delete v1 (BLOCKED on Stages 1–3)**: remove
  `OAuthClient.swift` / `OAuthClient.kt` / `OAuthCredentialStore`,
  the `set_agent_credentials` WS message, and the Keychain blobs.
  (The broker retains the encrypted credential store for refresh
  propagation — the wire stops carrying tokens; the broker still
  encrypts what the CLI wrote, see #106.)

**Risk register (v2).**

- Codex CLI's `login` server may bind a different port if `1455` is
  taken — the broker parses the actual port out of the printed
  authorize URL's `redirect_uri` query param, never hard-codes it.
  Codex's `FALLBACK_PORT` is `1457`.
- Claude CLI's `auth login` may not use a loopback at all (web-code
  paste flow). In that case, the broker ferries the displayed
  authorize URL to the phone, the phone presents it, and a separate
  "paste your code" path lands the code back via a new
  `agent_login_code` control message. Investigation tracked in §K.
- Broker must guard the CLI process lifetime — kill the login child
  if the phone disconnects mid-flow, time out at 10 min, and never
  leave an orphan listening on the loopback port.
- `session_token` is the broker's anti-confused-deputy mechanism: a
  random 32-byte token the broker mints and only forwards a
  `agent_login_callback` whose `session_token` matches an active
  login session. Prevents a malicious WS peer from racing the
  callback handoff on a shared broker.

---

## v1 archive (deprecated — superseded by v2 above)

The remainder of this document describes the original phone-side PKCE
+ `swekitty://` custom-scheme approach. It is preserved verbatim for
historical context (PRs #99, #100, #104, #110, #112). **All sections
below are deprecated. Do not implement against them.**

The original goal: replace the host-side `swekitty-mirror-auth`
script (currently invoked from systemd `ExecStartPre`, see
`scripts/install.sh` lines 200-230) with a wire protocol that ships
per-user OAuth tokens from the phone to the broker to the agent
container.

## Why rewrite

Today, the broker authenticates Claude Code + Codex by reading the
**deploying host operator's** `~/.claude/.credentials.json` and
`~/.codex/auth.json`, copied into the `app` service-user's `$HOME` by
`/usr/local/bin/swekitty-mirror-auth` (installed by `scripts/install.sh`
and re-run on every broker start via `ExecStartPre`). Container `home`
volume `swe-kitty-home` then surfaces those files at `/home/app/.claude`
and `/home/app/.codex` inside the broker container; agent spawns inherit
them because the broker just `exec`s `claude` / `codex` with the
container's `$HOME=/home/app` (see `broker/docker/docker-compose.yml`
line 56 and `Dockerfile` line 102).

This works for a single-operator self-host, but:

- It requires the host owner to have logged in to both CLIs **before**
  rolling out the broker, which is a chicken-and-egg problem for anyone
  who self-hosts via the install script alone.
- It hard-couples *who pays for the agents* to the host owner. Every
  phone-side user sharing the broker spends the host's quota.
- We've already shipped the per-user pairing surface (Bearer tokens
  printed as a QR) — pairing identifies a *phone-side identity* the
  broker doesn't yet use for anything beyond WS auth. We can scope
  agent credentials to that identity.
- It blocks the litter-style story we want for the website ("install
  the app, log in to ChatGPT / Claude in-app, point at any swe-kitty
  broker, go").

Mirror what `litter` does: in-app OAuth → token shipped to broker over
the existing authenticated WS → broker materializes a per-session
`auth.json` / `.credentials.json` and points the agent's `$HOME` at it.

## A. Litter's approach (verbatim code paths)

Litter ships in-app **ChatGPT OAuth** today (Claude isn't wired yet —
see commit history, no `ClaudeOAuth*` files exist). The wire is
PKCE → loopback HTTP server on the *phone* → token exchange in the app.

### A.1 iOS — `apps/ios/Sources/Litter/Models/ChatGPTOAuth.swift`

PKCE generation:

```swift
private static func generatePKCECodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
```

Authorize URL parameters:

```swift
URLQueryItem(name: "code_challenge", value: codeChallenge),
URLQueryItem(name: "code_challenge_method", value: "S256"),
URLQueryItem(name: "scope", value: "openid profile email offline_access")
```

Client ID is hardcoded as `app_EMoamEEZ73f0CkXaXp7hrann` (Codex's
public CLI client ID — same one the `codex` CLI uses, see §C).

Callback receiver is a **loopback server on `127.0.0.1:1455`** inside
the iOS app:

```swift
let callbackServer = try ChatGPTOAuthLoopbackServer(
    bindHost: ChatGPTOAuth.callbackBindHost,
    publicHost: ChatGPTOAuth.callbackPublicHost,
    port: ChatGPTOAuth.callbackPort)
```

This is the **same port** the `codex` CLI's own `login` subcommand
uses (§C). The loopback server binds both `127.0.0.1` and `::1`, uses
a 250 ms socket timeout, responds with an HTML page that JavaScript-
and meta-refreshes back into the app via `litterauth://chatgpt-auth-complete`.

Token exchange:

```swift
let body = [
    "grant_type=authorization_code",
    "code=\(urlEncode(code))",
    "code_verifier=\(urlEncode(codeVerifier))"
].joined(separator: "&")
// POST to https://auth.openai.com/oauth/token
```

Storage: iOS Keychain, accessibility
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

UI surface (`apps/ios/Sources/Litter/Views/AccountView.swift`):

```swift
Button {
    Task { isWorking = true; await loginWithChatGPT(); isWorking = false }
} label: {
    HStack {
        if isWorking { ProgressView() }
        Image(systemName: "person.crop.circle.badge.checkmark")
        Text("Login with ChatGPT")
    }
}
// invokes: appModel.loginLocalChatGPTAccount(serverId: server.serverId)
```

### A.2 Android — `apps/android/app/src/main/java/com/litter/android/auth/ChatGPTOAuthActivity.kt`

Chrome Custom Tabs:

```kotlin
CustomTabsIntent.Builder()
    .setShowTitle(true).build()
    .launchUrl(this, authUri)
```

A `ChatGPTOAuthLoopbackServer` on the same `localhost:1455` reads the
GET callback, returns an HTML page that bounces back to the activity
via `litterauth://chatgpt-auth-complete`. PKCE verifier is generated
upstream and passed in as an intent extra.

### A.3 Wire to the sidecar — `shared/rust-bridge/codex-mobile-client/src/mobile_client/mod.rs`

Litter does **not** ship the raw token over the wire. It runs the
codex CLI on the **server side** (the sidecar) and uses an SSH
port-forward trick: the codex CLI's `login` subcommand on the server
opens `auth.openai.com/...` and listens on `127.0.0.1:1455` on the
*server*. The Rust client SSH-tunnels that port back to the phone and
the phone's mobile-browser flow lands the redirect on the tunnelled
port, which the codex CLI on the server sees as a local callback.

```rust
let params = upstream::LoginAccountParams::Chatgpt {
    codex_streamlined_login: false,
};
// → server returns auth_url + login_id
// → client SSH-forwards port 1455 to the phone
// → user completes browser flow; codex CLI on the server writes
//   auth.json directly
// → client calls:
upstream::ClientRequest::CompleteLoginAccount {
    request_id: ..., params: upstream::CompleteLoginAccountParams { login_id },
}
```

The takeaway: litter's design **does not transmit tokens** — it
tunnels the OAuth callback port so the CLI's own `login` writes
`auth.json` on the server. Tokens never leave the server's filesystem.

### A.4 What we'll borrow vs. diverge

**Borrow**: PKCE + `ASWebAuthenticationSession` / Chrome Custom Tabs +
hardcoded codex `client_id` + Keychain / EncryptedSharedPreferences
for at-rest storage on the phone.

**Diverge**: we ship the token **over the WS** instead of tunnelling
the callback port (Stage 0 ergonomics — WS is already authenticated,
we don't need an SSH side-channel). swe-kitty's broker is talking to
the same phone over an already-bearer-authenticated WS; piggybacking a
JSON control message is strictly simpler than litter's
SSH-port-forwarding model. Forward-compat note: if we ever ship a
secondary control plane, we can switch to litter's tunnel model and
the on-disk schema doesn't change.

## B. Claude Code CLI auth mechanics

Source: `https://code.claude.com/docs/en/authentication` (fetched
2026-05-22).

### B.1 Credential file

- **Path**: `~/.claude/.credentials.json` (Linux), mode `0600`.
  Overridable via `CLAUDE_CONFIG_DIR` (the file then lives at
  `$CLAUDE_CONFIG_DIR/.credentials.json`). macOS uses Keychain; we
  don't care because our agent container is Linux.
- **Schema** (from `swekitty-mirror-auth` + existing memory):
  ```json
  {
    "claudeAiOauth": {
      "accessToken": "sk-ant-oat01-...",
      "refreshToken": "sk-ant-ort01-...",
      "expiresAt": 1700000000000,
      "scopes": ["user:inference", "user:profile"],
      "subscriptionType": "max"
    }
  }
  ```
  Numbers are ms-since-epoch.

### B.2 Precedence (highest → lowest)

1. Cloud-provider creds (`CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` /
   `_FOUNDRY` — we don't use any of these)
2. `ANTHROPIC_AUTH_TOKEN` — sent as `Authorization: Bearer`
3. `ANTHROPIC_API_KEY` — sent as `X-Api-Key`
4. `apiKeyHelper` script output (rotating creds)
5. `CLAUDE_CODE_OAUTH_TOKEN` — long-lived OAuth from `claude
   setup-token` (CI use; piped via env var)
6. Subscription OAuth from `.credentials.json`

### B.3 OAuth refresh

Refresh happens server-side inside the `claude` CLI — when an inference
call returns 401, the CLI uses `refreshToken` against Anthropic's
token endpoint and writes a fresh `accessToken` + `expiresAt` back to
`.credentials.json`. No env var sees the refresh. **Implication:**
if our broker mirrors `.credentials.json` once and never reads it
again, the phone's local copy goes stale. We solve this by treating
`.credentials.json` as the **canonical** copy and having the broker
watch the file (Stage G below).

### B.4 The path we use

We write `.credentials.json` (subscription OAuth path, precedence 6),
**not** `CLAUDE_CODE_OAUTH_TOKEN`. Reasons:
- We want to use the user's existing Pro/Max/Team subscription
  exactly as the desktop `claude` CLI does.
- The phone's OAuth flow gives us back the subscription credential
  shape natively — no need for the `claude setup-token` indirection.
- The file path is easy to materialize per-session with a different
  `HOME`.

## C. Codex CLI auth mechanics

Source: `https://developers.openai.com/codex/auth` plus
`codex-rs/login/src/server.rs`, `codex-rs/login/src/auth/storage.rs`
(commit on `openai/codex@main`, fetched 2026-05-22).

### C.1 Credential file

- **Path**: `~/.codex/auth.json`, in `$CODEX_HOME` (defaults to
  `~/.codex`).
- **Schema** (verbatim from `codex-rs/login/src/auth/storage.rs`):
  ```rust
  pub struct AuthDotJson {
      pub auth_mode: Option<AuthMode>,            // "ApiKey" | "ChatGPT"
      #[serde(rename = "OPENAI_API_KEY")]
      pub openai_api_key: Option<String>,
      pub tokens: Option<TokenData>,
      pub last_refresh: Option<DateTime<Utc>>,
      pub agent_identity: Option<String>,         // JWT, optional
  }
  pub struct TokenData {
      pub id_token: IdTokenInfo,                  // serialized JWT
      pub access_token: String,
      pub refresh_token: String,
      pub account_id: Option<String>,
  }
  ```
  On disk this becomes a JSON object with keys `auth_mode`,
  `OPENAI_API_KEY`, `tokens` (with `id_token`/`access_token`/
  `refresh_token`/`account_id`), `last_refresh`, `agent_identity`.

### C.2 OAuth flow constants (verbatim from `codex-rs/login/src/server.rs`)

```rust
const DEFAULT_PORT: u16 = 1455;
const FALLBACK_PORT: u16 = 1457;
const DEFAULT_ISSUER: &str = "https://auth.openai.com";
// redirect_uri:  http://localhost:{port}/auth/callback
// authorize:     {issuer}/oauth/authorize?{qs with code_challenge_method=S256}
// token:         {issuer}/oauth/token
```

`client_id` is passed via `ServerOptions` — the public value litter
uses (`app_EMoamEEZ73f0CkXaXp7hrann`) is the same one codex publishes;
both apps treat it as the public-client ID for the ChatGPT-account
OAuth flow.

### C.3 ENV overrides

- `CODEX_HOME` — alternate dir for `auth.json` + `config.toml`
- `OPENAI_API_KEY` — bypasses ChatGPT OAuth entirely (`auth_mode:
  ApiKey`); we don't want this for the per-user case
- `CODEX_ACCESS_TOKEN` — accepts an OAuth access token on stdin
  during `codex login --pipe`; not the path we'll take (no refresh
  token, no `id_token`)
- `SSL_CERT_FILE` / `CODEX_CA_CERTIFICATE` — corp-CA bundles

### C.4 OAuth refresh

The codex CLI refreshes its own `access_token` using
`tokens.refresh_token` and writes a fresh `auth.json` (updating
`last_refresh`). Same implication as Claude — the broker should
**read back** the file periodically, propagate the refresh upstream to
the phone so the phone's persistent copy stays current across
sessions and devices.

### C.5 The path we use

Write `auth.json` with `auth_mode: "ChatGPT"`, fill in `tokens.id_token`
/ `access_token` / `refresh_token` / `account_id`, leave
`OPENAI_API_KEY` null, leave `agent_identity` null (until OpenAI
publicizes how to mint these — they're for the new managed-agent
product). Set `$CODEX_HOME` to a per-session dir, no global mutation.

## D. Wire protocol (our design)

### D.1 Message shape

New JSON control messages on the existing authenticated WS (the
broker's bearer token already scopes to a single paired identity, so
the auth model is reused as-is — see `broker/internal/auth/auth.go`):

**Client → server, on initial pairing or whenever the user re-logs:**

```json
{
  "type": "set_agent_credentials",
  "ts": "2026-05-22T08:00:00.000Z",
  "provider": "anthropic" | "openai",
  "kind": "oauth",
  "credential": {
    // Provider-native blob, schema matches what the CLI writes to
    // disk. Broker stores verbatim — no normalization.
    // For provider="anthropic": the full claudeAiOauth credentials.json
    "claudeAiOauth": {
      "accessToken": "sk-ant-oat01-...",
      "refreshToken": "sk-ant-ort01-...",
      "expiresAt": 1700000000000,
      "scopes": ["user:inference", "user:profile"],
      "subscriptionType": "max"
    }
    // For provider="openai": the full AuthDotJson contents
    // "auth_mode": "ChatGPT",
    // "OPENAI_API_KEY": null,
    // "tokens": { "id_token":"...", "access_token":"...",
    //             "refresh_token":"...", "account_id":"..." },
    // "last_refresh": "2026-05-22T08:00:00Z",
    // "agent_identity": null
  }
}
```

The broker stores the credential **keyed by the bearer token's
identity**, not per-session. Subsequent sessions started by the same
phone reuse the stored credential.

**Server → client, when the agent's on-disk file changes (refresh):**

```json
{
  "type": "agent_credentials_refreshed",
  "ts": "...",
  "provider": "anthropic" | "openai",
  "credential": { /* same shape as set_agent_credentials.credential */ }
}
```

The phone updates Keychain / EncryptedSharedPreferences with the new
blob so re-pairing on a new broker just-works.

**Server → client, when the credential is missing or rejected:**

```json
{ "type": "agent_credentials_required",
  "provider": "anthropic" | "openai",
  "reason": "missing" | "expired" | "rejected" }
```

The phone shows the "Log in to <provider>" button. `reason=rejected`
tells the phone to wipe the stored copy first (it's truly dead).

### D.2 On-disk shape (broker)

Per identity-bearer-token, **encrypted at rest** under the broker's
state dir:

```
$BROKER_STATE_DIR/credentials/
    <bearer-token-sha256>/
        anthropic.enc   # AES-GCM(claudeAiOauth blob)
        openai.enc      # AES-GCM(AuthDotJson blob)
        nonce           # 12-byte random, regen per write
```

Master key: derived from a host-machine secret (`/etc/machine-id`
mixed with a salt generated on first broker start and stored at
`$BROKER_STATE_DIR/credentials/.key-salt`). Trade-off: this is *not*
hardware-bound — anyone with read access to the broker's state dir
and `/etc/machine-id` can decrypt. The threat model is "casual host
snooping", not "well-resourced attacker with root on the host" — root
on the host is game over for everything (PTYs, source code, etc.) by
construction. Stage G considers an SE / TPM-bound key path.

### D.3 Per-session materialization

When the broker spawns an agent for a session owned by identity `I`
running assistant `claude`:

1. Decrypt `credentials/<sha256(I)>/anthropic.enc` → in-memory blob.
2. Create a per-session ephemeral dir
   `$BROKER_STATE_DIR/sessions/<uuid>/agent-home/.claude/` with mode
   `0700`.
3. Write the blob to `<ephemeral>/.claude/.credentials.json` mode `0600`.
4. Spawn `claude` with `HOME=<ephemeral>`. This is the **only**
   change to the agent process — the CLI sees a regular
   `.credentials.json` exactly as if the user had `claude login`'d.
5. **Watch the file** (inotify) and broadcast `agent_credentials_refreshed`
   on every modification.
6. On session exit, atomically replace the encrypted blob with the
   latest on-disk contents (captures any refresh that happened in
   this session) and `rm -rf` the ephemeral dir.

Codex is symmetrical: write `auth.json` to
`<ephemeral>/.codex/auth.json`, spawn `codex` with `HOME=<ephemeral>
CODEX_HOME=<ephemeral>/.codex`.

### D.4 Refresh handling

Two refresh sources:

- **Agent-driven refresh** (the common case): the CLI writes a new
  `.credentials.json` / `auth.json` while the session is live.
  Inotify fires → broker re-encrypts and stores → broadcasts
  `agent_credentials_refreshed` to the WS (if the phone is connected).
  Phone Keychain gets updated.
- **Phone-driven refresh**: the phone re-runs the OAuth flow (user
  hit "log out / log in again") → sends a new `set_agent_credentials`
  → broker overwrites the encrypted blob → in-flight sessions
  continue using the old file (the agent CLI does its own refresh
  loop, it doesn't watch the file) → next session creation picks up
  the new credential. This is the desired semantics.

## E. iOS implementation plan

### E.1 OAuth flow

Use **`ASWebAuthenticationSession`** (not WKWebView). It's the
system-blessed OAuth surface; it shows the OS-managed browser, doesn't
leak cookies into the app, and supports both custom-scheme and
universal-link callbacks.

```swift
let session = ASWebAuthenticationSession(
    url: authorizeURL,
    callbackURLScheme: "swekitty"
) { callbackURL, error in
    // exchange code for tokens via POST to provider's /oauth/token
}
session.presentationContextProvider = ...
session.prefersEphemeralWebBrowserSession = false  // share cookies w/ Safari
session.start()
```

Universal-link / scheme: **`swekitty://oauth/<provider>/callback?code=...&state=...`**.
Provider is `anthropic` or `openai`.

Code flow per provider:

- **Codex / OpenAI**: hardcoded `client_id` =
  `app_EMoamEEZ73f0CkXaXp7hrann`, issuer = `https://auth.openai.com`,
  scope = `openid profile email offline_access`, PKCE S256.
  After code exchange we get `access_token`, `id_token`, `refresh_token`,
  and (decoded from the id_token) `account_id`.
- **Claude / Anthropic**: client_id from the `claude` CLI's
  GitHub-Action public OAuth app — we'll need to derive this from
  `claude setup-token`'s actual HTTP traffic the first time we
  implement (do not invent). Issuer is `https://claude.ai/oauth/...`.
  Scopes: `user:inference user:profile`. PKCE S256.

### E.2 Keychain storage

```swift
// Service: "swekitty.agent-credentials"
// Account: "anthropic" or "openai"
// AccessControl: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
//                + .biometryCurrentSet (optional, Stage I+)
let attributes: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "swekitty.agent-credentials",
    kSecAttrAccount as String: provider,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    kSecValueData as String: blobJsonBytes,
]
SecItemAdd(attributes as CFDictionary, nil)
```

### E.3 UI surface

`apps/ios/Sources/SweKitty/Views/AgentLoginSheet.swift` (new) — a
sheet with two buttons:

- "Log in to Claude" → starts Anthropic OAuth
- "Log in to ChatGPT (for Codex)" → starts OpenAI OAuth

Sheet is reachable from:
- The pairing screen when the broker just sent
  `agent_credentials_required`
- Settings → Agents → "Manage logins"
- Inline pill at the top of the chat surface when the active agent's
  credential is missing

### E.4 Wire-up

`SweKittyClient.setAgentCredentials(_ provider:, blob:)` sends the
JSON control message over the live WS. On `agent_credentials_refreshed`,
the WS-receive loop pushes the refreshed blob back into Keychain.

### E.5 Universal-link setup

Add `swekitty` URL scheme + an `Info.plist` `CFBundleURLTypes` entry,
*and* an apple-app-site-association on the swe-kitty website so
`https://swe-kitty.app/oauth-bounce/<provider>` is also a valid
callback (Stage I — only matters if a provider doesn't accept custom
schemes; today both do).

## F. Android implementation plan

### F.1 OAuth flow

Use **Chrome Custom Tabs**. Same PKCE flow, same provider endpoints,
same `client_id`s.

```kotlin
val authIntent = CustomTabsIntent.Builder()
    .setShowTitle(true)
    .build()
authIntent.launchUrl(this, authorizeUri)
```

### F.2 Intent filter for the callback

`AndroidManifest.xml`:

```xml
<activity android:name=".auth.AgentOAuthRedirectActivity"
          android:exported="true"
          android:launchMode="singleTop">
    <intent-filter android:autoVerify="false">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="swekitty" android:host="oauth" />
    </intent-filter>
</activity>
```

### F.3 EncryptedSharedPreferences

```kotlin
val masterKey = MasterKey.Builder(context)
    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
    .build()
val prefs = EncryptedSharedPreferences.create(
    context, "swekitty-agent-credentials", masterKey,
    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
)
prefs.edit().putString("anthropic-blob", blobJson).apply()
```

### F.4 UI + wire-up

Symmetric to iOS — sheet with two buttons in
`apps/android/.../auth/AgentLoginSheet.kt`, same WS message shape.

## G. Broker implementation plan

### G.1 Code layout

```
broker/internal/credentials/
    store.go          # encrypted-at-rest read/write, key derivation
    store_test.go
    materialize.go    # per-session ephemeral dir + HOME setup
    materialize_test.go
    watcher.go        # inotify → broadcast refresh
    watcher_test.go
broker/internal/ws/
    server.go         # add handler for set_agent_credentials
```

### G.2 Spawn-time integration

In `broker/internal/session/lifecycle.go`'s `commandEnv` (today line
69), append:

```go
if creds := s.materializedCredentials; creds != nil {
    env = append(env, "HOME="+creds.AgentHome)
    if s.Assistant == "codex" {
        env = append(env, "CODEX_HOME="+filepath.Join(creds.AgentHome, ".codex"))
    }
}
```

`s.materializedCredentials` is populated by `manager.go` when the
session is created. If no credential exists for the bearer-token
identity, fall back to today's behavior (the container-wide
`/home/app/.{claude,codex}` files from `swekitty-mirror-auth`).

### G.3 Watcher

`fsnotify.NewWatcher()` on `<agent-home>/.claude/.credentials.json`
and `.codex/auth.json`. On write: read, encrypt, store, broadcast.
Debounce 250 ms to coalesce the temp-file-rename pattern that both
CLIs use.

### G.4 401 hook

Out of scope for Stage 0-3 — the CLI handles refresh internally. If
a CLI gives up on refresh (e.g. refresh token revoked server-side),
the session will spew auth errors into the PTY; the broker can pattern-
match those (cheap, fragile) and emit
`agent_credentials_required reason=rejected` to the phone. Defer to
Stage I.

## H. Migration & rollback

- **Keep `swekitty-mirror-auth`** as a fallback. The broker's
  per-session materialization is opt-in: if no `set_agent_credentials`
  has ever arrived for a bearer-token identity, the agent inherits
  the container-wide `$HOME=/home/app` exactly as today.
- **Feature flag**: `KITTY_AGENT_OAUTH_PER_USER` env var on the
  broker, default off through Stage E (iOS surface lands), default on
  from Stage F+.
- **Rollback**: setting `KITTY_AGENT_OAUTH_PER_USER=0` immediately
  reverts to the global mirror path, even if encrypted credentials
  exist on disk (they get ignored, not deleted — so re-enabling later
  doesn't require re-OAuth).
- **Encrypted-blob format versioning**: prepend a 1-byte version
  prefix to every `.enc` file; bump it if we ever change AEAD
  algorithm.

## I. Stages

Each stage is a single demoable PR. Roughly modeled on
`PLAN-TERMINAL-REWRITE.md`'s staging discipline.

- **Stage 0 — iOS-only ChatGPT OAuth spike (THIS-PR's followup).**
  Add `AgentLoginSheet.swift` + `OAuthClient.swift` + `Keychain.swift`
  on iOS. Button labelled "Login with ChatGPT". Runs the full PKCE
  → `ASWebAuthenticationSession` → `auth.openai.com` flow. **Stashes
  the resulting blob in Keychain and prints it to the console.** No
  broker wiring; no Claude flow yet; no Android. Demoable: tap
  button, complete browser flow, see the access/refresh token logged.
  Validates: the OAuth client_id works, our PKCE math is right,
  Keychain access pattern is right.

- **Stage 1 — broker `set_agent_credentials` handler + per-session
  materialization for Codex.** Server-side only. Add `credentials/`
  package. Define the WS message. Materialize `auth.json` to a
  per-session `agent-home/.codex/`. Spawn codex with `HOME=` +
  `CODEX_HOME=`. Watch the file, log refreshes (no broadcast yet).
  Demoable: paste a hand-rolled `auth.json` blob into a WS
  message via `wscat`, see codex start with that credential in a
  fresh session.

- **Stage 2 — iOS end-to-end for Codex.** Wire the Stage 0 sheet to
  the Stage 1 broker handler. Send `set_agent_credentials` over the
  paired WS. Add `agent_credentials_refreshed` listener on iOS that
  rewrites Keychain. Demoable: a fresh-install phone pairs with a
  fresh-install broker (host operator has *no* `~/.codex/auth.json`),
  taps "Login with ChatGPT", spawns a Codex session, agent runs on
  the user's quota.

- **Stage 3 — Claude flow.** Add Anthropic OAuth alongside the
  Codex one (separate button, same sheet, same WS message with
  `provider: "anthropic"`). Broker writes `.credentials.json`
  instead of `auth.json`. Stage 2 demoability for the Claude side.

- **Stage 4 — Android.** Port Stage 0-3 to Android (Chrome Custom
  Tabs, EncryptedSharedPreferences, identical WS protocol).

- **Stage 5 — refresh broadcast + 401 hook.** Implement the
  `agent_credentials_refreshed` broadcast path. Pattern-match auth-
  failure strings in PTY output to emit `agent_credentials_required
  reason=rejected`. Stage I (optional) work: SE/TPM-bound master key,
  biometric-gated Keychain access.

- **Stage 6 — retire `swekitty-mirror-auth`.** Once Stage 4 ships and
  bakes for one release with no rollback, remove the systemd hook +
  install-script chunk + container-wide `/home/app/.claude` mounts
  from `docker-compose.yml`. The container becomes credential-free
  by default; agents auth strictly through per-session ephemeral
  homes.

## J. Risk log

- **Anthropic OAuth client_id leak**: We need a public client_id for
  the Claude OAuth flow. The `claude` CLI's `setup-token` flow uses
  one; we have to derive ours from observed traffic (Stage 3 only).
  If Anthropic later restricts it, we have to ship an updated app.
  Same risk litter accepts for Codex.
- **Token at-rest crypto is host-machine-bound, not user-bound**:
  Trade-off accepted in §D.2 — anyone with read access to broker
  state can decrypt. Mitigations: file mode `0600`, broker state
  dir mode `0700`, owned by the `app` service user.
- **Agent CLI changes the on-disk schema**: Both vendors could
  re-shape `.credentials.json` / `auth.json` between versions. We
  store the blob verbatim, so additive changes (new fields) are safe.
  Breaking schema changes manifest as the CLI's own login pop-up
  during a session; broker pattern-match catches it and asks the
  phone to re-OAuth.
- **WS message size**: `set_agent_credentials` carries a credential
  blob of ~1-4 KB. Well under any frame limit. No chunking needed.

## References

- `scripts/install.sh` lines 200-230 — current host-side mirror
- `broker/docker/docker-compose.yml` line 56 — container `home` volume
- `broker/docker/Dockerfile` line 102 — `ENV HOME=/home/app`
- `broker/internal/session/lifecycle.go` line 69 — `commandEnv`
- `broker/internal/auth/auth.go` — bearer-token store (re-used for
  identity scoping)
- `docs/WEBSOCKET-PROTOCOL.md` §3.3 — client → server JSON messages
  (where `set_agent_credentials` slots in)
- `docs/SESSION-LIFECYCLE.md` — per-session worktree pattern that
  agent-home mirrors
- `dnakov/litter` `apps/ios/Sources/Litter/Models/ChatGPTOAuth.swift`
- `openai/codex` `codex-rs/login/src/server.rs` and
  `codex-rs/login/src/auth/storage.rs`
- `https://code.claude.com/docs/en/authentication`
- `https://developers.openai.com/codex/auth`

## K. CLI auth subcommand investigation (v2)

Confirmed locally on the harness host 2026-05-22:

- **`codex login`** — verified. Stdout (verbatim first 5 lines):
  ```
  Starting local login server on http://localhost:1455.
  If your browser did not open, navigate to this URL to authenticate:

  https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&...
  ```
  The broker parses the second non-empty `https://` line as the
  authorize URL and extracts the `redirect_uri` query param to learn
  the actual loopback port (handles `FALLBACK_PORT=1457` per
  `codex-rs/login/src/server.rs`). Test fixtures live in
  `broker/internal/oauth/login_session_test.go`.

- **`claude auth login`** — verified subcommand exists. Flags:
  `--claudeai` (default, subscription path), `--console` (API
  billing), `--sso`. **Loopback behaviour not yet confirmed** — to be
  validated end-to-end in Stage 2. If it follows the
  `setup-token`-style "paste this code" web flow (where the redirect
  URI is `https://platform.claude.com/oauth/code/callback` and the
  user copies the displayed code back into the CLI), the broker's
  `login_session.go` ferries the displayed URL but the phone does
  **not** start a loopback listener — instead the phone presents a
  "paste your code" prompt after the browser closes, and ships the
  code back via `agent_login_code`. The v2 wire protocol leaves room
  for this branch: `agent_login_url.loopback_port` may be `0` to
  signal the code-paste flow.
