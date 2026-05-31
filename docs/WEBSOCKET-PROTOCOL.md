# WebSocket protocol (frozen contract v1)

Wire format between `conduit-broker` (Go) and `conduit-core` (Rust). The binary framing was originally adopted from [choonkeat/swe-swe](https://github.com/choonkeat/swe-swe), but conduit has since added `switch_agent`, typed `view_event`, structured `health` / `phase` fields, and a **bearer-only auth path** (no cookie redirect to `/swe-swe-auth/login`). Treat the upstream as historical prior art, not as a compatibility target — pointing the Conduit client at an unmodified `swe-swe` server fails the WS upgrade because the auth redirect lands on an HTML login page.

Changes to this document REQUIRE a deliberate PR that rebases all in-flight feature branches.

## 1. Endpoint

```
GET /ws/{session-uuid}?assistant={claude|codex|…}&cwd={absolute-path}
GET /api/capabilities
GET /api/fs/list?path=/abs/path&limit=100&offset=0&include_hidden=false
POST /api/session/start
GET /api/recent-projects?limit=20
Authorization: Bearer <token>
Upgrade: websocket
```

- `{session-uuid}` is a v4 UUID. Unknown UUID → server creates a new session.
- `assistant` query param is **only honored on session creation**. For existing sessions it is ignored (use `switch_agent` JSON message to swap mid-session).
- Bearer token is validated against the broker's token table (printed as QR on `conduit-broker up`).

## 2. Frame types

WebSocket frames split into two categories.

### 2.1 Binary frames

Binary frames are length-prefixed by the WebSocket layer itself; the first byte of the payload is the **type tag**.

| Tag | Direction | Meaning | Payload after tag |
|---|---|---|---|
| `0x00` | client → server | Terminal resize | 2 bytes BE `rows` + 2 bytes BE `cols` |
| `0x01` | client → server | File upload (sweswe-parity #file-upload) | `u32 LE session_id_len` + session_id bytes + `u32 LE filename_len` + filename bytes + `u32 LE mime_len` + mime bytes + file bytes |
| `0x02` | server → client | Gzip-compressed snapshot chunk | 2 bytes BE `chunk_idx` + 2 bytes BE `chunk_total` + gzip bytes |
| any other first byte | server ↔ client | Raw PTY I/O | the entire payload is PTY bytes |

Notes:
- Snapshots are chunked because iOS Safari (and some WKWebView builds) cap individual WebSocket message size aggressively. Reassembly: concatenate by `chunk_idx`, gunzip the result.
- Filenames are sanitized server-side (no `..`, no absolute paths, no path separators) and stored under `<workspace>/uploads/<session_id>/<filename>`. The embedded `session_id` MUST match the WS path's bound session — mismatches are rejected with a `view_event { view: "chat", role: "tool" }` notification and dropped without closing the socket.
- Raw PTY I/O has no tag because matching against tag bytes that happen to appear at byte 0 of a PTY chunk is acceptable: the broker reserves `0x00`, `0x01`, `0x02` as forbidden first bytes for PTY frames — if a PTY chunk would start with one, the broker prefixes a single `0xFF` escape byte; the client strips a leading `0xFF` from raw frames. (Implementations: in practice this only matters at the boundary of NUL/SOH/STX bytes which are rare in interactive shells. Test fixture covers it.)

### 2.2 Text frames

Text frames are UTF-8 JSON objects with a `type` field.

## 3. JSON control messages

### 3.1 Universal envelope

```json
{ "type": "<name>", "ts": "2026-05-17T12:34:56.789Z", ...payload }
```

`ts` is optional on the client side; server stamps if absent.

### 3.2 Server → client

```json
{ "type": "status",
  "session": "<uuid>",
  "viewers": 1,
  "rows": 40, "cols": 120,
  "assistant": "claude",
  "session_name": "002-rust-core",
  "yolo": false,
  "health": "healthy" | "warning" | "dead",
  "phase": "running" | "swapping" | "stalled" | "exited",
  "reason_code": "ok",
  "preview": { "port": 3001, "url": "/preview/<uuid>/" },
  "reasoning_effort": "low" | "medium" | "high",
  "cwd": "/abs/path/to/agent/workdir",
  "started_at": "2026-05-21T08:00:00.000Z",
  "last_activity_at": "2026-05-21T09:12:34.500Z"
}
```

Field notes (post-#16 additions; all optional, older clients ignore unknown keys):
- `reasoning_effort` — per-agent label read from `agents/<name>.toml`'s `reasoning_effort` field. Falls back to `"medium"` when the toml didn't specify.
- `cwd` — absolute path of the agent's working directory (the broker's `workspaceDir`).
- `started_at` — RFC3339Nano timestamp of session construction (broker stamps once at `newSession`).
- `last_activity_at` — RFC3339Nano timestamp of the most recent PTY byte from the agent process.

The same four-field bundle is also re-emitted on the typed `view_event` channel as `view: "status"` (see below) — sweswe-parity multi-viewer surface. Two channels, one source of truth; clients pick whichever stream they already subscribe to.

```json
{ "type": "view_event",
  "session": "<uuid>",
  "view": "chat",
  "event": {
    "role": "assistant" | "user" | "tool",
    "content": "string",
    "ts": "ISO8601",
    "files": [{"path":"…","rev":"…"}]
  }
}
```

The `view: "chat"` shape is the agent's chat output. It is produced from each
agent's **structured** mode (claude stream-json, codex `exec --json`), not by
scraping the TUI — see [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md) for the per-agent
backends. `role: "tool"` events carry the structured tool payload the client's
conversation classifier renders as cards. (The legacy PTY scraper
`chatScraper` survives only as a fallback for adapters with no `chat_mode`.)

```json
{ "type": "view_event",
  "session": "<uuid>",
  "view": "status",
  "event": {
    "viewer_count": 2,
    "terminal_cols": 120,
    "terminal_rows": 40,
    "display_name": "002-rust-core"
  }
}
```

The `view: "status"` shape is reserved for **sweswe parity** — a typed mirror of the fields broadcast in the top-level `status` envelope (see §3.2), shipped through the same `view_event` channel so multi-viewer clients can subscribe without parsing the heterogeneous `status` frame. All four event fields are **optional**; older clients (and brokers) that don't emit them stay wire-compatible because unknown keys are ignored (§3.3). Field semantics:

- `viewer_count` — integer count of live WebSocket subscribers attached to the session right now. Mirrors `status.viewers`. Clients are expected to render a badge only when `viewer_count > 1` (one viewer is the local user; no point announcing yourself to yourself).
- `terminal_cols` / `terminal_rows` — current PTY dimensions in character cells. Mirrors `status.cols` / `status.rows`. Emitted whenever the broker resizes the PTY (after a `0x00` binary resize frame) so a late-joining viewer can immediately render scrollback at the right geometry without waiting for the next `status` envelope.
- `display_name` — human-readable session label. Mirrors `status.session_name`. Set by `rename_session` (§3.3) and persisted by the broker until the session exits.
- `agent_credentials_refreshed` — `{ "provider": "anthropic" | "openai" }`. Emitted exactly once per successful `set_agent_credentials` (§3.3) so the phone can confirm the credential blob landed in the broker's per-identity store. Optional; older clients ignore it. See [PLAN-AGENT-OAUTH.md](archive/PLAN-AGENT-OAUTH.md) §D for the broader refresh-broadcast contract — Stage 1 only ships the post-`set_agent_credentials` ack; the agent-driven refresh broadcast (inotify on the CLI's on-disk credential file) lands in a later stage.
- `agent_login_url` — `{ "provider": "openai" | "anthropic", "url": "<authorize-url>", "loopback_port": 1455, "session_token": "<hex>" }`. Emitted in response to a successful `start_agent_login` (§3.3). The phone opens `url` in `ASWebAuthenticationSession` / `CustomTabsIntent`, binds a tiny HTTP listener on `127.0.0.1:<loopback_port>` to catch the provider's redirect, then ships the captured query string back via `agent_login_callback`. `session_token` must round-trip verbatim — see [PLAN-AGENT-OAUTH.md](archive/PLAN-AGENT-OAUTH.md) "Approach v2".
- `agent_login_complete` — `{ "ok": true }`. Emitted after the broker successfully ferried the OAuth callback to the CLI and the CLI exited cleanly (token exchange complete + on-disk credential file written). The phone dismisses its login sheet.
- `agent_login_failed` — `{ "provider": "...", "reason": "human-readable" }`. Emitted on any v2 login error: unknown provider, CLI not on PATH, URL parse timeout, unknown `session_token` on callback, CLI exited non-zero. The phone surfaces `reason` and re-presents the login button.

```json
{ "type": "view_event",
  "session": "<uuid>",
  "view": "quick_replies",
  "event": {
    "session_id": "<uuid>",
    "replies": ["Yes, go ahead", "Show me the diff", "Run the tests"],
    "for_message_id": "<ts-of-assistant-message>"
  }
}
```

The `view: "quick_replies"` shape carries **AI-generated** contextual quick replies (task #233), replacing the apps' old client-side heuristic chips. When a Claude stream-json assistant turn finishes (the `result` envelope), the broker fires a **best-effort, async, non-blocking** one-shot `claude -p --model haiku` against the session's credentials and emits up to 4 short tap-able *user* replies for the turn's final assistant message. Field semantics:

- `replies` — array of ≤4 short strings. The apps render them as composer chips and clear them on send / when a new turn arrives. An empty/absent array means "no chips".
- `for_message_id` — the `ts` of the assistant message the chips were generated for, so a stale set can be dropped.
- `session_id` — echoes the bound session for symmetry with the envelope `session`.

Generation details and guarantees:
- **Never blocks the real turn**: runs in a goroutine with an 8s timeout; any error/timeout/malformed model output emits **nothing**.
- **Credential-race safe**: the interactive session and the one-shot share one ephemeral `$HOME`, so a concurrent OAuth refresh-token rotation on `.claude/.credentials.json` could race. The one-shot sidesteps this by running against a **throwaway temp-`$HOME` copy** of the session's `.claude` creds (removed after the call) — any refresh it does lands in the discardable copy, never the live session's token.
- **Config-gated**: on by default; `CONDUIT_AI_QUICKREPLIES=0` (or `false`/`off`/`no`) disables it entirely.
- **Claude-only**: codex / TUI-scrape sessions cleanly no-op (no chips from the broker; the apps fall back to the local heuristic).
- Core passes this through `on_view_event(session_id, "quick_replies", { replies: "<json-array-string>", for_message_id })` — the typed `record<string,string>` delegate, so `replies` is JSON-encoded as a string the apps decode. No UDL change.

```json
{ "type": "exit", "session": "<uuid>", "code": 0 }
```

```json
{ "type": "chat", "session": "<uuid>", "from": "username", "msg": "..." }
```
(Multi-user session chat, separate from `view_event` agent chat.)

### 3.3 Client → server

```json
{ "type": "ping" }                            // 30s heartbeat; server responds {"type":"pong"}
{ "type": "rename_session", "name": "…" }      // ≤32 chars, [A-Za-z0-9 _-]+
{ "type": "toggle_yolo" }                      // restart agent with autonomous flag
{ "type": "switch_agent", "assistant": "codex" } // atomic agent swap; see SESSION-LIFECYCLE.md
{ "type": "exit" }                             // request session shutdown
{ "type": "chat", "from": "username", "msg": "..." }
{ "type": "set_agent_credentials",
  "provider": "anthropic" | "openai",
  "kind": "oauth",
  "credential": { /* provider-native JSON; see archive/PLAN-AGENT-OAUTH.md §D */ } }
```

`rename_session` notes (sweswe parity):
- `name` is validated server-side against `^[A-Za-z0-9 _-]{1,32}$`. Whitespace-only strings, empty strings, and strings >32 chars are rejected silently (the broker logs and ignores; the socket stays open — see §3.3 forward-extensibility rule).
- On a successful rename the broker persists the label, then broadcasts an updated `status` envelope (`session_name` + the `view: "status"` mirror's `display_name`) to **all** viewers of that session. The rename is durable across reconnects: the next `status` frame the client receives after a fresh WS attach will carry the new label.
- Renames are last-writer-wins. The broker does not stamp authorship and does not return an ack — clients should treat the broadcast `status` as the source of truth and avoid optimistic local mutation.

`chat` notes:
- For structured-mode agents (the default — see [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md))
  the composer message is written to the agent's stdin as a structured input
  event; the reply comes back as `view_event { view: "chat" }`. The Terminal tab
  is a separate bash shell.
- On the legacy fallback path (adapters with no `chat_mode`), the broker writes
  `msg + "\r"` (CR) into the agent's PTY stdin and the scraper lifts the reply
  back out — fragile, retained only for agents without a structured mode.

`set_agent_credentials` notes (Stage 1 of [PLAN-AGENT-OAUTH.md](archive/PLAN-AGENT-OAUTH.md)):
- `provider` must be `"anthropic"` or `"openai"`. Anything else is rejected with a `view_event { view: "chat", role: "tool", tool_name: "set_agent_credentials" }` carrying a human-readable reason; the socket stays open.
- `kind` is `"oauth"` for now. The field is required so a future protocol rev that adds `"api_key"` / `"signed_jwt"` etc. doesn't have to thread an explicit version bump.
- `credential` is the **provider-native** OAuth blob — for `anthropic` the `claudeAiOauth` object the `claude` CLI writes to `~/.claude/.credentials.json`; for `openai` the `AuthDotJson` shape the `codex` CLI writes to `~/.codex/auth.json`. The broker stores it verbatim (no normalization) so additive vendor changes survive round-trip without code changes.
- The WS upgrade is already bearer-gated, so the handler doesn't recheck auth — but a broker started **without** a configured credentials store (no `--credentials-dir`) replies with a chat-tool error rather than silently dropping the blob, so the phone learns the per-user OAuth path isn't enabled on this server.
- On success, the broker emits a typed `view_event { view: "status", event: { agent_credentials_refreshed: { provider } } }` so the phone learns the credential landed without needing a separate ack channel. This piggybacks on the existing `view: "status"` mirror so multi-viewer surfaces stay consistent.
- The encrypted credential is keyed by **a hash of the broker's bearer token**, not per-session — subsequent sessions started by the same phone reuse the stored credential. The broker materializes it into a per-session ephemeral `$HOME` (with `CODEX_HOME` set for codex) at session spawn time; missing-credential sessions fall back to the legacy host-mirror behaviour exactly as before.

`set_agent_credentials` is **deprecated** in favour of the v2 server-side login flow below. v1 PRs (#100, #104, #110, #112) shipped the wire but both providers reject the phone-generated `conduit://` custom-scheme redirect URI at the authorize endpoint, so the existing path is dead code. Stage 4 of [PLAN-AGENT-OAUTH.md](archive/PLAN-AGENT-OAUTH.md) removes it.

#### v2 agent-login control messages

```json
{ "type": "start_agent_login",
  "provider": "openai" | "anthropic" }
{ "type": "agent_login_callback",
  "session_token": "<broker-issued>",
  "query_string": "code=...&state=..." }
{ "type": "cancel_agent_login",
  "session_token": "<broker-issued>" }
```

`start_agent_login` notes (archive/PLAN-AGENT-OAUTH.md "Approach v2"):
- The broker spawns the CLI's own login subcommand on the broker host — `codex login` for `openai`, `claude auth login --claudeai` for `anthropic`. The CLI binds its own loopback HTTP listener (`http://127.0.0.1:1455/auth/callback` by default, fallback `1457`) and prints the authorize URL on stdout. The broker parses the URL out of stdout and emits a typed `view_event { view: "status", event: { agent_login_url: { provider, url, loopback_port, session_token } } }` so the phone can open `url` in `ASWebAuthenticationSession` (iOS) / `CustomTabsIntent` (Android).
- The `session_token` is a broker-minted 32-byte hex string that scopes the subsequent `agent_login_callback`. The phone must echo it back verbatim; the broker rejects callbacks whose token doesn't match an active session. This is the confused-deputy mitigation for shared brokers where multiple paired identities could otherwise race callback delivery.
- `loopback_port` is `0` when the provider's CLI doesn't use a loopback (Anthropic's code-paste flow may fall into this category — pending Stage 2 verification, see PLAN §K). In that case the phone presents a "paste your code" affordance after the browser closes, and ships the code back via a future `agent_login_code` message.
- Failure cases (CLI not on PATH, URL parse timeout, unknown provider, broker not built with OAuth manager) emit `view_event { view: "status", event: { agent_login_failed: { provider, reason } } }` with a human-readable `reason`. The socket stays open.

`agent_login_callback` notes:
- Sent by the phone immediately after its local loopback HTTP server (bound to `127.0.0.1:<loopback_port>` on the device) captures the OAuth provider's redirect. The phone parses the query string out of the GET request and ships it back over WS.
- The broker forwards `query_string` to the still-running CLI subprocess's loopback by `GET http://127.0.0.1:<loopback_port><callback_path>?<query_string>` on its own host. The CLI sees this exactly as it would a browser-side redirect on the same machine, completes the token exchange, and writes the on-disk credential file (`~/.codex/auth.json` or `~/.claude/.credentials.json`) before exiting.
- On the CLI exiting successfully, the broker emits `view_event { view: "status", event: { agent_login_complete: { ok: true } } }`. On any error (CLI not listening, unknown token, network failure, CLI exited non-zero), emits `agent_login_failed` with `reason` instead.

`cancel_agent_login` notes:
- Used when the phone aborts (user dismissed the sheet, browser timed out). The broker kills the CLI subprocess so a stale loopback isn't left bound. Silent no-op when the token is unknown — the WS read loop doesn't error.

Unknown `type` values are logged and ignored — never close the socket for them. This keeps the protocol forward-extensible.

## 4. Lifecycle

### 4.1 New session
1. Client opens `GET /ws/<new-uuid>?assistant=claude&cwd=/abs/path` (optional `cwd` only on create).
2. Server creates worktree + agent process + PTY (per `docs/SESSION-LIFECYCLE.md`).
3. Server sends a `status` frame.
4. Server starts forwarding PTY bytes as raw binary frames.

### 4.2 Joining existing session
1. Client opens `GET /ws/<existing-uuid>` (assistant param ignored).
2. Server sends `status`, then a chunked gzip **snapshot** (type tag `0x02`) of current scrollback.
3. After last chunk, server resumes live PTY forwarding.

### 4.3 Heartbeat
Either side may send `{"type":"ping"}`; the peer replies `{"type":"pong"}`. Default cadence 30s. If a client misses two consecutive pings, server marks the connection idle but keeps the session running.

### 4.4 Disconnect
Closing the socket does NOT stop the session. Sessions live until an explicit `{"type":"exit"}` from a client or until the broker is told to drop them.

## 5. Forbidden in v1

- Server-initiated socket close other than for: bearer-auth failure, malformed binary tag, oversize file upload (>50MB).
- Out-of-order chunks: chunks must arrive in `chunk_idx` order. Out-of-order is a protocol error and the client may discard the snapshot and request a fresh one by reconnecting.
- Renegotiating `assistant` via the query string mid-session — must use `switch_agent`.

## 6. Conformance tests

`broker/internal/ws/conformance_test.go` (task 001) holds the canonical wire-level fixtures. Any client implementation (including the Rust core) must pass them.
### HTTP helper endpoints (mobile bootstrap)

- `GET /api/capabilities` returns machine-readable server feature flags and assistant list.
- `GET /api/fs/list` returns directory-only children with metadata and pagination.
- `POST /api/session/start` accepts `{session_id?, assistant?, cwd?}` and returns `{session_id, assistant, ws_path, created}`.
- `GET /api/recent-projects` returns most-recent workspace paths for cross-device continuity.
- Error responses are JSON: `{"error":{"code":"...","message":"..."}}`.

Status/exit payloads include machine-readable `reason_code` (examples: `ok`, `agent_switched`, `agent_switch_in_progress`, `process_exited`, `session_closed`).

### Health endpoints

- `GET /health` — soft liveness. Returns `200 ok\n` as long as the broker process is responding. Trivial; kept for backwards-compat curl scripts.
- `GET /healthz` — strict liveness (added in #26). Returns JSON `{live, sidecar_expected, sidecar_healthy, sidecar_error?}`. **503** when the Node sidecar was expected at startup but isn't answering its 5s Ping; 200 otherwise. Wire into systemd `Restart=on-failure` or LB health checks — silent sidecar crashes now surface as a degraded health status instead of garbled terminal snapshots.
