---
title: Per-box credential model
tags: [credentials, broker, auth, ios, android, oauth]
scope: repo
source: per-box-credential-model
status: active
---

# Per-box credential model

## Model

Agent credentials (Anthropic/OpenAI OAuth tokens) are stored on the PHONE
(Keychain on iOS, `EncryptedSharedPreferences` on Android) but the broker holds
them PER-BOX, keyed by the box's bearer identity, encrypted at rest under
`~/.conduit/credentials/<sha256(idsalt)>/<provider>.enc`.

A box connected AFTER sign-in never receives the credential automatically. The
device-global "signed in" label in the app's accounts sheet was a lie about
remote boxes — it reported only local Keychain/Prefs state.

## Fix (v0.0.152)

The apps now AUTO-PROPAGATE on every box-connect success: on `connect()` /
`connectBox()` they POST every stored credential to the connecting box.

**Endpoint:**
```
POST /api/agent/credentials
Authorization: Bearer <box token>
{
  "provider": "anthropic" | "openai",
  "kind": "oauth",
  "credential": { ...native blob as a JSON object, NOT a stringified blob... }
}
→ 200 {"stored":true,"provider":"..."}
→ 400 unknown_provider | unsupported_kind | empty_credential | invalid_request
→ 401 bad/missing bearer
→ 503 credentials_unavailable (old broker without credentials store)
```

A 401-string-match safety net in the apps re-pushes mid-session if a session
returns `Failed to authenticate. API Error: 401`.

**Broker readiness:** `GET /api/capabilities` → `readiness.agents.<name>.signed_in`
is true when `credentials.Store.Has(provider)`, so an auto-propagated box
reports signed-in correctly without requiring a host-login file
(`~/.claude/.credentials.json` / `~/.codex/auth.json`).

## Clearing credentials

`POST /api/agent/credentials/clear` (HTTP) + WS `clear_agent_credentials{provider}`
removes ONLY the app-pushed `.enc` file. It CANNOT revoke the box owner's
host-shell login. The UI must say "Remove pushed credential from this box",
NOT "Sign out of this box" — the distinction matters for shared/hosted boxes.

## Per-box status feasibility

`brokerReadiness` is authoritative for the CURRENTLY CONNECTED box only. Other
token-paired boxes can be queried via `GET /api/capabilities` with their token;
SSH/loopback boxes are unknown unless tunneled.

## Wire format details

The full app-side implementation spec is in `docs/PLAN-credential-propagate.md`.
The broker wire-format (WebSocket messages, endpoint schemas) is covered in
`docs/WEBSOCKET-PROTOCOL.md`.

Related: [BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md),
[SSH-BOOTSTRAP-FOOTGUNS](SSH-BOOTSTRAP-FOOTGUNS.md)
