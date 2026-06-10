# opencode protocol (reference)

Ground-truth wire shapes for a future **opencode** backend (WS-4.2). Captured
live against `opencode 1.17.0` (npm `opencode-ai@1.17.0`) on the dev box, with
**no provider credentials configured** — opencode 1.17 ships a built-in
`opencode` ("OpenCode Zen") provider with free, no-auth models, so every capture
below is from a real model answering a real turn, not an auth-error stub.

Unlike codex (JSON-RPC over stdio) and claude (stream-json over stdio),
opencode's integration surface is an **HTTP server** (`opencode serve`) with a
REST control plane plus an **SSE event stream** (`GET /event`). This matches the
plan note: *"litter launches `opencode serve` so the API is the integration
surface."* `opencode run` is a thin headless one-shot over the same engine and
is documented here as a fallback.

Schema source of truth: the server self-serves its OpenAPI 3.1 document at
`GET /doc` (alias `GET /openapi.json`) — `opencode 1.17.0`, 135 paths. Every
request/response schema below is from that doc, cross-checked against live curls.

---

## Install (user-space, on the dev box)

```
mkdir -p ~/.opencode-install
npm i -g --prefix ~/.opencode-install opencode-ai@1.17.0
export PATH="$HOME/.opencode-install/bin:$PATH"
opencode --version          # -> 1.17.0
```

`opencode-ai` is a launcher that, on first run, downloads a ~300 MB platform
binary into `~/.opencode-install/lib/node_modules/opencode-ai/bin/opencode.exe`
(despite the `.exe` suffix it is the native ELF on Linux). **No system packages
touched.** See the cleanup note at the end for the keep/remove decision.

### CLI surface (`opencode --help`, abridged)

```
opencode serve              starts a headless opencode server      <- INTEGRATION SURFACE
opencode run [message..]    run opencode with a message (headless one-shot)
opencode models [provider]  list all available models
opencode providers          manage AI providers and credentials   (alias: auth)
opencode session            manage sessions (list / delete)
opencode export [sessionID] export session data as JSON
opencode attach <url>       attach to a running server
opencode acp                start ACP (Agent Client Protocol) server
```

Top-level flags relevant to us: `--port` (default 0 = random), `--hostname`
(default `127.0.0.1`), `-m/--model provider/model`, `-c/--continue`,
`-s/--session <id>`, `--agent`, `--dangerously-skip-permissions`.

---

## Server mode (`opencode serve`) — the integration surface

```
$ opencode serve --port 47821 --hostname 127.0.0.1 --print-logs
Warning: OPENCODE_SERVER_PASSWORD is not set; server is unsecured.
... message=loading path=/root/.config/opencode/config.json
opencode server listening on http://127.0.0.1:47821
```

- Binds `127.0.0.1` by default (good — localhost-only, like the codex/claude
  chat-event ports). `--port 0` (the default) picks a random port; litter passes
  an explicit `--port=`.
- **Unauthenticated by default.** Optional HTTP Basic via
  `OPENCODE_SERVER_PASSWORD` (+ `OPENCODE_SERVER_USERNAME`, default `opencode`).
  For a localhost-only broker child we can leave it open; if we ever bind
  non-loopback, set the password.
- A single server process is **multi-session** and backed by a **global** store
  (see Persistence). One long-lived `opencode serve` per agent install can host
  every conduit session — closer to the codex app-server model than to claude's
  one-process-per-turn.

### Two REST namespaces (important)

The OpenAPI doc exposes the same concepts under **two prefixes**:

- **un-prefixed** (`/session`, `/session/{id}/prompt_async`, `/event`,
  `/config/providers`, …) — the stable SDK / TUI surface. **Use these.** All
  live captures below are against this namespace.
- **`/api/...`** (`/api/session`, `/api/session/{id}/prompt`, `/api/event`, …) —
  a newer/experimental admission-queue surface with different bodies (e.g.
  `/api/session/{id}/prompt` wants `{"prompt":{"text":...},"delivery":"queue"}`
  and returns an `admittedSeq` envelope). Documented here as "seen" but **not**
  the recommended target — it churned across versions and the un-prefixed routes
  are what the official SDK/TUI drive.

### Endpoint map (the subset a backend needs)

| Purpose | Method + path | Notes |
|---|---|---|
| OpenAPI doc | `GET /doc` | also `/openapi.json`; 3.1.0 |
| Health | `GET /global/health`, `GET /api/health` | |
| Create session | `POST /session` | body `{title?, agent?, model?{id,providerID,variant?}, parentID?}` |
| List sessions | `GET /session` | array of Session |
| Get / patch / delete session | `GET\|PATCH\|DELETE /session/{id}` | |
| **Send turn (async)** | `POST /session/{id}/prompt_async` | returns **204**, streams over `/event` |
| **Event stream** | `GET /event` | **SSE**, `data: {json}\n\n`, all sessions |
| **Interrupt** | `POST /session/{id}/abort` | returns `true` |
| Message history (resume) | `GET /session/{id}/message` | array of `{info, parts[]}` |
| Connected providers + models | `GET /config/providers` | **catalog-probe surface** |
| Full models.dev catalog | `GET /provider` | ~3.7 MB; do NOT use for probe |
| Write a credential | `PUT /auth/{providerID}` | api / oauth / wellknown |
| Compact / summarize | `POST /session/{id}/summarize`, `/api/session/{id}/compact` | |
| Permission reply | `POST /session/{id}/permissions/{permissionID}` | approval path |
| Fork | `POST /session/{id}/fork` | |

(Full 135-path list lives in `GET /doc`; the table is the slice WS-4.2 touches.)

---

## Turn lifecycle (live capture)

Server on `127.0.0.1:47821`. Create a session, open the SSE stream, fire an
async prompt, watch the stream to `session.idle`.

### 1. Create session

```
C->S POST /session  {"title":"async-cap"}
S->C 200 {
  "id":"ses_14fb1f36effem9u8iW7lORYvyR","slug":"sunny-moon","projectID":"global",
  "directory":"/tmp/oc-srv.VzARDi","path":"tmp/oc-srv.VzARDi","cost":0,
  "tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},
  "title":"async-cap","version":"1.17.0",
  "time":{"created":1781074280704,"updated":1781074280704}}
```

Session id is `ses_…`. The `directory` is the cwd the server was launched in
(per-session cwd is set via `--dir` on the CLI / the workspace API; a plain
`POST /session` inherits the server's launch dir).

### 2. Open the event stream

```
C->S GET /event              (SSE; stays open)
S->C data: {"id":"evt_…","type":"server.connected","properties":{}}
```

`/event` is a **server-wide** SSE stream (events for *all* sessions; demux on
`properties.sessionID`). Frames are `data: <json>\n\n`. The first frame on
connect is always `server.connected`.

### 3. Send the turn (async)

```
C->S POST /session/ses_14fb1f36…/prompt_async
     {"model":{"providerID":"opencode","modelID":"big-pickle"},
      "parts":[{"type":"text","text":"reply with exactly: PONG"}]}
S->C 204 No Content
```

`prompt_async` returns **204 immediately**; all turn output arrives on `/event`.
`model` is `{providerID, modelID, variant?}`. `parts[]` items are
`TextPartInput` / `FilePartInput` / `AgentPartInput` / `SubtaskPartInput`.

### 4. Stream frames (verbatim, in order)

Ordered `type` sequence for the turn above:

```
server.connected
session.next.agent.switched          properties.agent="build"
session.next.model.switched          properties.model={id,providerID,variant}
message.updated                      role="user" (the prompt is recorded)
message.part.updated  type=text      text="reply with exactly: PONG"
session.updated
session.status        status=busy     <- TURN START signal
message.updated                      role="assistant" (empty shell created)
session.updated / session.diff / message.updated
session.status        status=busy
message.part.updated  type=step-start
message.part.updated  type=reasoning
message.part.delta  (x12)            field="text", incremental reasoning
message.part.updated  type=reasoning (finalized)
message.part.updated  type=text      text=""        <- answer part opens
message.part.delta  (x2)             field="text", delta="The"/...
message.part.updated  type=text      text="PONG"    <- answer finalized
message.part.updated  type=step-finish  reason="stop", tokens{...}
message.updated  (assistant)         finish="stop", tokens{...}
session.status        status=busy
session.status        status=idle     <- TURN END signal
session.idle                          <- TURN END (terminal, per-session)
session.updated / session.diff / message.updated
```

Verbatim key frames:

```json
{"id":"evt_…","type":"server.connected","properties":{}}
```
```json
{"id":"evt_…","type":"session.status","properties":{
  "sessionID":"ses_14fb1f36…","status":{"type":"busy"}}}
```
```json
{"id":"evt_…","type":"message.part.delta","properties":{
  "sessionID":"ses_14fb1f36…","messageID":"msg_eb04e1194…",
  "partID":"prt_eb04e191e…","field":"text","delta":"The"}}
```
```json
{"id":"evt_…","type":"message.part.updated","properties":{
  "sessionID":"ses_14fb1f36…",
  "part":{"id":"prt_…","reason":"stop","messageID":"msg_eb04e1194…",
    "sessionID":"ses_14fb1f36…","type":"step-finish",
    "tokens":{"total":8593,"input":8578,"output":3,"reasoning":12,
      "cache":{"write":0,"read":0}},"cost":0},
  "time":1781074369127}}
```
```json
{"id":"evt_…","type":"session.idle","properties":{"sessionID":"ses_14fb1f36…"}}
```

**Frame facts the broker depends on:**

- **Text streaming is two-phase.** `message.part.delta` carries incremental
  chunks (`field`, `delta`); a final `message.part.updated` with the *same*
  `partID` carries the **full** `text`. A renderer can either accumulate deltas
  or just take the final `message.part.updated`. `field` distinguishes `text`
  from `reasoning` deltas (reasoning streams first under a `type:"reasoning"`
  part, then the answer under a `type:"text"` part).
- **Turn boundaries:** start = first `session.status {type:"busy"}` after the
  user `message.updated`; end = `session.status {type:"idle"}` immediately
  followed by `session.idle` (terminal). `session.idle` is the cleanest
  "turn done" trigger (one per session, no payload beyond `sessionID`).
- **Failure terminus — `session.error` (added; the no-reply-hang fix).** A turn
  that fails emits `session.error` and is **NOT guaranteed** to be followed by a
  `session.idle`. The backend MUST treat `session.error` as a turn terminus too,
  or the composer's typing indicator spins forever with no reply (the
  device-reported v0.0.133 hang — `session.idle` was the only recognized end).
  Shape (live, opencode 1.17.0):

  ```json
  {"id":"evt_…","type":"session.error","properties":{
    "sessionID":"ses_…",
    "error":{"name":"UnknownError","data":{
      "message":"Model not found: anthropic/claude-nonexistent-99. Did you mean: …"}}}}
  ```

  `error` is a tagged union by `name`: `ProviderAuthError`
  (`data.{providerID,message}`), `UnknownError` (`data.{message,ref}`),
  `APIError` (`data.{message,statusCode,isRetryable,…}`), `ContextOverflowError`,
  `MessageOutputLengthError` (no `data`), `StructuredOutputError`, and
  `MessageAbortedError` (`data.message`) — the abort terminus, which the
  interrupt/Stop path already handled, so the backend ends the turn **quietly**
  for that one and surfaces a Chat-tab notice for the rest. opencode may pack a
  `$bunfs` JS stack trace into `data.message`; the backend keeps only the first
  line for the user-facing notice. (Observed: a *model-not-found* error WAS
  followed by `idle`, but error classes that fail mid-stream are not — endTurn
  is idempotent, so handling both is safe.)
- **Silent stall — the REAL v0.0.134 no-reply hang (fixed).** The `session.error`
  terminus above (#459) only covers turns that *fail*. A turn can also go `busy`
  and then **stall with NO terminus at all** — no `message.part.*`, no
  `session.idle`, no `session.error` — when the hosted **OpenCode Zen** provider
  (the no-auth default `opencode/big-pickle`) is rate-limited / slow / down and
  opencode's upstream request just hangs. Reproduced live on the box: a turn that
  errors or succeeds always ends, but a provider stall leaves the per-session
  stream silent indefinitely. The backstop is a 10-minute silence watchdog
  (`opencodeTurnSilenceTimeout`) that ends the turn and posts "no response from
  the agent." **The bug:** opencode emits a server-wide **`server.heartbeat`**
  frame — `{"type":"server.heartbeat","properties":{}}`, NO `sessionID` — every
  **~10 s**, and the backend was resetting the watchdog's `lastActivity` on
  *every* decoded frame *before* the own-session filter. So the heartbeats
  perpetually rearmed the watchdog and it could NEVER fire → typing indicator
  spun forever, no reply, no error (matching the device report; not the #459
  case). **Fix:** reset `lastActivity` only for frames that belong to OUR
  `sessionID`, *after* the filter — heartbeats and other-session frames no longer
  starve the watchdog (`handleEvent`, `backend_opencode.go`).
- **Stale resume → `prompt_async` 404 (fixed).** opencode's conversation store is
  a single global SQLite DB (`~/.local/share/opencode/opencode.db`). If it is
  wiped/rotated under the broker (fresh agent-home after a redeploy, a GC of
  `data_dir`, a DB reset) while `meta.json` still carries the old `ses_…`, then
  resuming that id makes `POST /session/{id}/prompt_async` return **HTTP 404**
  (`NotFoundError`) with **zero SSE frames** — no `busy`, no terminus. Verified
  live. The backend now treats a 404 on send as "session lost": it `POST`s a
  fresh `/session`, re-persists the new `ses_…` (so the next resume targets a
  live id), and retries the prompt once. The old transcript stays in the app's
  own log.
- **Token usage** rides the `step-finish` part and the final assistant
  `message.updated` (`tokens{total,input,output,reasoning,cache{read,write}}`,
  plus `cost`). On the free zen models `cost` is `0`. This is the Usage source
  if we ever wire it — but per the plan, **usage is unsupported** for opencode
  (Capabilities flag off); these fields exist but we won't surface them in v1.
- Every frame is namespaced by `properties.sessionID` — one `/event` stream
  multiplexes all sessions, so the broker filters by the session it owns.

### 5. Interrupt (abort)

```
C->S POST /session/{id}/abort
S->C 200 true
```

Returns the bare JSON `true`. Aborting mid-turn stops generation; the stream
settles to `session.idle`. (No dedicated `turn.aborted` event observed — the
turn just terminates with idle.)

---

## Headless one-shot (`opencode run`) — fallback surface

```
$ opencode run "say hi" --format json
{"type":"step_start","timestamp":…,"sessionID":"ses_14fb45328…","part":{…,"type":"step-start"}}
{"type":"text","timestamp":…,"sessionID":"ses_14fb45328…","part":{"type":"text","text":"hi","time":{…}}}
{"type":"step_finish","timestamp":…,"sessionID":"ses_14fb45328…","part":{"reason":"stop","type":"step-finish","tokens":{"total":8217,"input":8200,"output":2,"reasoning":15,"cache":{"write":0,"read":0}},"cost":0}}
exit 0
```

- `--format json` emits **JSONL** (one event per line) on stdout. Note the event
  envelope differs slightly from the server SSE stream: `run` uses
  `step_start`/`text`/`step_finish` snake-case top-level `type`s, whereas the
  server SSE uses `message.part.*` + `session.*`. **Same underlying parts**
  (`part.type` is `step-start`/`text`/`step-finish` in both); only the outer
  envelope differs. A backend that targets one surface cannot blindly reuse the
  other's parser.
- `--format default` is human/TUI formatting (not machine-readable).
- The `sessionID` appears on **every** event line.
- Exit code `0` on success. (Auth/payload failures surface as a non-zero exit +
  a JSON error on stderr; not separately captured because the zen provider never
  forced an auth error.)
- Resume: `opencode run --continue "…"` reuses the **last** session id verbatim
  and preserves context (verified: told it "my name is Zephyr", then
  `--continue "what is my name"` → `"Zephyr"`, same `ses_…` id).
  `opencode run --session <id> "…"` targets a specific session; `--fork` forks
  before continuing.

`run` is fine for a one-shot probe but lacks live interrupt and the rich event
stream — **prefer `serve`** for the real backend.

---

## Model catalog (probe surface)

`opencode models` (CLI) and `GET /config/providers` (server) both enumerate the
**connected** providers' models — this is the catalog probe for WS-4.2.

```
$ opencode models
opencode/big-pickle
opencode/deepseek-v4-flash-free
opencode/mimo-v2.5-free
opencode/nemotron-3-ultra-free
opencode/north-mini-code-free
```

`GET /config/providers` (the structured form, recommended for the probe):

```json
{"providers":[
  {"id":"opencode","name":"OpenCode Zen","source":"custom",
   "env":["OPENCODE_API_KEY"],"options":{"apiKey":"public"},
   "models":["nemotron-3-ultra-free","mimo-v2.5-free","deepseek-v4-flash-free",
             "big-pickle","north-mini-code-free"]}],
 "default":{"opencode":"big-pickle"}}
```

- `providers[]` is the **connected** set (here just `opencode`, since no creds);
  `default` is the per-provider default model. Model id for a prompt is
  `providerID/modelID` (e.g. `opencode/big-pickle`), or split into
  `{providerID, modelID}` in the prompt body.
- **Do NOT probe `GET /provider`** for the catalog — it returns the *entire*
  models.dev universe (~3.7 MB, ~150 providers) regardless of what's connected.
  It has `connected:[…]` and `default:{…}` fields, but `/config/providers` is the
  small, connected-only view we want. (`opencode models --refresh` repopulates
  the models.dev cache; `--verbose` adds per-model `cost`/`limit`/`capabilities`
  metadata.)
- Per-model metadata (from `--verbose` / `/provider`): `cost{input,output,cache}`,
  `limit{context,input,output}`, and a `capabilities{reasoning,toolcall,
  attachment,input{text,image,…},output{…}}` block — useful if we later map
  opencode capabilities into our model picker.

---

## Auth / credentials

- **Env-var keys work directly.** opencode reads provider keys from env per the
  provider's `env` field: `ANTHROPIC_API_KEY` (anthropic), `OPENAI_API_KEY`
  (openai), `OPENCODE_API_KEY` (zen), etc. So our credentials-materialization
  can simply export the right env var into the server child — no file write
  needed for API-key providers. (On this box `env | grep -c ANTHROPIC` = **0**,
  so no key was present; the zen free provider is what answered.)
- **On-disk creds** live at **`~/.local/share/opencode/auth.json`** (the path
  `opencode providers list` prints: *"Credentials ~/.local/share/opencode/auth.json"*).
  It was absent here (0 credentials). Shape, from the OpenAPI `PUT /auth/{providerID}`
  body (a map `providerID -> credential`):
  - **API key:** `{"type":"api","key":"<secret>","metadata?":{…}}`
  - **OAuth:** `{"type":"oauth","refresh":"…","access":"…","expires":<ms>,
    "accountId?":"…","enterpriseUrl?":"…"}`
  - **wellknown:** `{"type":"wellknown","key":"…","token":"…"}`
- **Login flow:** `opencode providers login -p <provider> -m <method>`
  (interactive; alias `opencode auth login`). Programmatically the server exposes
  `PUT /auth/{providerID}` (write a credential) and
  `POST /provider/{providerID}/oauth/authorize` + `/oauth/callback` for the OAuth
  dance. For conduit's API-key providers, writing `auth.json` or exporting the
  env var are both viable; env var is simplest.

---

## Persistence / resume

- **Single global SQLite store**, not per-project files:
  `~/.local/share/opencode/opencode.db` (+ `-wal`, `-shm`). All sessions from
  *both* `serve` and `run` share it — `opencode session list` and
  `GET /session` see the same set.
- Session ids are `ses_…`; message ids `msg_…`; part ids `prt_…` (all sortable,
  time-ordered prefixes).
- **Resume after a broker restart** = relaunch `opencode serve` against the same
  `~/.local/share/opencode` (same `$HOME`/`XDG_DATA_HOME`), then
  `GET /session/{id}/message` to rehydrate history, and continue with
  `POST /session/{id}/prompt_async`. No "resume" RPC is needed — the session is
  already in the DB; you just keep prompting the same `ses_…` id. (CLI analogue:
  `run --session <id>` / `run --continue`.)
- `GET /session/{id}/message` returns `[{info:{role,…}, parts:[{type,…}]}]`;
  verified it returns the full prior turn (`role:user` + `role:assistant` with
  `step-start/reasoning/text/step-finish` parts) after a restart-free reconnect.
- Config dir: **`~/.config/opencode`** (`config.json` / `opencode.json` /
  `opencode.jsonc`). opencode also auto-installs a `@opencode-ai/plugin`
  node_modules tree (~62 MB) there on first run; `--pure` skips external plugins.

---

## Recommendation for our AgentBackend (Phase 2 interface)

**Target the server (`opencode serve`), not `run`.** One long-lived
`opencode serve --port=<alloc> --hostname 127.0.0.1` per agent install, shared
across conduit sessions, mirroring the codex app-server "one durable child"
model more than claude's per-turn spawn.

| Phase-2 method | opencode mapping |
|---|---|
| **Spawn** | Start (or reuse) `opencode serve --port <p> --hostname 127.0.0.1`; `POST /session` to create a `ses_…`; open `GET /event` (SSE) and demux on `properties.sessionID`; send a turn with `POST /session/{id}/prompt_async`; map `session.status{busy}`→turn-start, `message.part.delta`/`message.part.updated`→chat parts, `session.idle`→turn-end. Interrupt = `POST /session/{id}/abort`. Resume = reconnect to the same DB + keep prompting the same `ses_…`. |
| **CatalogProbe** | `GET /config/providers` → `providers[].models` as `providerID/modelID`; `default` for the default pick. (Never `GET /provider`.) Or shell `opencode models` if the server isn't up yet. |
| **Usage** | **Unsupported** — set the Capabilities "no usage" flag. (Token/cost fields exist on `step-finish` / `message.updated` but the plan scopes usage out for opencode; the zen free models report `cost:0` anyway.) |
| **Capabilities** | server-based; multi-session; supports interrupt (abort); supports resume (global DB); permission/approval path exists (`/session/{id}/permissions/{id}`) but is a follow-up; usage = off. |

Why server over exec: live interrupt, a structured multiplexed event stream,
multi-session reuse, and a self-describing OpenAPI surface — all absent or
clumsy via `run`.

---

## Manifest fields `agents/opencode.toml` will need

Modeled on `agents/codex.toml`:

```toml
name                = "opencode"
command             = ["opencode"]
args                = ["serve", "--hostname", "127.0.0.1"]   # broker appends --port=<alloc>
# API keys are read from env by provider; pass through what we materialize:
env_passthrough     = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENCODE_API_KEY"]
workdir             = "/workspace"

# --- Phase-1 manifest-driven fields ---
protocol            = "opencode-server"          # new backend dispatch key
config_dir          = ".config/opencode"          # ~/.config/opencode (config.json/.jsonc)
cred_files          = [".local/share/opencode/auth.json"]   # on-disk creds (optional; env works too)
# data/session DB lives at ~/.local/share/opencode/opencode.db — persist this dir for resume
data_dir            = ".local/share/opencode"      # (new field — sessions DB; needed for resume)
resume_args         = []                            # server resumes via the global DB, no flag
continue_args       = []                            # CLI fallback: ["run","--continue"]
model_args          = []                            # model is a prompt-body field, not a flag
login_provider      = "opencode"                    # zen free provider; anthropic/openai via env

# port the broker tells the server to listen on (parallels codex chat_event_port_env,
# but opencode takes it as a CLI flag, so the backend appends --port=<n> at spawn)
```

Notes for the manifest author:
- opencode has **no API-key flag**; keys flow via env (`env_passthrough`) or
  `auth.json`. Prefer env materialization.
- The **session store is a global SQLite DB under `data_dir`**, not per-session
  cred/scratch files — `cred_files` covers only `auth.json`; resume needs the
  whole `data_dir` to persist across broker restarts. If the manifest schema has
  no `data_dir` field yet, WS-4.2 should add one (it's the resume hinge).
- `args = ["serve", …]` differs from codex/claude (bare `command`); confirm the
  Phase-1 spawn path supports a subcommand in `args` (it should — codex already
  passes `--dangerously-bypass…` as an arg).
- Plan/permission mode: opencode supports `--dangerously-skip-permissions` (CLI)
  and a `/session/{id}/permissions/{id}` reply API; a `[permission_modes.plan]`
  block can map to a read-only agent or skip-permissions toggle in a follow-up.

---

## WS-4.2 implementation checklist

1. **`agents/opencode.toml`** (+ embedded copy under
   `broker/cmd/conduit-broker/embedded-agents/opencode.toml`) with
   `protocol = "opencode-server"` and the fields above; add a `data_dir`
   manifest field if absent.
2. **New backend package** (e.g. `broker/internal/session/opencodeserver.go` +
   a wire file) implementing the Phase-2 `AgentBackend`:
   - Spawn/reuse `opencode serve --hostname 127.0.0.1 --port <alloc>`; wait for
     `opencode server listening on http://127.0.0.1:<port>` (or poll
     `GET /global/health`).
   - `POST /session` → store `ses_…`.
   - Long-lived `GET /event` SSE reader; parse `data: {json}`; demux on
     `properties.sessionID`; map `session.status{busy}`→turn-start,
     `message.part.delta`+`message.part.updated`→chat content (text +
     reasoning), `session.idle`→turn-end.
   - Turn send: `POST /session/{id}/prompt_async` with
     `{model:{providerID,modelID}, parts:[{type:"text",text}]}`.
   - Interrupt: `POST /session/{id}/abort`.
   - Resume: reconnect to the same `data_dir`; rehydrate via
     `GET /session/{id}/message`; keep prompting the same `ses_…`.
3. **Catalog probe**: `GET /config/providers` → `providers[].models`
   (`providerID/modelID`); default from `default`. Usage = unsupported
   (Capabilities flag).
4. **Credentials materialization**: export `ANTHROPIC_API_KEY` /
   `OPENAI_API_KEY` (or write `auth.json`) into the server child before spawn.
5. **Telemetry** (CLAUDE.md standing order): breadcrumbs at serve-spawn,
   server-ready, session-create, prompt-send, SSE-connect/reconnect/fail, abort;
   `Telemetry.capture` ERROR on serve crash / non-2xx / SSE drop.
6. **Stub-binary tests**: a fake `opencode` that serves `/doc`, `/session`,
   `/event` (canned SSE), `/session/{id}/prompt_async` (204 + scripted frames),
   and `/session/{id}/abort` — exercise turn, interrupt, resume. Keep the broker
   suite green (`gofmt -l . && go vet ./... && go test ./...`).
7. **Apps**: zero required changes if Phase-3 generic rendering landed; optional
   brand tint as a follow-up.

Plan success metric: files touched outside `agents/opencode.toml` + the new
backend package should be **≤ 3** (the `data_dir` manifest field + an embedded
copy + the dispatch wiring are the likely ones).

---

## Capture technique

```
# install (user-space)
npm i -g --prefix ~/.opencode-install opencode-ai@1.17.0
export PATH="$HOME/.opencode-install/bin:$PATH"

# server
opencode serve --port 47821 --hostname 127.0.0.1 --print-logs &

# openapi
curl -s http://127.0.0.1:47821/doc        # 135-path OpenAPI 3.1

# turn: open SSE, then async prompt
curl -sN http://127.0.0.1:47821/event > events.sse &     # SSE: data: {json}\n\n
curl -s -X POST http://127.0.0.1:47821/session -d '{"title":"x"}' -H 'content-type: application/json'
curl -s -X POST http://127.0.0.1:47821/session/<ses>/prompt_async \
  -H 'content-type: application/json' \
  -d '{"model":{"providerID":"opencode","modelID":"big-pickle"},"parts":[{"type":"text","text":"reply with exactly: PONG"}]}'
# -> 204; watch events.sse for message.part.delta ... session.idle

# interrupt
curl -s -X POST http://127.0.0.1:47821/session/<ses>/abort     # -> true

# catalog + resume + creds
curl -s http://127.0.0.1:47821/config/providers
curl -s http://127.0.0.1:47821/session/<ses>/message
opencode run "say hi" --format json          # headless JSONL fallback
opencode run --continue "…"                  # resume last session
```

The driver curls + the captured SSE/JSON live in the job tmp dir
(`/tmp/oc-events.jsonl`, `/tmp/oc-openapi.json`, etc.); not committed.

---

## Unverified / untested (honest list)

- **Real provider turns.** Every capture used the no-auth `opencode` zen free
  models. With `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` present the turn lifecycle
  should be identical (same engine, same events), but **tool-call frames,
  reasoning blocks on bigger models, and provider-specific errors are
  unverified.** No real key was on the box (`env | grep -c ANTHROPIC` = 0).
- **Tool / shell / file-edit parts.** A code-touching prompt ("create a file…")
  was later driven live: the turn is multi-step (`step-start` → `reasoning` →
  `tool` parts with `{tool,callID,state}` → `step-finish`, then a second step
  with the final `text`), interleaved with top-level `file.edited` /
  `file.watcher.updated` events, and still terminates with a single
  `session.idle`. The backend drops `tool`/`step-*`/`file.*` for prose and folds
  only `text` parts, so a tool turn maps to one assistant bubble + a clean end.
- **Permission / approval flow.** Endpoints exist
  (`/session/{id}/permissions/{id}`, `/permission/{requestID}/reply`,
  `permission` SSE events) but no approval fired (free model, no real tools).
  The codex-style accept/cancel decision shapes are **unconfirmed for opencode**.
- **Abort event.** Abort returns `true` and the stream goes `idle`; whether a
  distinct `*.aborted`/interrupted event is emitted (vs. plain `session.idle`)
  was not isolated.
- **`/api/*` namespace.** Body shapes differ (`prompt:{text}`, `delivery`,
  `admittedSeq`); treated as experimental and **not** the chosen surface — its
  full lifecycle is uncaptured.
- **Multi-session interleaving on one `/event` stream.** Demux-by-`sessionID` is
  assumed correct from the schema but not stress-tested with concurrent turns.
- **Server auth (`OPENCODE_SERVER_PASSWORD`).** Captures ran unsecured; the
  Basic-auth path was not exercised.
- **`config_dir` / `data_dir` relocation.** Did not verify that pointing
  `XDG_DATA_HOME` / `XDG_CONFIG_HOME` (or `$HOME`) at a per-agent dir cleanly
  relocates the DB + auth.json — assumed from standard XDG behavior. WS-4.2 must
  confirm the broker can sandbox each agent's store.
- **Crash/restart resume end-to-end.** History rehydration via
  `GET /session/{id}/message` was verified, but a full kill-serve →
  relaunch-serve → continue-same-`ses_` cycle was not run.
