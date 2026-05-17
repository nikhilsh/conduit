# WebSocket protocol (frozen contract v1)

Wire format between `swe-kitty-harness` (Go) and `swe-kitty-core` (Rust). **Byte-identical** to upstream [swe-swe](https://github.com/choonkeat/swe-swe)'s protocol so that swe-swe's own browser UI also works against our server. swe-kitty extends the JSON control set with `switch_agent`, `view_event`, and `health` fields — extensions are forward-compatible because the swe-swe client ignores unknown JSON types.

Changes to this document REQUIRE a deliberate PR that rebases all in-flight feature branches.

## 1. Endpoint

```
GET /ws/{session-uuid}?assistant={claude|codex|…}
Authorization: Bearer <token>
Upgrade: websocket
```

- `{session-uuid}` is a v4 UUID. Unknown UUID → server creates a new session.
- `assistant` query param is **only honored on session creation**. For existing sessions it is ignored (use `switch_agent` JSON message to swap mid-session).
- Bearer token is validated against the harness's token table (printed as QR on `swe-kitty-harness up`).

## 2. Frame types

WebSocket frames split into two categories.

### 2.1 Binary frames

Binary frames are length-prefixed by the WebSocket layer itself; the first byte of the payload is the **type tag**.

| Tag | Direction | Meaning | Payload after tag |
|---|---|---|---|
| `0x00` | client → server | Terminal resize | 2 bytes BE `rows` + 2 bytes BE `cols` |
| `0x01` | client → server | File upload | 2 bytes BE `name_len`, `name_len` UTF-8 bytes of filename, then file bytes |
| `0x02` | server → client | Gzip-compressed snapshot chunk | 2 bytes BE `chunk_idx` + 2 bytes BE `chunk_total` + gzip bytes |
| any other first byte | server ↔ client | Raw PTY I/O | the entire payload is PTY bytes |

Notes:
- Snapshots are chunked because iOS Safari (and some WKWebView builds) cap individual WebSocket message size aggressively. Reassembly: concatenate by `chunk_idx`, gunzip the result.
- Filenames are sanitized server-side (no `..`, no absolute paths) and stored under `.swe-kitty/sessions/<uuid>/uploads/`.
- Raw PTY I/O has no tag because matching against tag bytes that happen to appear at byte 0 of a PTY chunk is acceptable: the harness reserves `0x00`, `0x01`, `0x02` as forbidden first bytes for PTY frames — if a PTY chunk would start with one, the harness prefixes a single `0xFF` escape byte; the client strips a leading `0xFF` from raw frames. (Implementations: in practice this only matters at the boundary of NUL/SOH/STX bytes which are rare in interactive shells. Test fixture covers it.)

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
  "preview": { "port": 3001, "url": "/preview/<uuid>/" }
}
```

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
```

Unknown `type` values are logged and ignored — never close the socket for them. This keeps the protocol forward-extensible.

## 4. Lifecycle

### 4.1 New session
1. Client opens `GET /ws/<new-uuid>?assistant=claude`.
2. Server creates worktree + Docker container + PTY (per `docs/SESSION-LIFECYCLE.md`).
3. Server sends a `status` frame.
4. Server starts forwarding PTY bytes as raw binary frames.

### 4.2 Joining existing session
1. Client opens `GET /ws/<existing-uuid>` (assistant param ignored).
2. Server sends `status`, then a chunked gzip **snapshot** (type tag `0x02`) of current scrollback.
3. After last chunk, server resumes live PTY forwarding.

### 4.3 Heartbeat
Either side may send `{"type":"ping"}`; the peer replies `{"type":"pong"}`. Default cadence 30s. If a client misses two consecutive pings, server marks the connection idle but keeps the session running.

### 4.4 Disconnect
Closing the socket does NOT stop the session. Sessions live until an explicit `{"type":"exit"}` from a client or until the harness is told to drop them.

## 5. Forbidden in v1

- Server-initiated socket close other than for: bearer-auth failure, malformed binary tag, oversize file upload (>50MB).
- Out-of-order chunks: chunks must arrive in `chunk_idx` order. Out-of-order is a protocol error and the client may discard the snapshot and request a fresh one by reconnecting.
- Renegotiating `assistant` via the query string mid-session — must use `switch_agent`.

## 6. Conformance tests

`harness/internal/ws/conformance_test.go` (task 001) holds the canonical wire-level fixtures. Any client implementation (including the Rust core) must pass them.
