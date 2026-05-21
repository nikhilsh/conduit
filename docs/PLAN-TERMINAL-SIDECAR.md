# Stage G — Server-side xterm.js headless grid (terminal sidecar)

## Problem

The iOS client renders the terminal with xterm.js inside a WKWebView
(Stage F'). Live PTY bytes stream over the WebSocket and are written
into the local xterm.js instance, which renders them correctly at the
client's actual viewport size.

The bug shows up on (re)attach. When a client connects to an existing
session, the broker ships its `Session.Snapshot()` — a copy of the
last 256 KB of raw PTY output from `session.ring`. Those bytes were
emitted by the agent at whatever `rows × cols` the PTY was at when they
were written. They contain absolute cursor positioning (`CSI H`), line
wraps at the old column count, alt-screen toggles (`CSI ?1049h`), and
DEC private mode state. Replaying them into an xterm.js instance whose
viewport has different dimensions yields visibly wrong output: URLs
wrap at the old column, cursor lands in the wrong place, TUI status
lines smear.

This is not a bug a client-side xterm.js can fix on its own. The bytes
are not size-portable.

## Fix (this stage)

Keep the terminal grid on the SERVER, using the headless build of the
same xterm.js engine the client renders with. On attach, the server
reflows the grid to the client's size and serializes it via
`@xterm/addon-serialize`. The serialized payload is byte-for-byte safe
to feed back into the client's xterm.js — same parser, same line-wrap
algorithm, same DEC state machine.

Tabby-Web, ttyd, Hyper-Cloud all use this pattern. We do it via a Node
subprocess so we don't have to embed a JS engine in the Go broker.

## Architecture

```
              ┌────────────────────────┐
   PTY bytes  │ broker/session.go     │
   ──────────►│   ring (256 KB)        │ ← streaming source of truth
              │   PTY drain loop       │
              └─────┬──────────────────┘
                    │ mirror chunks
                    ▼
              ┌────────────────────────┐    ┌───────────────────────┐
              │ termgrid.Manager (Go)  │◄───┤ Node sidecar          │
              │   stdin/stdout JSON-RPC│    │  @xterm/headless      │
              │                        │───►│  one Terminal per sid │
              └─────┬──────────────────┘    │  + SerializeAddon     │
                    │                       └───────────────────────┘
                    │ on attach: Resize(sid, rows, cols)
                    │            then Serialize(sid)
                    ▼
              ┌────────────────────────┐
              │ ws/server.go           │
              │   sendSnapshot(snap)   │
              └────────────────────────┘
                    │
                    ▼
                  client xterm.js
                  (same engine!)
```

The Go ring buffer remains the streaming source of truth for live
output (cheap, allocation-free, doesn't cross the process boundary).
The sidecar is consulted only on attach for size-correct snapshots.

## Protocol

Line-delimited JSON over the sidecar's stdin/stdout. Each request is
one JSON object; each response is one JSON object.

### Request envelope

```json
{ "id": <uint64>, "cmd": "<verb>", ...fields }
```

### Response envelope

```json
{ "id": <same>, "ok": true,  ...fields }
{ "id": <same>, "ok": false, "error": "<string>" }
```

### Verbs

| cmd         | fields                       | response fields                |
|-------------|------------------------------|--------------------------------|
| `create`    | `sid, cols, rows`            | —                              |
| `write`     | `sid, b64`                   | — (ack after grid applied)     |
| `resize`    | `sid, cols, rows`            | —                              |
| `serialize` | `sid`                        | `data: "<ANSI string>"`        |
| `delete`    | `sid`                        | —                              |
| `ping`      | —                            | `pong: <epoch_ms>`             |

`write` acks AFTER the bytes are applied to the grid (xterm.js's write
queue is drained via its callback). `serialize` likewise drains via an
empty enqueued write so the response sees everything the caller wrote
before it.

Unknown `cmd` → `{ok: false, error: "unknown_cmd"}`. Bad JSON is
logged to stderr and dropped — the sidecar does not crash on a bad
line.

## Go side (`broker/internal/termgrid`)

`Manager` owns the long-running sidecar subprocess and a pending-request
map keyed by `id`. A background goroutine consumes the sidecar's
stdout and dispatches responses by id. All RPCs use a 5-second
context timeout; on timeout the caller gets `ErrTimeout` and the
broker falls back to ring-based snapshots.

If `node` isn't on PATH at startup, `termgrid.NewManager()` returns
`termgrid.ErrNoNode` and the session.Manager continues with
`termgrid = nil`. Every termgrid use site checks for nil first.

## Snapshot path

`session.Session` now exposes two methods:

- `Snapshot() []byte` — unchanged; returns the raw ring contents
  (used by the memory-html writer, tests, and as the universal
  fallback).
- `SnapshotForSize(rows, cols uint16) []byte` — new; reflows the
  headless grid to `(rows, cols)` then serializes. Falls back to
  `Snapshot()` if the sidecar is nil, errors, or returns empty.

The WS server prefers `SnapshotForSize` and supplies dimensions in
this order:

1. `rows`/`cols` URL query params (mobile clients pass them on
   connect).
2. The session's current PTY size (still useful because the headless
   grid serialization is more portable than raw PTY bytes).

If the client's first 0x00 resize frame after connect disagrees with
the size used for the initial snapshot, the server re-emits a fresh
snapshot reflowed to the new dimensions. This costs one extra
`Resize + Serialize` round-trip (~5 ms in practice) and only happens
once per attach.

## Failure modes & fallbacks

| Symptom                        | Behavior                                                     |
|--------------------------------|--------------------------------------------------------------|
| `node` not on PATH             | Log once; sessions run with `termgrid=nil`; snapshots = ring |
| Sidecar fails to spawn         | Same as above                                                |
| Sidecar crashes mid-session    | Pending RPCs fail; subsequent calls return `ErrClosed`; ring snapshot fallback in effect for that session lifetime (Go does NOT auto-restart yet — deferred) |
| RPC times out (5s)             | That call returns `ErrTimeout`; caller falls back to ring   |
| `serialize` returns empty      | Treat as failure; ring fallback                              |
| Network split (client gone)    | No effect — the sidecar only talks to Go                     |

## What's deferred

- **Auto-respawn**: if the sidecar dies mid-session, the broker keeps
  running but loses size-correct snapshots until the broker itself
  restarts. A future stage should auto-respawn the sidecar and rebuild
  per-session grids from the ring.
- **Persistent grid across broker restarts**: each cold start
  re-creates an empty grid in the sidecar. The grid gets the
  persisted ring replayed once at recovery time (which seeds it), but
  scrollback older than the ring is gone.
- **Multi-client reflow**: if two clients attach at different sizes,
  whichever resized last wins. A proper fix would pick smallest-common
  dimensions or keep per-client grids.
- **Detaching scrollback from the live grid**: xterm.js scrollback is
  capped at 10000 lines on both sides. Larger scrollback would need a
  separate ANSI-aware paging layer.
- **Bundle Node binary**: today we require Node 20+ on the host. A
  future cleanup could bundle a pinned Node binary alongside the
  broker so install.sh has zero runtime deps.

## Runtime requirement

Node.js **20+** on the host that runs the broker. `install.sh` warns
if Node is missing or older.
