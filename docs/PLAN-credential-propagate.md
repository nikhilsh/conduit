# Credential auto-propagate + per-box control — app implementation spec

Broker half shipped on branch `broker-credential-propagate`. This file is the
precise iOS + Android spec for the APP half (separate PR). All anchors are
`file:line` against `origin/main` at the time this was written — re-grep before
editing, the line numbers drift.

## The bug being fixed

Credentials are device-global on the phone (Keychain / EncryptedSharedPrefs) but
the broker stores them **per-box** (per bearer identity). A box connected AFTER
sign-in (classically an SSH box, but any box added later) never received the
pushed credential, so starting a claude session there returns
`Failed to authenticate. API Error: 401`. Chosen fix: **auto-propagate** the
stored credential to any box you connect that is missing it, plus **per-box
status** and **per-box sign-out**.

## What the broker now exposes (this branch)

1. **Readiness sees pushed creds.** `GET /api/capabilities` →
   `readiness.agents.<name>.signed_in` is now `true` when the per-identity
   credential store has the provider, even with no host-login file. So an
   auto-propagated box correctly reports signed-in.
   (broker `internal/ws/readiness.go` `agentSignInState`, plumbed via
   `buildReadiness` in `internal/ws/api.go`.)

2. **Session-less credential push** — NEW HTTP endpoint:
   ```
   POST /api/agent/credentials
   Authorization: Bearer <box token>   (or ?token=<token>)
   { "provider": "anthropic"|"openai", "kind": "oauth", "credential": {…native blob…} }
   → 200 {"stored":true,"provider":"…"}
   → 400 unknown_provider | unsupported_kind | empty_credential | invalid_request
   → 401 (bad/missing bearer) | 503 credentials_unavailable (old broker, no store)
   ```
   This is the seam for auto-propagate-on-connect: it stores a credential for a
   box that has **no session yet**, keyed by the request bearer (the same
   identity the store uses), encrypted-at-rest unchanged. The in-session WS
   `set_agent_credentials` control message is untouched and still works.

   **Decision rationale (why HTTP, not a session-less WS):** the broker WS path
   (`serveWS`) is always session-bound — it `GetOrCreate`s a session on connect.
   There is no session-less control socket, and inventing one means a new
   connection lifecycle. The credential store is already keyed by the broker
   bearer (single-operator), which the authenticated HTTP request already
   carries, so `POST /api/agent/credentials` lands the blob in exactly the place
   the in-session push would have. It mirrors `POST /api/push/register`
   precisely. Net new surface stays inside the broker's `ws` package.

3. **Per-box sign-out** — NEW HTTP endpoint + NEW WS control message:
   ```
   POST /api/agent/credentials/clear
   Authorization: Bearer <box token>
   { "provider": "anthropic"|"openai" }
   → 200 {"cleared":true,"provider":"…"} (idempotent: clearing nothing is 200)
   → 400 unknown_provider | invalid_request | 401 | 503
   ```
   Also available in-session as WS control `{"type":"clear_agent_credentials",
   "provider":"…"}`. Both remove ONLY the app-pushed `<provider>.enc` blob; they
   never touch the box owner's host-HOME login files (`~/.claude/.credentials.json`,
   `~/.codex/auth.json`). **Surface this honestly in the UI: "Remove pushed
   credential from this box" — NOT "Sign out of Claude on this box".**

4. **Typed 401 signal — NOT built this round (deliberate).** See
   "401 handling" below; do the string-match fallback now, typed event later.

After this broker PR merges, the broker MUST be redeployed for the endpoints to
be live (tagging does not deploy the broker).

---

## iOS

### A. Auto-propagate on connect (the core fix)

Today `replayStoredAgentCredentials()` (`SessionStore.swift:3451`) is called only
inside `createSession` success (`:2487`) and at sign-in
(`ConduitAgentLoginSheet.swift:438`). It pushes via
`sendAgentCredentials(provider:credential:)` (`:3316`), which routes through the
Rust `client.setAgentCredentials` over a **live session WS** (`any_handle`). That
never fires for a box you merely connect.

Add an HTTP-based replay that works session-lessly, and call it on every
box-connect path:

1. **New method** on `SessionStore`, next to `getJSON` (`:1759`) and
   `sendAgentCredentials` (`:3316`):
   ```swift
   /// Push every locally-stored agent credential to a specific box over
   /// HTTP (POST /api/agent/credentials), independent of any session. Used
   /// by the connect paths so a freshly-connected box gets creds before its
   /// first session. Best-effort per provider; 503 = old broker, skip.
   func propagateStoredAgentCredentials(to endpoint: StoredEndpoint) async {
       for provider in [OAuthProvider.openai, .anthropic] {
           guard let credential = OAuthCredentialStore.load(provider: provider) else { continue }
           guard let json = try? Self.encodeCredentialAsJSONString(credential) else { continue }
           // POST to endpoint.httpBaseURL + "/api/agent/credentials"
           // headers: Authorization: Bearer endpoint.token, Content-Type: application/json
           // body: {"provider": provider.rawValue, "kind":"oauth", "credential": <json as raw JSON>}
           // NOTE: `credential` must be the RAW JSON object, not a string —
           //       reuse encodeCredentialAsJSONString's output but inject it as
           //       a JSON value (it already produces the native blob JSON).
           // Telemetry.breadcrumb("agent_creds","propagate", data:["host":endpoint.displayHost,"provider":provider.rawValue])
           // On non-2xx (esp. 503) just breadcrumb + continue.
       }
   }
   ```
   Model the request exactly on `getJSON` (`:1759`) but `httpMethod = "POST"`,
   set `Content-Type`, and encode the body. The `credential` field is a JSON
   **object**, so build the body as `Data` via `JSONSerialization` or an
   `Encodable` wrapper whose `credential` is `OAuthCredential` (NOT a string).
   Watch the encoding: `encodeCredentialAsJSONString` (`:3371`) emits the native
   blob as a STRING; for the HTTP body you want that same blob as a nested JSON
   object. Simplest correct path: `JSONSerialization.jsonObject(with:)` on the
   encoded string's UTF-8, then put the resulting object under `"credential"`.

2. **Call sites** (after the box's WS connect succeeds, using THAT box's
   endpoint/token):
   - `connectBox(_:)` — inside the `Task` success branch after
     `try await newClient.connect(...)` succeeds and `conn.harness = .linked`
     (`SessionStore.swift:1226`). Use `server.endpoint`.
   - `selectSavedServer(_:autoConnect:)` (`:2254`) — when it switches the active
     endpoint / connects, propagate to the newly-selected `endpoint`.
   - `reconnect()` (`:1533`) — after a successful reconnect, propagate to the
     current `endpoint` (a box that rotated/lost its `.enc` re-receives it).
   - Keep the existing `replayStoredAgentCredentials()` call in `createSession`
     (`:2487`) as a belt-and-suspenders for the active box; it's harmless if the
     HTTP propagate already ran.

   These are `async`; fire them in the existing `Task { … }` connect closures.
   Best-effort — never block or fail the connect on a propagate error.

### B. Per-box accounts status (drive from per-box readiness)

`ConduitAgentLoginSheet.swift` `signedInProviders` (`:138`) reads only
`OAuthCredentialStore.load` (device-local) → it lies ("signed in" when the box
doesn't have the cred). Replace/augment with per-box readiness:

- The ACTIVE box is authoritative via `brokerReadiness` (`SessionStore.swift:1638`,
  refreshed against `self.endpoint` at `:1693`). Use
  `brokerReadiness.agents[name].signedIn` (`AgentReadiness.signedIn`,
  `SessionStore.swift:383`) for the connected box.
- OTHER token-paired boxes: probe `GET /api/capabilities` per box via the
  existing `getJSON(endpoint:path:)` (`:1759`) — same pattern as
  `fetchBoxFeatures` (`:1714`) — and read `readiness.agents.<name>.signed_in`.
  Decode the readiness sub-object you already model as `AgentReadiness`.
- SSH / loopback boxes are NOT directly dialable when not tunnelled
  (`connectBox` skips them at `:1209`); their status is **unknown** — render a
  neutral "unknown" state, never a false "signed in".
- Map: device-credential present = "available to push"; box readiness
  `signed_in` = "present on this box". Show the provider × box matrix honestly.

### C. Per-box sign-out

Settings "Manage" → "Sign out" (`ConduitSettingsView.swift:134`) today only calls
`OAuthCredentialStore.clear` (device keychain) — no broker call. Add a per-box
action that calls the new clear endpoint:

- New `SessionStore` method `clearAgentCredential(provider:on endpoint:)` that
  `POST`s `/api/agent/credentials/clear` with `{"provider": provider.rawValue}`
  (same request shape as the propagate POST, different path, body has no
  `credential`). Best-effort; 200 even when nothing was stored.
- Wire it into the per-box management UI with the honest label "Remove pushed
  credential from this box". Keep the existing device-keychain
  `OAuthCredentialStore.clear` as a SEPARATE "Remove from this phone" action —
  they are different scopes.
- After a successful clear, refresh that box's readiness so the status flips.

### D. 401 handling (string-match fallback this round)

The claude 401 arrives as plain assistant chat text (broker `claudechat.go:147`,
no structured signal — the typed `agent_auth_required` view_event was deliberately
NOT built broker-side this round; see follow-up below). For now:

- At chat ingest, string-match assistant text for `API Error: 401` /
  `Failed to authenticate` (the live wording). On a hit for the active session's
  provider, trigger an auto-recover: call
  `propagateStoredAgentCredentials(to: endpoint)` (if a device credential
  exists) and surface a retry; if no device credential, preselect the
  `AgentLoginSheet` (`ConduitAgentLoginSheet.swift:34-36`).
- Keep this match narrow and provider-attributed to avoid false positives on
  benign chat text mentioning "401".

---

## Android

### A. Add `replayStoredAgentCredentials` + auto-propagate on connect

Android has NO replay at all today — credentials are only pushed at sign-in
(`AgentLoginSheet.kt:125`). The existing push, `sendAgentCredentials(credential)`
(`SessionStore.kt:863`), routes through `client.setAgentCredentials` over a live
session WS (same live-session limitation as iOS).

1. **New session-less HTTP method** on `SessionStore`, modeled on
   `getJsonOrNull(endpoint:path:)` (`SessionStore.kt:3226`) but POST:
   ```kotlin
   /** Push every stored agent credential to a box over HTTP
    *  (POST /api/agent/credentials), independent of any session. */
   suspend fun propagateStoredAgentCredentials(endpoint: Endpoint) = withContext(Dispatchers.IO) {
       val base = endpoint.httpBaseUrl ?: return@withContext
       for (provider in listOf(OAuthProvider.OPENAI, OAuthProvider.ANTHROPIC)) {
           val cred = OAuthStore.load(provider) ?: continue
           // open HttpURLConnection to base + "/api/agent/credentials"
           // requestMethod = "POST"; setRequestProperty("Authorization","Bearer ${endpoint.token}")
           // setRequestProperty("Content-Type","application/json"); doOutput = true
           // body: {"provider": provider.raw, "kind":"oauth", "credential": <cred.toJson() as RAW JSON object>}
           //   cred.toJson() (OAuthCredential.toJson, used at SessionStore.kt:870) is the native blob;
           //   inject it as a JSON value, not a quoted string.
           // breadcrumb + swallow non-2xx (503 = old broker).
       }
   }
   ```
   Reuse the exact `HttpURLConnection` + bearer pattern from
   `resolveApproval` (`:634-643`) / `getJsonOrNull` (`:3226-3231`).

2. **Call sites** (after a successful connect, with that box's `Endpoint`):
   - `connect()` (`SessionStore.kt:1361`) and `connectAndStart(...)`
     (`:1278` and `:1897`) success paths.
   - `reconnect()` (`:1423`).
   - `selectSavedServer(serverId, autoConnect)` (`:1229`) when it connects.
   - `connectViaSSH(...)` (`:1652`) success path (SSH box gets creds the moment
     the tunnel is live).
   - Also call from `createSession(...)` (`:2103`) success for parity with iOS's
     belt-and-suspenders.

   Fire-and-forget in the existing coroutine scopes; never fail the connect on a
   propagate error.

### B. Per-box accounts status

`AgentLoginSheet.kt` status (`:104-106`, readiness at `:102`) and
`SettingsScreen.kt:613` read device-local `OAuthStore`. Drive status from
per-box readiness instead:

- Active box: the readiness already parsed from `/api/capabilities`
  (`SessionStore.kt:3090` block, fetch at `:3106`) — read
  `agents.<name>.signed_in`.
- Other token boxes: probe via `fetchBoxFeatures` sibling — call
  `getJsonOrNull(endpoint, "/api/capabilities")` (`:3226`) per box and decode the
  readiness `agents.<name>.signed_in`.
- SSH boxes not tunnelled → unknown; render neutral, never false "signed in".

### C. Per-box sign-out

`SettingsScreen.kt:613` → `OAuthStore.clear` (`OAuthStore.kt:52`) is device-only.
Add a `SessionStore.clearAgentCredential(provider, endpoint)` that POSTs
`/api/agent/credentials/clear` (same HTTP shape as the propagate POST, no
`credential` field). UI label: "Remove pushed credential from this box". Keep
`OAuthStore.clear` as the separate "Remove from this phone" action. Refresh that
box's readiness after clearing.

### D. 401 handling (string-match fallback)

Same as iOS: at chat ingest in `SessionStore.kt`, string-match assistant text for
`API Error: 401` / `Failed to authenticate`, attribute to the session's provider,
auto-recover by calling `propagateStoredAgentCredentials(endpoint)` (if a stored
credential exists) + retry, else open `AgentLoginSheet`.

---

## Follow-up (NOT in this round): typed 401 view_event

Broker-side, classify a claude/codex auth-failure `result` in `claudechat.go`
(processClaudeStreamOutput, ~`:147`, plus the codex equivalent) and emit a typed
`view_event { agent_auth_required: { provider } }` so apps auto-recover without
string-matching. Deferred because the 401 currently surfaces as normal
assistant text and classifying it cleanly (without false positives on legit chat
content mentioning auth errors) needs the exact `is_error`/`subtype` shape of a
real auth-failure result captured live first. When built, apps route it near
`routeAgentLoginViewEvent` (iOS `SessionStore.swift:3420`) → push stored cred +
retry, and the string-match fallback above becomes belt-and-suspenders.
