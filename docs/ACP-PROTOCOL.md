# ACP (Agent Client Protocol) — wire facts + conduit integration design

Research notes for a future **ACP backend** in the broker's protocol-keyed
`AgentBackend` registry (alongside `stream-json` for claude, `codex-app-server`
for codex, `opencode-server` for opencode). Goal: make ACP-speaking agents
(gemini-cli today; Zed-family, goose, others later) cheap to onboard by paying
the protocol cost once.

ACP = **Agent Client Protocol**, the Zed-originated open standard for
editor⇄agent integration. It is distinct from MCP (MCP connects an agent to
tools/data; ACP connects a *client/editor* to an *agent*). Spec:
<https://agentclientprotocol.com>, Zed overview: <https://zed.dev/acp>.

All wire frames below were **captured live** against `gemini-cli 0.42.0`
(`gemini --acp`) on the dev box on 2026-06-11 unless marked "(spec)". Gemini-cli
is installed + Google-OAuth signed in, so ACP is locally verifiable the same way
codex app-server is.

## 1. Transport + frame kinds

JSON-RPC 2.0, **one JSON object per line over the subprocess's stdin/stdout**
(same JSONL-over-stdio model as codex app-server). gemini-cli **does** emit the
`"jsonrpc":"2.0"` field (codex omits it). Three frame kinds, demuxed exactly like
codex:

- **Request** — has `id` + `method`. Both directions send these.
- **Response** — has `id` + (`result` | `error`), no `method`.
- **Notification** — has `method`, no `id`.

Critically, like codex, ACP has **server→client (agent→client) requests** — the
agent calls methods ON the client (permission, filesystem, terminal). The
broker's existing reader pattern (a line with both `id` and `method` ⇒ a
server→client request whose `id` must be echoed back) applies verbatim.

## 2. Method inventory

**Client→Agent** (the broker calls these):

| Method | Kind | Purpose |
|---|---|---|
| `initialize` | request | version + capability negotiation |
| `authenticate` | request | run an auth method (optional; OAuth/key) |
| `session/new` | request | create a session (cwd, mcpServers) → `sessionId` |
| `session/load` | request | resume a prior session (optional; gated by `loadSession` cap) |
| `session/prompt` | request | submit a turn; resolves with `stopReason` |
| `session/set_mode` | request | switch permission mode (default/plan/yolo/…) |
| `session/cancel` | notification | interrupt the running turn |

**Agent→Client** (the broker must implement these):

| Method | Kind | Purpose |
|---|---|---|
| `session/update` | notification | ALL streaming output (text, thoughts, tool calls, plans, commands) |
| `session/request_permission` | request | approval gate for a tool call |
| `fs/read_text_file` | request | read a file via the client (optional cap) |
| `fs/write_text_file` | request | write a file via the client (optional cap) |
| `terminal/create` / `output` / `release` / `wait_for_exit` / `kill` | request | run commands via the client (optional `terminal` cap) |

## 3. Handshake (LIVE)

```
C->S {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":1,
        "clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":false},
        "clientInfo":{"name":"conduit","version":"0.1"}}}
S->C {"jsonrpc":"2.0","id":1,"result":{
        "protocolVersion":1,
        "authMethods":[{"id":"oauth-personal","name":"Log in with Google",...},
                       {"id":"gemini-api-key",...},{"id":"vertex-ai",...},{"id":"gateway",...}],
        "agentInfo":{"name":"gemini-cli","title":"Gemini CLI","version":"0.42.0"},
        "agentCapabilities":{"loadSession":true,
            "promptCapabilities":{"image":true,"audio":true,"embeddedContext":true},
            "mcpCapabilities":{"http":true,"sse":true}}}}

C->S {"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/root/acp_ws","mcpServers":[]}}
S->C {"jsonrpc":"2.0","id":2,"result":{
        "sessionId":"2db20e8f-0a1e-4d22-950e-0000568360d6",
        "modes":{"currentModeId":"default","availableModes":[
            {"id":"default","name":"Default","description":"Prompts for approval"},
            {"id":"autoEdit","name":"Auto Edit","description":"Auto-approves edit tools"},
            {"id":"yolo","name":"YOLO","description":"Auto-approves all tools"},
            {"id":"plan","name":"Plan","description":"Read-only mode"}]},
        "models":{"currentModelId":"auto-gemini-3","availableModels":[
            {"modelId":"auto-gemini-3","name":"Auto (Gemini 3)","description":"..."},
            {"modelId":"gemini-3.1-pro-preview-customtools","name":"gemini-3.1-pro-preview"},
            {"modelId":"gemini-2.5-pro","name":"gemini-2.5-pro"}, ...]}}}

# Immediately after session/new the agent pushes an available_commands_update:
S->C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"...","update":{
        "sessionUpdate":"available_commands_update",
        "availableCommands":[{"name":"memory","description":"Manage memory."}, ...,
                             {"name":"init",...},{"name":"about",...}]}}}
```

**Facts the broker depends on:**
- `protocolVersion` is an integer (`1`), not a semver string.
- `clientInfo`/`agentInfo` mirror codex's `clientInfo`.
- `session/new` returns BOTH the session id AND (gemini extension, not in the
  base spec) `modes` and `models` blocks — **this is the model + effort/mode
  catalog**, discoverable per-session with no extra RPC. The base ACP spec puts
  `modes`/`models` here too but as `null` for agents that don't expose them.
- `authMethods[]` in the initialize result is the login surface — if the agent
  is not authed, the broker would call `authenticate {methodId}` (or rely on
  materialized creds, the conduit norm).

## 4. Prompt turn (LIVE)

`session/prompt` is the turn verb. Its **response does not return until the turn
ends** (unlike codex `turn/start` which returns immediately and streams a
separate `turn/completed`). All streaming arrives as `session/update`
notifications in between; the response carries the terminal `stopReason`.

```
C->S {"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId":"...","prompt":[{"type":"text","text":"Reply with exactly: The sky is blue."}]}}

# streaming, in order:
S->C session/update {"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"**Responding...**"}}}
S->C session/update {"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The sky is blue."}}}

# turn end — the response to id:3:
S->C {"jsonrpc":"2.0","id":3,"result":{
        "stopReason":"end_turn",
        "_meta":{"quota":{"token_count":{"input_tokens":10620,"output_tokens":4},
                          "model_usage":[{"model":"gemini-2.5-flash",
                                          "token_count":{"input_tokens":10620,"output_tokens":4}}]}}}}
```

### `session/update` discriminator

The variant key is **`sessionUpdate`** (a string), NOT `type`. (The published
schema page renders it ambiguously; the live wire and the prompt-turn doc confirm
`sessionUpdate`.) Variants seen / specced:

| `sessionUpdate` | Payload | Conduit handling |
|---|---|---|
| `agent_message_chunk` | `{content:{type:"text",text}}` | the assistant prose — **accumulate, emit ONE bubble at turn end** (same posture as codex deltas / claude `content_block_delta`) |
| `agent_thought_chunk` | `{content:{type:"text",text}}` | reasoning; drop or route to a thinking lane (don't emit as the answer) |
| `tool_call` | `{toolCallId,status,title,kind,content,locations}` | a tool started (see below) |
| `tool_call_update` | `{toolCallId,status,title?,content,locations,kind}` | tool progress/result |
| `plan` | `{plan:{entries:[{content,status,priority}]}}` (spec) | optional plan/todo lane |
| `available_commands_update` | `{availableCommands:[{name,description,input?}]}` | slash-command catalog (drop in v1) |
| `usage_update` | token/cost metrics (spec; gemini puts usage in the prompt `_meta` instead) | usage gauge |

### ContentBlock shape

A `ContentBlock` is `{type, ...}`:
- `{"type":"text","text":"..."}`
- `{"type":"image","data":"<base64>","mimeType":"image/png"}`
- `{"type":"resource_link","uri":"file:///...","name":"..."}`
- `{"type":"resource","resource":{"uri","text","mimeType"}}`

The `prompt` array in `session/prompt` and the `content` arrays in tool updates
both use ContentBlocks (conduit sends `[{type:"text",text}]`, mirroring its codex
`input` shape).

### Tool-call lifecycle (LIVE)

```
S->C session/update {"update":{"sessionUpdate":"tool_call","toolCallId":"h523ji2j",
        "status":"in_progress","title":"...","content":[],"locations":[],"kind":"think"}}
S->C session/update {"update":{"sessionUpdate":"tool_call_update","toolCallId":"h523ji2j",
        "status":"completed","content":[{"type":"content","content":{"type":"text","text":"..."}}],"kind":"think"}}
# a file edit, reported as a diff content block:
S->C session/update {"update":{"sessionUpdate":"tool_call_update","toolCallId":"yiosok0h",
        "status":"completed","title":"Writing to acp_demo.txt",
        "content":[{"type":"diff","path":"/root/acp_ws/acp_demo.txt","oldText":"","newText":"HELLO\n"}],
        "locations":[{"path":"/root/acp_ws/acp_demo.txt"}],"kind":"edit"}}
```

`status` ∈ `pending` → `in_progress` → `completed` | `failed` | `cancelled`.
`kind` ∈ (observed) `think` / `edit` / `execute` / `read` (spec adds more). Tool
content blocks add `{"type":"content",...}` and `{"type":"diff",...}` to the base
ContentBlock set.

### stopReason enum (spec; `end_turn`/`cancelled` live-verified)

`end_turn` · `max_tokens` · `max_turn_requests` · `refusal` · `cancelled`.

## 5. Filesystem / terminal delegation (LIVE)

When the client advertises `clientCapabilities.fs.{read,write}TextFile`, the
agent performs file I/O **through the client** via server→client requests:

```
S->C {"jsonrpc":"2.0","id":0,"method":"fs/read_text_file","params":{"path":"/root/acp_ws/acp_demo.txt","sessionId":"..."}}
C->S {"jsonrpc":"2.0","id":0,"result":{"content":""}}
S->C {"jsonrpc":"2.0","id":3,"method":"fs/write_text_file","params":{"path":"/root/acp_ws/acp_demo.txt","content":"HELLO\n","sessionId":"..."}}
C->S {"jsonrpc":"2.0","id":3,"result":{}}
```

**Recommendation for v1: advertise `fs:{readTextFile:false,writeTextFile:false}`
and `terminal:false`.** The agent then does its own file/command I/O directly in
the session cwd (its child runs in the same workspace) instead of round-tripping
through the broker — exactly how claude/codex/opencode operate today (the broker
never proxies their disk access). This drops a whole surface from the v1 backend.
Wire fs/terminal delegation only if a target agent *requires* it. (Note: gemini's
server-id counter for these is its own space starting at 0, same independence
caveat as codex's approval ids — echo the exact `id`.)

## 6. Permission / approval request (spec + flow LIVE)

The agent gates a tool call with a server→client `session/request_permission`:

```
S->C {"jsonrpc":"2.0","id":N,"method":"session/request_permission","params":{
        "sessionId":"...",
        "toolCall":{ ...the tool_call being gated, by toolCallId... },
        "options":[
            {"optionId":"o1","name":"Allow once","kind":"allow_once"},
            {"optionId":"o2","name":"Allow always","kind":"allow_always"},
            {"optionId":"o3","name":"Reject once","kind":"reject_once"},
            {"optionId":"o4","name":"Reject always","kind":"reject_always"}]}}

# select an option:
C->S {"jsonrpc":"2.0","id":N,"result":{"outcome":{"outcome":"selected","optionId":"o1"}}}
# or, on cancel/timeout/disconnect:
C->S {"jsonrpc":"2.0","id":N,"result":{"outcome":{"outcome":"cancelled"}}}
```

`kind` ∈ `allow_once` / `allow_always` / `reject_once` / `reject_always`. The
client picks an `optionId` from the agent-supplied list (you do NOT invent
decision strings — unlike codex's fixed `accept`/`decline`/`cancel` enum, ACP's
options are agent-defined and you echo back the chosen `optionId`). The
`{"outcome":"cancelled"}` form is the deny/timeout terminus.

Note: with gemini in `default` mode the model auto-escalated to `autoEdit` for an
edit and went straight to `fs/write_text_file` without a `request_permission`; to
force the permission request, run a non-edit tool (e.g. a shell `execute`) or
keep the session pinned to `default`/`plan`. The shape above is from the spec
(<https://agentclientprotocol.com/protocol/prompt-turn>); the request/response
*flow* (server→client id-bearing request, echo the id, `outcome` reply) was
exercised live via the fs delegation path which uses the identical mechanism.

## 7. Cancellation (spec)

```
C->S {"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"..."}}
```

A **notification** (no id). On receipt the agent stops the model + tools, replies
`cancelled` to any pending `request_permission`, and resolves the outstanding
`session/prompt` with `{"stopReason":"cancelled"}`. So interrupt is a fire-and-
forget notify, and the turn's completion is observed via the prompt response —
cleaner than codex's `turn/interrupt` request.

---

## 8. Mapping ACP onto conduit's `AgentBackend`

The opencode backend (`broker/internal/session/backend_opencode.go`) is the
closest template: an external long-lived child speaking a structured protocol,
one process per session, with a turn state machine that accumulates streamed
output into one assistant bubble and a self-heal respawn. ACP differs only in
transport (JSONL/stdio vs HTTP/SSE) — and stdio is what the codex app-server
backend (`codexappserver.go`) already does. **ACP = "codex app-server's stdio
JSON-RPC reader" + "opencode's turn-accumulator + server→client approval
bridge".** Both halves already exist in-tree.

### Lifecycle / process

- **Spawn:** `gemini --acp` (or `<agent> --acp`) as a long-lived child, stdio
  pipes. Run `initialize` → latch `agentCapabilities` → `session/new {cwd}` →
  latch `sessionId`. Persist `sessionId` in `meta.json` (reuse the
  `codexThreadID`/`resumeCodexThreadID` slot, exactly as opencode does).
- **Resume:** if `agentCapabilities.loadSession` is true, `session/load
  {sessionId,cwd,mcpServers}` after a respawn. If false, fall back to a fresh
  `session/new` (opencode's posture).
- **Send (turn):** `session/prompt {sessionId, prompt:[{type:text,text}]}`. The
  call is outstanding for the whole turn; the reader resolves it on the `id`
  response and reads `stopReason` as the turn terminus. `TurnActive()` = a prompt
  id is outstanding.
- **Interrupt:** `session/cancel {sessionId}` notification + mark interrupting
  (so the terminus is quiet); the prompt resolves `cancelled`. Maps directly to
  the `chatBackend.Interrupt()` contract.
- **Close:** kill the child (idempotent), cancel the reader.

### Streaming → conduit chat channel

Run the codex/opencode posture: **accumulate `agent_message_chunk` text, emit a
single `view_event {view:"chat", event:{role:"assistant",content,ts,files:[]}}`
at turn end** (on the `stopReason` response). Route `agent_thought_chunk` to a
thinking lane or drop it (do NOT fold it into the answer). `tool_call` /
`tool_call_update` can drive activity breadcrumbs / a tool lane in a later pass;
v1 can drop them (the answer text is the load-bearing output). A silence watchdog
(opencode's `lastActivity` timer reset on any owned-session frame) guards a hung
provider.

### Tool approval → conduit approval card (the high-value mapping)

`session/request_permission` is the ACP twin of codex's
`item/commandExecution/requestApproval` / `item/fileChange/requestApproval`. It
maps onto the SAME surface codex already uses: the `approvalAnswerer` chatBackend
capability (`chatbackend.go`) + the pending-input card + the `pendingInputHooker`
push hook. Concretely:

- Stash the pending request (its `id`, `options[]`, and the gated `toolCall` for
  the card title) on the backend, fire `onPendingInput` (push notify), and block
  the turn.
- The user's card tap → `AnswerApproval(msg)` → reply
  `{outcome:{outcome:"selected", optionId:<mapped>}}`. Map **Approve → the
  `allow_once` option's `optionId`; Deny → the `reject_once` option's
  `optionId`** (select by `kind` from the agent-supplied list — never hardcode an
  id). This is cleaner than codex's `decline`-vs-`cancel` heuristic because ACP's
  reject options don't interrupt the turn (the agent decides how to proceed).
- Timeout / disconnect / close → `{outcome:{outcome:"cancelled"}}` (the codex
  policy: never leave the turn hanging).

ACP has **no separate AskUserQuestion/elicitation channel** — there is no
`item/tool/requestUserInput` analogue. A choice the agent wants from the user
either arrives as prose or (if the agent models it) as a permission request.
So conduit's AskUserQuestion card maps only to `session/request_permission` for
ACP; free-text elicitation is out of scope for ACP v1.

### Usage

Gemini embeds usage in the prompt response `_meta.quota.token_count`
(`input_tokens`/`output_tokens`) per turn — a usable per-turn usageDelta + a
context gauge from `input_tokens` (same shape-of-data as codex
`thread/tokenUsage/updated.last`). There is **no ACP account-level subscription
usage source** in the base spec, so `Usage()` returns `ok=false` (like opencode);
the per-turn token deltas feed the context gauge only.

### Catalog (model/effort discovery)

`session/new`'s result carries `models.availableModels[]` (id/name/description)
and `modes.availableModes[]` — a free per-session catalog. `CatalogProbe` spawns
a throwaway `<agent> --acp`, runs `initialize` + `session/new`, reads the models
block, maps to `ModelInfo`, and kills the child (the opencode probe pattern).
Effort/mode is the `modes` list, applied via `session/set_mode {sessionId,
modeId}` rather than a CLI flag.

### `BackendCapabilities` for ACP

| Flag | Value | Why |
|---|---|---|
| `Compact` | **false** (v1) | no `session/compact` in base ACP; revisit if an agent exposes a slash `/compact` via `available_commands_update` |
| `AskUserQuestion` | **true** | `session/request_permission` → approval card |
| `Effort` | **true** | `modes` (default/plan/yolo/autoEdit) via `session/set_mode`; or false if an agent reports no modes |
| `Resume` | **true** when `agentCapabilities.loadSession`, else false | per-agent from the initialize result |
| `Interrupt` | **true** | `session/cancel` |
| `Usage` | **false** | no account-usage source (per-turn tokens only) |
| `Steer` | **false** | ACP has no mid-turn-injection verb; a 2nd `session/prompt` must wait for the turn to end |

Plan mode (`AgentSupports.PlanMode`) maps to the `plan` entry in `availableModes`
+ a `permission_modes.plan` manifest rule that calls `session/set_mode` — though
for ACP the mode switch is protocol-level (`session/set_mode`), not an argv
rewrite, so the manifest rule would be a no-op and the backend applies the mode
from the session-create options instead.

### Conduit-side gaps

- **Argv-based `permission_modes` don't fit ACP.** The manifest rule model is
  drop/add argv flags; ACP modes are a runtime `session/set_mode` call. Either
  (a) the ACP backend ignores `permission_modes` and maps conduit's plan flag to
  `session/set_mode "plan"` internally, or (b) add an optional manifest field
  for "mode is protocol-level." Smallest path: (a), backend-internal.
- **`set_model` / effort override** is also protocol-level (`session/set_mode`,
  and model selection is a `session/new`/per-prompt option in some agents) rather
  than `model_args`/`effort_args` argv. The ACP backend reads conduit's model/
  effort override and applies it via the protocol, ignoring the argv templates.
  The manifest's `model_args`/`effort_args` would be empty (like codex/opencode).
- **No elicitation/free-text-ask channel** (noted above) — AskUserQuestion is
  approval-only for ACP.
- Everything else (push hooks, AI niceties, title gen, watchdog, resume slot,
  catalog probe) reuses existing seams unchanged.

---

## 9. `pi` specifically

**`pi` is Mario Zechner's coding agent** (`@earendil-works/pi-coding-agent` on
npm, v0.79.1 as of 2026-06-11; an active fork `oh-my-pi` exists). It is a
terminal/IDE coding agent. **`pi` does NOT natively speak ACP.** Its native
programmatic interface is a **custom RPC protocol** invoked as `pi --mode rpc`
(JSON over stdio, pi's own schema — not ACP, not the codex app-server schema).

ACP support for pi exists ONLY through a **third-party adapter, `pi-acp`**
(<https://github.com/svkozak/pi-acp>): the adapter is the ACP server (speaks ACP
JSON-RPC 2.0 over stdio to the client) and spawns `pi --mode rpc` underneath,
translating between the two. There is also `pi-shell-acp` (the inverse: lets pi
*drive* ACP backends). Neither is first-party.

**`pi` is NOT installed on this box** (`which pi` → none; only unrelated
`pidof`/`ping`/`pinentry`). It is installable: `npm i -g
@earendil-works/pi-coding-agent` (Node 22+, provider API keys). I did not install
it (read-only task).

**Recommendation: do NOT make `pi` the ACP pilot.** Reasons:
1. pi doesn't speak ACP natively — onboarding it means shipping/owning the
   third-party `pi-acp` adapter as an extra hop (two processes: adapter + `pi
   --mode rpc`), which is fragile and outside conduit's control.
2. The clean ACP path for pi is to add a **native pi backend** later that speaks
   `pi --mode rpc` directly (its own protocol family), the way codex got a native
   app-server backend rather than going through an adapter.
3. **gemini-cli is the right ACP pilot** — it speaks ACP natively (`gemini
   --acp`), is already installed + signed in on the box (locally verifiable), and
   exercises the full surface (streaming, tool calls, fs delegation, permission,
   modes, model catalog) as captured above.

### Speculative `pi.toml` (IF onboarded via pi-acp — not recommended for v1)

```toml
name           = "pi"
command        = ["pi-acp"]          # the adapter; spawns `pi --mode rpc`
args           = []
protocol       = "acp"
config_dir     = ".config/pi"        # verify against pi's real config path
cred_files     = [".config/pi/auth.json"]   # verify; pi uses provider API keys (env likely)
env_passthrough = ["ANTHROPIC_API_KEY","OPENAI_API_KEY","GEMINI_API_KEY"]
data_dir       = ".local/share/pi"   # resume store, if pi-acp maps session/load
resume_args    = []                  # ACP resume is protocol-level (session/load)
continue_args  = []
model_args     = []                  # model is protocol-level
effort_args    = []                  # mode is protocol-level (session/set_mode)
login_provider = ""                  # API-key based; no conduit OAuth flow
workdir        = "/workspace"
```

(Paths marked "verify" need a real pi install to confirm — not done here.)

### Recommended gemini ACP manifest (the actual pilot)

```toml
name            = "gemini"
command         = ["gemini"]
args            = ["--acp"]
protocol        = "acp"
config_dir      = ".gemini"
cred_files      = [".gemini/gemini-credentials.json", ".gemini/google_accounts.json"]
env_passthrough = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
data_dir        = ".gemini"          # session store; gates resume via session/load
resume_args     = []                 # ACP resume is protocol-level (session/load)
continue_args   = []
model_args      = []                 # model is protocol-level (session/new option)
effort_args     = []                 # mode is protocol-level (session/set_mode)
login_provider  = "google"           # OAuth-personal; creds materialized from host ~/.gemini
workdir         = "/workspace"

[permission_modes.plan]
# ACP plan mode is a session/set_mode "plan" call, applied by the backend, not an
# argv rewrite — these are advisory/no-op for the acp backend.
```

(cred paths confirmed live: `~/.gemini/gemini-credentials.json` +
`google_accounts.json` exist on the box.)

---

## 10. Implementation plan (for the architect)

**Files to add (mirrors the opencode pilot exactly):**

1. `broker/internal/session/backend_acp.go` — the `acpBackend` (`AgentBackend`:
   Spawn/CatalogProbe/Usage/Capabilities) + `acpProcess` (the long-lived stdio
   JSON-RPC child: reader/demux, turn state machine, `Send`/`Interrupt`/`Close`/
   `TurnActive`, `AnswerApproval`, setTurnHook/setTurnIdleHook/setPendingInputHook).
   `init()` registers `registerBackend("acp", acpBackend{})`.
2. `broker/internal/session/backend_acpwire.go` — pure parsers/encoders for the
   ACP frames (initialize, session/new result→catalog, session/update variants,
   request_permission), table-tested. (opencode split its wire parsers out this
   way; keeps the I/O file thin and the parsers unit-testable with the captured
   frames above.)
3. `broker/cmd/conduit-broker/embedded-agents/gemini.toml` — the manifest above.
4. Tests: `backend_acp_test.go` (stub-driven turn + approval), `backend_acpwire_test.go`
   (table tests over the captured frames), and a gated `backend_acp_live_test.go`
   (`CONDUIT_ACP_LIVE=1`, like the codex/opencode live tests) that drives a real
   `gemini --acp` handshake+turn+approval on the box.

**Pilot + "≤3 files outside its package" success metric:** gemini via
`gemini.toml`. Files touched OUTSIDE `broker/internal/session/`: just
**(1)** `embedded-agents/gemini.toml`. Possibly **(2)** an app-side agent icon/
mark asset (a GeminiMark) — but the `/api/capabilities` descriptor + app static
fallback (PR #428 pattern) already degrade an unknown agent gracefully, so even
that is optional for the broker proof. So ≤1–2 files outside the backend package
— it clears the bar the opencode pilot set.

**Risks:**
- **Spec drift / agent extensions.** gemini layers non-base fields (`modes`/
  `models` on session/new, `_meta.quota` usage, autoEdit auto-escalation). The
  wire parsers must tolerate unknown fields (decode into structs that ignore
  extras) and absent base fields (`modes:null` on a stricter agent).
- **`fs`/`terminal` delegation.** If a future ACP agent *requires* the client to
  do file/terminal I/O (advertises and depends on it), v1's `fs:false`/
  `terminal:false` posture would break it. Mitigation: keep the capability flags
  in one place; wire the handful of server→client fs methods only when needed.
- **Permission auto-escalation.** gemini's default mode auto-promotes edits to
  autoEdit, so approval cards may fire less than expected; pin sessions to
  `default`/`plan` if conduit wants every action gated. Verify per agent.
- **Turn-blocking prompt response.** `session/prompt` stays outstanding for the
  whole turn — the reader must NOT block on it (codex/opencode already use an
  async reader goroutine; same pattern).
- **First-token latency (gemini-3).** Live captures showed multi-second to
  occasionally >45s first-token under load; keep the silence watchdog generous
  (opencode uses 2 min) and the model picker can default to a flash model.

### Capture technique (reproduce on the box)

Spawn `gemini --acp`, write `initialize` (protocolVersion 1, clientInfo) →
`session/new {cwd}` (latch `sessionId` + read the models/modes catalog) →
`session/prompt {sessionId, prompt:[{type:text,text}]}`. Implement the
server→client handlers: echo `id` for `fs/read_text_file`/`fs/write_text_file`,
and reply `{outcome:{outcome:"selected",optionId}}` to `session/request_permission`.
The prompt response (id-matched) carries `stopReason`. Drivers used for these
captures live in the job tmp dir (`acp_probe.py`, `acp_turn2.py`, `acp_text.py`).
