# PLAN: SSH Chat Takeover (`conduit-broker chat <session-id>`)

Status: design only. No code in this PR.

Let the owner, while SSH'd into the broker box, **see the live Conduit chat for
a session and take it over** from a terminal: read the structured agent
conversation (the phone's "Chat tab" — user/assistant/tool messages +
AskUserQuestion prompts), send new messages into the **same running session**,
answer AskUserQuestion, and optionally interrupt — all over the broker's
localhost APIs. This is the **chat** surface, not the raw PTY/terminal-grid
mirror. No winsize/reflow concerns apply.

---

## 1. Goal + non-goals

### Goal
A `conduit-broker chat <session-id>` subcommand that, run on the broker box:
1. Loads chat history from the existing REST transcript endpoint.
2. Opens the existing `/ws/<id>` socket as just another subscriber.
3. Tails live chat (`view_event` `view:"chat"`) and status frames, rendering
   chat / tool / AskUserQuestion events to the terminal.
4. Sends new chat messages into the same running session.
5. Answers an outstanding AskUserQuestion by typing a reply (same mechanism the
   phone uses — a plain chat message routed through `SendChat`).
6. Optionally interrupts the current turn (`stop`).

### Non-goals (explicit)
- **Not PTY co-drive.** The CLI does not subscribe to or render the raw
  terminal grid, does not send resize frames, and does not write raw bytes to
  the agent PTY. It uses only the structured chat channel. The binary PTY sub
  (`Subscribe()`) exists on the WS handler but the chat CLI deliberately ignores
  those frames.
- **Not a new `claude --resume` process.** It does **not** spawn a fresh agent
  CLI. It attaches to the already-running session via the broker's localhost WS
  + REST, so the agent's credentials, agent-home, MCP config, and conversation
  state are untouched. There is exactly one agent process; the SSH CLI is a
  second *client* of it, identical in kind to the phone.
- **Not a new auth surface.** It reuses the existing bearer token and the
  existing endpoints. No new HTTP routes, no new WS message types (sends reuse
  `chat` / `stop`).
- **Not multi-session.** One invocation attaches to one session id. `--list`
  (or no id) just prints the session list and exits.

The entire value proposition is: a terminal client that is **wire-identical to
the phone** on the chat channel, so it inherits dedup, ack, AskUserQuestion
bridging, self-heal, and transcript persistence for free. The only thing that
is *not* free — and the one real regression — is the push-suppression gate
(§3).

---

## 2. Architecture

### 2.1 Where it lives
New subcommand in the existing dispatch switch:
`broker/cmd/conduit-broker/main.go:60-74` (`up` / `memory` / `kb` today). Add
`case "chat": os.Exit(runChat(os.Args[2:]))` and a usage line at
`main.go:77-86`. The `kb` subcommand (`runKB`) is the structural template — a
self-contained `runChat([]string) int` in a new file
`broker/cmd/conduit-broker/chat.go`.

The CLI is a **pure client**: it makes HTTP/WS calls to the already-running
broker on loopback. It does **not** import `internal/session` or
`internal/ws`; it talks the wire protocol like the phone. This keeps the new
backend-style surface tiny and avoids coupling the CLI to broker internals.

### 2.2 Endpoint + auth
- Broker base URL: default `http://127.0.0.1:1977` (matches the default listen
  addr, `main.go:97`). Allow `--addr`/`CONDUIT_BROKER_ADDR` override for a
  non-default port.
- Auth: every endpoint is bearer-gated via `Store.Check`
  (`broker/internal/auth/auth.go:65-71`), which accepts **either**
  `Authorization: Bearer <token>` **or** `?token=<token>` on the URL
  (`auth.go:66-69`). The WS handshake path (`server.go:373-376` →
  `requireAuth` → `Auth.Check`) takes the same.
- **Token source on the box:** the broker adopts `CONDUIT_TOKEN` at startup
  (`main.go:153-156`); the systemd unit pins it (see `docs/BROKER-REDEPLOY.md`,
  knowledge BROKER-OPS-FOOTGUNS). The CLI resolves the token in this order:
  1. `--token` flag,
  2. `CONDUIT_TOKEN` env (the same var the unit exports — works when the
     operator runs the CLI in an env that sources the unit's environment, or
     manually exports it),
  3. read it out of the systemd unit / drop-in environment as a documented
     fallback (e.g. `systemctl show -p Environment conduit-broker`), surfaced as
     a clear error message rather than auto-magic.

  Open question O-1 covers making this fully turnkey. The minimum viable
  behavior: require `CONDUIT_TOKEN` in the env or `--token`, and print a precise
  hint (the `systemctl show` one-liner) when absent.

### 2.3 Resolve / list sessions
`GET /api/sessions` → `serveSessions` (`broker/internal/ws/api.go:348-356`)
returns `{sessions, recoverable}` (live + recoverable). The CLI:
- with no id (or `--list`): print the list (id, assistant, display name, status)
  and exit 0.
- with an id: validate it appears in the list; if it is only *recoverable*
  (lazy, not spawned — `main.go:179-183`), warn that connecting will spawn it on
  open (the WS connect itself triggers `GetOrCreateWithOptions`,
  `server.go:403`).

### 2.4 Load history (REST), then tail (WS)
This mirrors the phone's contract exactly: **the broker does NOT replay chat
history on reattach** (`server.go:466-469`) — the client loads history from
REST/file, then tails live frames.

History: `GET /api/session/conversation/<id>?tail=N`
(`serveSessionConversation`, `api.go:394-419`). Returns
`{items:[{role,content,ts,files}], has_more_before, oldest_ts, latest_ts}`
(`sessionConversationResponse`, `api.go:371-376`; `ConvEntry`,
`broker/internal/session/convlog.go:16-21`). Backed by
`<sessionDir>/conversation.jsonl` on the local box
(`~/.conduit/sessions/<id>/conversation.jsonl`; convLog write path
`convlog.go:51-75`, manager wiring at `manager.go:240-245`).

Sequence to avoid a gap/dup at the seam:
1. `GET …/conversation/<id>?tail=N` → render items in order; remember
   `latest_ts`.
2. Open the WS (below) and begin buffering live `chat` frames.
3. Optionally re-poll `…/conversation/<id>?since_ts=<latest_ts>` once to fill
   any messages persisted between step 1 and the socket attaching, then start
   draining the live buffer. (Live `chat` frames carry the same
   `{role,content,ts}` shape, so dedup on `ts`+`content` is trivial. For a v1,
   accept a tiny chance of one duplicate line at the seam rather than build a
   perfect cursor — see Edge cases.)

### 2.5 Open the socket
`GET ws://127.0.0.1:1977/ws/<id>?token=<token>` (no `assistant=` needed for an
existing session; it defaults to `claude` but is ignored when the session
already exists, `server.go:382-385` + `GetOrCreate`). **Deliberately omit
`device_id`** — the CLI is not an owner device and must never be treated as the
push target (§3). Also omit `rows`/`cols` (no PTY interest).

On connect the broker (`server.go:446-486`):
- sends a `status` frame (`sendStatus`),
- sends a **PTY snapshot** (`sendSnapshot`) — the chat CLI **discards** binary
  frames,
- re-surfaces an outstanding AskUserQuestion **directly to this client** as a
  `view_event`/`view:"chat"` assistant frame whose content begins with the
  `[[conduit:needs-input]]` sentinel (`server.go:474-485`, content from
  `PendingAskChatContent`, `askcontrol.go:210-225`; sentinel def
  `askcontrol.go:55`). This is how the CLI learns the agent is *currently*
  blocked on a question even if it attached after the question was asked.

Then the broker subscribes the client to both `Subscribe()` (binary PTY) and
`SubscribeText()` (JSON frames) and runs `writeLoop`
(`server.go:488-519`, `writeLoop` `server.go:1158-1203`). The CLI cares only
about the **text** frames.

### 2.6 Frames the CLI CONSUMES (read from the wire)
All live chat/status arrive as **text** WS messages (gorilla TextMessage),
JSON. Shapes the CLI must parse:

- **Chat message** (the core of the Chat tab), published via `PublishText`
  (`manager.go:862-909`), wire shape:
  ```json
  {"type":"view_event","view":"chat",
   "event":{"role":"assistant"|"user"|"tool"|"system",
            "content":"…","ts":"<RFC3339Nano>","files":[…]}}
  ```
  - `role:"assistant"` whose `content` starts with `[[conduit:needs-input]]`
    is an **AskUserQuestion / approval card** — render it as a numbered prompt
    (strip the sentinel line, as the apps do, `askcontrol.go:43-55`). The
    user's next sent message answers it.
  - `role:"tool"` → render as a dimmed tool line.
  - `role:"system"` → render as a system notice (e.g. delivery-failure text
    published by `SendChat`, `manager.go:1071-1074`).
- **Direct AskUserQuestion re-surface on connect** — same `view:"chat"` shape
  but sent directly (not broadcast), `server.go:474-485`.
- **Status** — both the top-level `{"type":"status",…}` envelope and the
  `view_event`/`view:"status"` mirror (`emitViewerStatus`,
  `server.go:526-…`; mirror carries `viewer_count`/`terminal_rows/cols`). The
  CLI uses status only for: assistant name, `phase`/`turn_active`, and to show a
  "(N viewers)" hint. Geometry fields are ignored.
- **`chat_ack`** — `{"type":"chat_ack","session_id":…,"client_msg_id":…}`
  (`server.go:919-923`). Confirms the CLI's own send was delivered; flip a local
  "sent → delivered" indicator.
- **`exit`** — `{"type":"exit","session":…,"code":…,"reason_code":…}`
  (`writeLoop` done branch, `server.go:1192-1200`). Print and quit.
- **`ping`/`pong`** — heartbeat (`writeLoop` ticker `server.go:1181-1190`,
  `handleText` `ping`→`pong` `server.go:807-808`). The CLI must answer the
  broker's `{"type":"ping"}` text with nothing required (gorilla protocol-level
  Ping is auto-Ponged by the read loop), but should itself send periodic
  `{"type":"ping"}` to keep its read deadline fresh, matching the app.
- **Binary frames** (PTY snapshot/stream, resize/upload tags) — **discarded**.

### 2.7 Frames the CLI PRODUCES (write to the wire)
Only text frames, all already handled by `handleText` (`server.go:769-…`):

- **Send a chat message:**
  ```json
  {"type":"chat","msg":"<text>","client_msg_id":"<uuid>"}
  ```
  Handled at `server.go:878-925`: dedups on `client_msg_id`
  (`chatDedup.markSeen`, dedups same-client resends only), routes to
  `c.sess.SendChat(env.Msg)` (`manager.go:968-1077`), and returns a
  `chat_ack`. The CLI MUST set a stable `client_msg_id` (UUID per send) so it
  gets acks and so a reconnect-resend is deduped — same durable-delivery
  contract as the app (`server.go:888-924`).
  - Because `SendChat` first calls `takePendingAsk()` (`manager.go:987`), a
    message typed while an AskUserQuestion is outstanding is automatically
    routed as the **answer** to that question (control_response), not queued as
    a new turn. The CLI does not need a separate "answer" command — typing the
    answer text *is* the answer, exactly like the phone. (For numbered-option
    questions, the operator types the option text / number; the same free-text
    routing the app uses applies, `manager.go:982-996`.)
- **Interrupt the current turn:**
  ```json
  {"type":"stop"}
  ```
  Handled at `server.go:811-815` → `InterruptTurn()` (`manager.go:1084`). Bound
  to a CLI command (e.g. `/stop` or Ctrl-C-once). See STOP-INTERRUPT-PROTOCOL.
- **Keepalive ping** (`{"type":"ping"}`, `server.go:807`).

The CLI introduces **zero** new WS message types and **zero** new HTTP routes —
it is purely a new consumer of the existing protocol. This is the central
invariant: *the SSH chat client is wire-indistinguishable from the phone on the
chat channel, except that it carries no `device_id`.*

### 2.8 Rendering model
A simple line-oriented TUI is sufficient (no full-screen grid): print history,
then stream live chat lines as they arrive, with a readline prompt at the
bottom for composing. Roles get distinct prefixes/colors; tool lines dimmed;
AskUserQuestion cards rendered with their numbered options and a visible "agent
is waiting" banner. A minimal v1 can be plain stdin/stdout line mode; a nicer
v2 can use a readline lib. Keep v1 dependency-light.

---

## 3. The push-gate fix (the one real regression)

### The bug
`maybeNotifyTurnEnd` (`broker/internal/session/push_notify.go:106-112`) and
`maybeNotifyPendingInput` (`push_notify.go:152-158`) both early-return when
`s.SubscriberCount() > 0`. `SubscriberCount()` counts `s.subs` — the **binary
PTY** subscriber set (`manager.go:762-769`, `765-768`). On WS connect the
handler subscribes **both** `sub := sess.Subscribe()` (PTY) **and**
`textSub := sess.SubscribeText()` (`server.go:488-489`). So *any* WS client —
including the phone and, naively, the SSH CLI — increments `SubscriberCount`.

If the SSH CLI attaches via the standard `/ws/<id>` path, it bumps
`SubscriberCount` to ≥1, and the phone (now backgrounded, socket dropped) will
**miss** turn-done and pending-input pushes. That is the regression to prevent.

Note the LA (Live Activity) updates are already *not* gated — `notifyLATurnEnd`
/ `notifyLAPendingInput` fire unconditionally (`push_notify.go:107-108`,
`153-154`). Only the alert push is gated. So the fix is scoped to those two
`SubscriberCount() > 0` checks.

### Options

**Option A — gate on owner-device presence, not raw subscriber count
(recommended).**
Replace the `SubscriberCount() > 0` guard with "an **owner-device** client is
currently attached." Track a per-session count of *currently-connected owner
clients* — i.e. clients whose connect carried a `device_id` equal to the
session's `OwnerDeviceID` (`manager.go:1710-1716`, `pushState.ownerDeviceID`
`push_notify.go:24-32`). The WS handler increments it on connect when
`ownerDeviceID != "" && ownerDeviceID == session.OwnerDeviceID`
(`server.go:402-407`), decrements in the existing `defer` cleanup
(`server.go:500-504`). The push guard becomes `if s.OwnerDeviceConnected()
{ return }`.
- The SSH CLI carries **no** `device_id`, so it never counts → never suppresses
  the phone's push. Exactly the desired behavior.
- **Preserving single-phone behavior exactly:** for a session created by an old
  client *without* a `device_id`, `OwnerDeviceID` is empty. We must keep the
  current "any viewer suppresses" semantics there to avoid a *new* push when the
  phone is foregrounded. So the guard is:
  ```
  if ownerDeviceID == "" { suppress when SubscriberCount() > 0 }   // legacy, unchanged
  else                   { suppress when an owner-device client is connected }
  ```
  This is byte-identical to today for the no-device_id case, and for the
  single-modern-phone case (the phone *is* the owner device, so when it's
  attached we suppress, when it's gone we push) — while the SSH CLI is invisible
  to the gate in both cases.
- Cost: a small connected-owner counter on the session, inc/dec at the two WS
  sites, one new accessor. Touches `session/push_notify.go` (guard + counter),
  `session/manager.go` (counter field + accessor), `ws/server.go` (inc/dec).
  All inside the session/ws packages — no backend or client changes.

**Option B — let the chat client subscribe "text-only" so it doesn't count.**
`SubscriberCount` counts only `s.subs` (PTY), not `s.textSubs`
(`manager.go:765-768`). If the chat CLI attached via a path that subscribes
**only** `SubscribeText()` and skips `Subscribe()`, it would tail chat without
ever incrementing `SubscriberCount`, and the existing gate would be untouched.
This needs either (a) a query flag on `/ws/<id>` (e.g. `chat_only=1`) that makes
the handler skip the PTY subscribe + snapshot, or (b) a dedicated lightweight
endpoint.
- Pro: zero change to the push-gate logic; the regression simply never happens
  because the CLI is invisible to `SubscriberCount`.
- Con: introduces a new connect mode/branch in the hot WS path
  (`server.go:446-519`) and a behavior where `viewer_count` no longer reflects
  the chat CLI (arguably correct — it's not a PTY viewer). Slightly more
  surface area in the protocol than Option A. Does **not** fix the deeper
  conceptual bug that *any* PTY viewer (e.g. a future second phone in PTY mode)
  suppresses the owner's push.

**Option C — owner-device-targeted push always fires regardless of viewers.**
Drop the suppression entirely for sessions with an `OwnerDeviceID`, relying on
the fact that pushes are already device-targeted (`notifyTargeted`,
`push_notify.go:84-99`) and the phone can locally suppress a notification when
it's foregrounded with the session open.
- Pro: simplest broker change.
- Con: **regression risk** — today the phone relies on the broker *not* pushing
  while it's attached; moving suppression to the client is a behavior change
  across both apps (mobile work, device-verify) and would over-notify older app
  builds that don't suppress locally. Rejected for v1.

### Recommendation
**Option A.** It fixes the actual conceptual bug (suppress only when the
*owner's* device is present, not any subscriber), keeps legacy/no-`device_id`
and single-phone behavior byte-identical, and makes the SSH CLI correctly
invisible to the gate without inventing a new connect mode. It is a small,
self-contained broker-only change shippable as its own PR (§5), independently
testable with the broker unit suite (§6), and requires **one** device-verify
pass (confirm the phone still gets turn-done/approval pushes when backgrounded,
and does *not* double-notify when foregrounded). Ship the CLI first (Phase 1),
which works correctly the instant Option A lands; until then the CLI is usable
but does suppress the phone's pushes — acceptable for an owner-only,
opt-in-by-running-a-command tool, and called out in O-2.

---

## 4. Concurrency / edge cases

- **AskUserQuestion phone-vs-SSH answer race.** There is a single `pendingAsk`
  slot consumed atomically by `takePendingAsk()` (`askcontrol.go:258-268`,
  invoked from `SendChat`, `manager.go:987`). If both the phone and the SSH CLI
  answer "simultaneously," `takePendingAsk` returns the request to exactly one
  of them (the first to grab `s.mu`); that one sends the control_response and
  the agent resumes. The **second** message finds `pendingAsk == nil` and is
  routed as a *normal new user turn* (`manager.go:996` onward → `s.chat.Send`).
  Result: the question is answered once (correct), and the loser's text becomes
  an ordinary follow-up prompt. This is **acceptable** for a single-operator
  tool — both clients are the same human. Mitigation if we want it tighter:
  surface "(answered by another client)" when a send that the CLI *thought*
  was answering a pending ask comes back as a normal turn — detectable because
  the CLI knows it had an outstanding sentinel card and the agent resumed. v1:
  document the behavior, no special handling.
- **Concurrent sends (no pending ask).** Two clients each sending a chat
  message are two discrete user turns into `SendChat`; the agent processes them
  in order (or returns `errCodexTurnInFlight` → the system notice at
  `manager.go:1064-1071`). Fine — no shared mutable answer slot, no corruption.
  `client_msg_id` is per-client; the dedup map keys on `(sessionID,
  client_msg_id)` (`chatDedup`), so two clients with different ids never collide.
- **Broker redeploy / session recovery.** A broker restart drops the CLI's WS
  (read error → reconnect). On reconnect the session may be only *recoverable*
  and is spawned lazily on the WS connect (`main.go:179-183`,
  `GetOrCreate` at `server.go:403`). The CLI should: on WS close, attempt a
  bounded reconnect loop, and on reconnect **re-load history**
  (`…/conversation/<id>?since_ts=<lastSeen>`) before tailing, since the broker
  does not replay chat (`server.go:466-469`). The `conversation.jsonl` survives
  reap, so the transcript is intact across redeploy (`convlog.go` /
  `serveSessionConversation` works for exited sessions too,
  `api.go:378-381`). An outstanding AskUserQuestion that was in-flight at
  restart time is *lost* (the `pendingAsk` lived in memory and dies with the
  old process; a respawned agent re-asks if still blocked) — same as the
  phone's behavior, no special CLI handling.
- **Session already exited.** WS connect to an exited session yields an `exit`
  frame (or 410 `session_gave_up`, `server.go:415-419`); the CLI prints the
  transcript (still readable from REST) and reports the session is closed.
- **Multiple SSH CLIs.** Two `conduit-broker chat <id>` instances are just two
  more text subscribers; `PublishText` fans out to all (`manager.go:896-908`,
  drop-oldest backpressure). Harmless.

---

## 5. Phased implementation checklist

**Phase 1 — the CLI client (broker-only, ships behind nothing).**
Self-contained new subcommand; no protocol changes, no behavior change to
existing clients. Caveat: until Phase 2, attaching suppresses the phone's
pushes (it counts toward `SubscriberCount`). Acceptable, called out in PR
description + O-2.
- [ ] `broker/cmd/conduit-broker/chat.go`: `runChat(args) int` — flag parse
      (`--addr`, `--token`, `--list`, `--tail N`), token resolution (§2.2),
      `GET /api/sessions` list/validate, `GET …/conversation/<id>?tail=N` load,
      open `/ws/<id>?token=…` (NO `device_id`, NO rows/cols), tail text frames,
      render chat/tool/ask/status, readline compose loop emitting `chat` with a
      fresh `client_msg_id`, `/stop` → `stop`, heartbeat ping, reconnect loop.
- [ ] `broker/cmd/conduit-broker/main.go`: add `case "chat"` to the dispatch
      switch (`:60-74`) and a usage line (`:77-86`).
- [ ] Telemetry/log breadcrumbs at connect / send / ack / ask-answer / reconnect
      (server-side log lines; the CLI is on the box so stderr is fine).
- [ ] Unit tests: history+tail seam dedup; frame parsing
      (chat/ask-sentinel/status/ack/exit); `client_msg_id` is set on every send.

**Phase 2 — push-gate fix (Option A, separate small PR).**
Broker-only, independently testable, needs one device-verify.
- [ ] `session/manager.go`: connected-owner counter field + `OwnerDeviceID`
      getter + `OwnerDeviceConnected()` accessor.
- [ ] `ws/server.go`: inc on connect when the connecting `device_id` matches the
      session owner (`:402-407`), dec in the cleanup `defer` (`:500-504`).
- [ ] `session/push_notify.go`: replace the two `SubscriberCount() > 0` guards
      (`:110`, `:156`) with the owner-presence guard, preserving the
      empty-`OwnerDeviceID` legacy path exactly (§3 Option A).
- [ ] Unit tests: legacy (no device_id) path unchanged; modern phone attached →
      suppressed, detached → pushes; non-owner subscriber (SSH CLI: no device_id)
      → does NOT suppress.
- [ ] Flag **needs on-device verification**: backgrounded phone still receives
      turn-done + approval pushes while an SSH CLI is attached; foregrounded
      phone does not double-notify.
- [ ] Broker redeploy after merge (per CLAUDE.md, `broker/` changed and must be
      live): `docs/BROKER-REDEPLOY.md`.

---

## 6. Testing

**Locally testable (broker is buildable/testable on the dev box — CLAUDE.md):**
- Gates: `cd broker && gofmt -l . && go vet ./... && go test ./...`.
- Phase 1: an integration test can spin the WS server in-process (existing tests
  do, e.g. `multi_viewer_test.go`, `chat_ack_test.go`), attach the chat client
  logic, and assert: history load order, live `chat` frame rendering, a `chat`
  send produces a `chat_ack` with the same `client_msg_id`, a send while a
  `pendingAsk` is set routes as the answer (assert the agent resumes / control
  path taken), `/stop` triggers `InterruptTurn`. Frame parsing is pure-unit.
- Phase 2: unit-test the push gate directly (the existing push_notify tests
  cover the targeting path; add cases for the owner-presence guard across the
  three scenarios in §5).

**Needs on-device verification (mobile is CI-compile-only — CLAUDE.md):**
- The actual push behavior on a backgrounded phone while the SSH CLI is
  attached (Option A): turn-done + approval pushes still arrive; no
  double-notify when foregrounded. This is the only device-gated item; batch it
  into the next device-test session.

---

## 7. Open questions for the owner

- **O-1 (token ergonomics).** How turnkey should token discovery be? Minimum:
  require `CONDUIT_TOKEN`/`--token` and print the `systemctl show -p
  Environment conduit-broker` hint when absent. Nicer: have the CLI read the
  unit's environment automatically. The latter means the CLI reads the live
  secret from systemd — acceptable for a root operator on the box, but worth a
  conscious yes.
- **O-2 (ship Phase 1 before Phase 2?).** Phase 1 alone suppresses the phone's
  pushes while attached. Is that acceptable as an interim (owner-only,
  opt-in-by-command), or should Phase 1 + Phase 2 land together? Recommendation:
  ship Phase 1 first for fast feedback, Phase 2 close behind.
- **O-3 (AskUserQuestion race mitigation).** Is the "loser's answer becomes a
  normal turn" behavior (§4) acceptable, or do you want the CLI to detect and
  annotate "answered by another client"? v1 assumes acceptable.
- **O-4 (rendering depth).** Plain line-mode v1, or invest in a readline/colored
  TUI immediately? Affects dependency footprint.
- **O-5 (interrupt binding).** Bind `stop` to a `/stop` command, to a single
  Ctrl-C (with a second Ctrl-C to quit), or both?

---

## Files touched, per phase

**Phase 1 (CLI):**
- `broker/cmd/conduit-broker/chat.go` (new)
- `broker/cmd/conduit-broker/main.go` (dispatch + usage)
- `broker/cmd/conduit-broker/chat_test.go` (new)

**Phase 2 (push-gate, Option A):**
- `broker/internal/session/push_notify.go` (guard + counter)
- `broker/internal/session/manager.go` (counter field + accessors)
- `broker/internal/ws/server.go` (inc/dec at connect + cleanup)
- `broker/internal/session/push_notify_test.go` (or existing push test file)

No iOS/Android/core changes in either phase. Phase 2 keeps the backend
abstraction line: the change is confined to `session/` + `ws/` and touches no
client and no agent backend.
