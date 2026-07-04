# Codex app-server protocol (reference)

Ground-truth wire shapes for the **codex app-server** backend
(`broker/internal/session/codexappserver.go`). The app-server is JSON-RPC 2.0
spoken as one JSON object per line (JSONL) over the subprocess's stdin/stdout.
Captured live against `codex-cli 0.132.0` on the dev box (codex installed +
signed in). The `jsonrpc` version field is omitted on the wire — codex tolerates
its absence.

Schema source of truth: `codex app-server generate-json-schema --out <dir>` —
`ServerRequest.json` enumerates every server→client request; `ServerNotification.json`
the notifications; `ClientRequest.json` the client→server requests.

## Frame kinds

- **Request** — has both `id` (integer) and `method`. Expects a matching response.
- **Response** — has `id`, plus `result` or `error`. No `method`.
- **Notification** — has `method`, no `id`. Fire-and-forget.

Both directions send all three kinds. The broker's reader (`readLoop`) demuxes
on `id`/`method`: a line with `id` and **no** `method` is a response; a line with
a `method` and **no** `id` is a notification; a line with **both** `id` and
`method` is a **server→client request** (the approval path below).

## Handshake + turn (existing, unchanged)

For a mid-session switch back to Codex, the broker keeps `codex_thread_id`
independently from Claude's conversation id and uses `thread/resume` instead of
`thread/start`. Cross-agent context is not written into the Codex thread by a
file hook: the broker prepends its bounded handoff to the next ordinary
`turn/start` input. Approval/requestUserInput/elicitation responses and slash
commands do not consume that pending handoff.

```
C->S {"id":1,"method":"initialize","params":{"clientInfo":{"name":"conduit-broker","version":"0.0.1"}}}
S->C {"id":1,"result":{ … capabilities … }}
C->S {"method":"initialized","params":{}}
C->S {"id":2,"method":"thread/start","params":{"cwd":"…","approvalPolicy":"…","sandbox":"…"}}
S->C {"id":2,"result":{"thread":{"id":"019…"}}}
S->C {"method":"thread/started","params":{"thread":{"id":"019…"}}}
C->S {"id":3,"method":"turn/start","params":{"threadId":"019…","input":[{"type":"text","text":"…"}]}}
S->C {"id":3,"result":{ … }}
S->C {"method":"turn/started","params":{"turn":{"id":"019…"}}}
S->C {"method":"item/started", …} / item/agentMessage/delta … / item/completed …
S->C {"method":"thread/tokenUsage/updated", …}
S->C {"method":"turn/completed","params":{"turn":{"id":"…","status":"completed", …}}}
```

`approvalPolicy` is an `AskForApproval` enum: `untrusted` / `on-failure` /
`on-request` / `never`. `sandbox` is a `SandboxMode` enum: `read-only` /
`workspace-write` / `danger-full-access`. Today the broker uses
`danger-full-access`+`never` (full-access default, parity with the exec path's
`--dangerously-bypass-approvals-and-sandbox`) and `read-only`+`on-request` for
plan mode.

## turn/steer — mid-turn user injection (confirmed working)

`turn/steer` injects a user message into a **running** turn. The injected text
reaches the model at the next reasoning/step boundary — it does NOT retroactively
delete already-emitted tokens; output that started streaming before the steer
continues to completion, then the model incorporates the steered input.

**Note:** prior notes in this repo marked steer as "functionally inert / proposal-only" — that was a test artifact (we steered short turns that had already completed and got -32600 back). Steer is live and working in codex-cli 0.132.0.

### Confirmed-working frame sequence (codex-cli 0.132.0)

```
# While a turn is in progress (turn/started seen, turn/completed NOT yet seen):
C->S {"id":99,"method":"turn/steer","params":{
        "threadId":"019eb47f-edb2-77c0-9760-a4de90fdc5e2",
        "input":[{"type":"text","text":"STOP. Write about a PURPLE ELEPHANT instead."}],
        "expectedTurnId":"019eb47f-ee92-7d12-b1b0-7a690fab00ae"}}
S->C {"id":99,"result":{"turnId":"019eb47f-ee92-7d12-b1b0-7a690fab00ae"}}

# NO new turn/started fires — the turn continues under the same id.
# The steered text surfaces as a new userMessage item:
S->C {"method":"item/started","params":{"item":{"type":"userMessage","id":"…","content":[{"type":"text","text":"STOP. Write about a PURPLE ELEPHANT instead."}]},"threadId":"…","turnId":"019eb47f-ee92-7d12-b1b0-7a690fab00ae"}}
S->C {"method":"item/completed","params":{"item":{"type":"userMessage", …},"threadId":"…","turnId":"019eb47f-ee92-7d12-b1b0-7a690fab00ae"}}

# Agent then picks it up at the next reasoning/step boundary and responds.
```

### Parameters

```json
{
  "threadId": "<active thread id>",
  "input": [{"type": "text", "text": "<steer text>"}],
  "expectedTurnId": "<active turn id from turn/started>"
}
```

No model/effort/sandbox/outputSchema overrides are allowed on a steer — input only.

### Failure: -32600 "no active turn to steer"

```
S->C {"id":99,"error":{"code":-32600,"message":"no active turn to steer"}}
```

This means the turn completed (or was interrupted) before the steer arrived —
a natural race when the turn finishes just as the steer is sent. The broker's
fallback: call `turn/start` with the same text so the user's message is never
lost. The broker implements this automatically in `codexAppServerProcess.Steer`
+ `handleSteerResponse`.

### Where the broker tracks the active turn id

`codexAppServerProcess.turnID` — latched from the `turn/started` notification's
`params.turn.id`. The same field that `Interrupt()` uses to target
`turn/interrupt`. `Steer()` reads it under `c.mu`; `finishTurn()` clears it to
`""` when any turn terminus fires.

### Broker auto-steer behaviour

`Send(text)` with a turn active + `turnID` latched → calls `Steer(text)` instead of
returning `errCodexTurnInFlight`. The steer response is routed in
`routeTurnResponse`; on -32600 `handleSteerResponse` falls back to `turn/start`.
When the turn is active but `turnID` is not yet latched (race: `turn/started` not
yet seen), `Send` returns `errCodexTurnInFlight` as before.

## Approval requests (server→client, id-bearing)

`ServerRequest.json` enumerates ten server→client request methods. The two that
fire for ordinary `turn/start` turns are:

| Method | When | Params type |
|---|---|---|
| `item/commandExecution/requestApproval` | a shell/exec command needs approval (it would escalate out of the sandbox, or every command prompts under `untrusted`) | `CommandExecutionRequestApprovalParams` |
| `item/fileChange/requestApproval` | a file edit/patch needs approval | `FileChangeRequestApprovalParams` |

Others (documented from schema, not the primary path): `item/permissions/requestApproval`,
`item/tool/requestUserInput` (EXPERIMENTAL generic question), `mcpServer/elicitation/request`,
`item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, and the
legacy v1 `applyPatchApproval` / `execCommandApproval`.

### Live capture — command-execution approval

Drive (`thread/start` with `approvalPolicy:"untrusted"` + `sandbox:"read-only"`,
then a turn asking for a file write so the write must escalate past read-only):

**ACCEPT path** (verbatim, `codex-cli 0.132.0`):

```
C->S {"id":2,"method":"thread/start","params":{"cwd":"/tmp/w","approvalPolicy":"untrusted","sandbox":"read-only"}}
C->S {"id":3,"method":"turn/start","params":{"threadId":"019eafd2-99a6-7923-9c46-ed481522ac3a","input":[{"type":"text","text":"…echo hi > hello.txt…"}]}}
S->C {"method":"item/commandExecution/requestApproval","id":0,"params":{
        "threadId":"019eafd2-99a6-7923-9c46-ed481522ac3a",
        "turnId":"019eafd2-9f61-7363-94e2-321210214f0e",
        "itemId":"call_CZnHNSxLzchz3apnt8aHppHj",
        "startedAtMs":1781066284751,
        "command":"/bin/bash -lc 'echo hi > hello.txt'",
        "cwd":"/tmp/w",
        "commandActions":[{"type":"unknown","command":"echo hi > hello.txt"}],
        "proposedExecpolicyAmendment":["/bin/bash","-lc","echo hi > hello.txt"],
        "availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{…}},"cancel"]}}
C->S {"id":0,"result":{"decision":"accept"}}
S->C {"method":"serverRequest/resolved","params":{"threadId":"019eafd2-…","requestId":0}}
S->C {"method":"turn/completed","params":{"turn":{"id":"019eafd2-9f61-…","status":"completed", …}}}
```

Result: the command ran, `hello.txt` was created, the turn completed normally.

**Key facts the broker depends on:**

- The request's `id` is a **server-side counter that starts at 0** and is
  **independent** of the client's request-id space (our `initialize`=1,
  `thread/start`=2, turns 3,4,…). The response **must** echo this exact `id`
  (`{"id":0,"result":{"decision":…}}`). Do not allocate a client id for it.
- `command` and `cwd` may be `null` (schema), so render defensively.
- `availableDecisions` lists what the server will accept; `accept` and `cancel`
  are always present. `decline` is offered for some requests but **not all** —
  this capture omitted it from `availableDecisions`. **For deny, the broker
  prefers `decline` when this request offers it** (the turn CONTINUES and the
  agent acknowledges the denial) and **falls back to `cancel`** when it doesn't
  (always available; interrupts the turn). The broker parses the string entries
  of `availableDecisions` to decide; object entries (e.g.
  `acceptWithExecpolicyAmendment`) are ignored.
- After the response, the server emits a `serverRequest/resolved` notification
  (`{threadId, requestId}`) — a non-actionable confirmation.

### Response shape (`CommandExecutionRequestApprovalResponse`)

```json
{"id": <echo>, "result": {"decision": <CommandExecutionApprovalDecision>}}
```

`CommandExecutionApprovalDecision` variants:

| Value | Meaning |
|---|---|
| `"accept"` | run the command |
| `"acceptForSession"` | run + don't prompt again this session |
| `{"acceptWithExecpolicyAmendment":{execpolicy_amendment:[…]}}` | run + persist a policy rule |
| `{"applyNetworkPolicyAmendment":{network_policy_amendment:…}}` | persist a network rule |
| `"decline"` | deny; **agent continues the turn** |
| `"cancel"` | deny; **turn is immediately interrupted** |

`FileChangeApprovalDecision` (for `item/fileChange/requestApproval`) is the
string-only subset: `accept` / `acceptForSession` / `decline` / `cancel`.

### DENY paths (live-verified)

- `{"decision":"decline"}` → command blocked, but the **turn continues**
  (`turn/completed` status `completed`); the agent sees the block and may retry
  or give up. No file created.
- `{"decision":"cancel"}` → **turn ends** with `turn/completed` status
  `interrupted`. No file created.

The broker maps an approved tap → `accept`. A denied tap → `decline` **when the
request offered it** (the turn continues so the agent acknowledges the denial
and can adapt — device feedback: a deny→`cancel` left the agent silent because
`cancel` interrupts the whole turn), otherwise → `cancel` (always available; a
deny must never leave the turn spinning, mirroring claude's AskUserQuestion-deny
posture). Timeout / disconnect / close always use `cancel` (the turn can't
continue regardless).

### Timeout / disconnect

There is no server-side timeout on the request — it blocks the turn until a
response arrives. The broker mirrors claude's `askcontrol.go` policy: on
timeout, session close, or a lost client, respond `cancel` (deny) so the turn
unwedges rather than hanging forever.

## File-change approval (`item/fileChange/requestApproval`) — LIVE-CAPTURED

A file edit needs approval. Trigger live: `thread/start` with
`approvalPolicy:"on-request"` + `sandbox:"read-only"`, then a turn that edits an
existing file (e.g. "append a line to notes.txt with apply_patch"). The write
escalates past read-only and prompts.

**Verbatim request (codex-cli 0.132.0):**

```
S->C {"method":"item/started","params":{"item":{"type":"fileChange","id":"call_Xpd…","changes":[{"path":"/tmp/w/notes.txt","kind":{"type":"update","move_path":null},"diff":"@@ -2 +2,2 @@\n this is a seed file\n+GOODBYE\n"}],"status":"inProgress"},"threadId":"019eb43d-…","turnId":"019eb43d-…","startedAtMs":1781140384431}}
S->C {"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"019eb43d-5099-…","turnId":"019eb43d-511c-…","itemId":"call_XpdYgBBNHRXxKymuVa1GTgaA","startedAtMs":1781140384431,"reason":null,"grantRoot":null}}
C->S {"id":0,"result":{"decision":"accept"}}   # (or "decline")
S->C {"method":"turn/completed","params":{"turn":{"status":"completed", …}}}
```

**CRITICAL — the approval params carry NO diff/path.** Unlike the
command-execution approval (which inlines `command`/`cwd`), the
`FileChangeRequestApprovalParams` is just
`{itemId, startedAtMs, threadId, turnId, reason?, grantRoot?}`. The actual change
(path + unified diff) lives in the **preceding `fileChange` item**
(`item/started` then `item/completed`, `item.type=="fileChange"`), correlated by
**`itemId == item.id`**. The broker stashes the most recent fileChange item
(`lastFileChange`) and joins it to the approval request to render a card with the
real path. (The raw diff is deliberately NOT embedded in the card body — core's
`extract_pending_options` would mis-read `- …` diff lines as bullet options.)

**Response shape** (`FileChangeRequestApprovalResponse`):

```json
{"id": <echo>, "result": {"decision": <FileChangeApprovalDecision>}}
```

`FileChangeApprovalDecision` = `accept` / `acceptForSession` / `decline` /
`cancel` (string-only; no execpolicy variants). Unlike command-execution, the
request omits `availableDecisions`, but `decline` is ALWAYS valid for a file
change — **live-verified**: `{"decision":"decline"}` → the change is blocked and
the turn **continues** (`turn/completed` status `completed`). The broker therefore
maps a denied fileChange → `decline` (turn continues), never `cancel`. Timeout /
disconnect / close → `cancel` (the turn can't continue).

## Generic question / elicitation (schema-captured, not the primary path)

Two more server→client requests are the codex analogues of claude's
AskUserQuestion "choice" card, distinct from a command/file approval. Neither
fired during ordinary turns on this box: `item/tool/requestUserInput` is an
EXPERIMENTAL tool the model invokes only under specific app/MCP conditions (it is
NOT a togglable `experimentalFeature/list` entry — verified: no such feature in
0.132's list), and `mcpServer/elicitation/request` needs an MCP server that
elicits input. So the shapes below are from `codex app-server
generate-json-schema` (0.132.0), not a live capture. The broker handles both
(table-tested with the captured frames + stub-driven integration tests):

- **`item/tool/requestUserInput`** (EXPERIMENTAL) —
  `ToolRequestUserInputParams {itemId, threadId, turnId, questions[]}` where each
  question is `{id, header, question, options?:[{label,description}], isOther?, isSecret?}`.
  The broker surfaces the FIRST question as a pending-input card (numbered menu
  when `options` are present, free-text otherwise — the app shows a text field
  for a sentinel card with no options). Response shape:

  ```json
  {"id": <echo>, "result": {"answers": {"<questionId>": {"answers": ["<reply>"]}}}}
  ```

  (`ToolRequestUserInputResponse`.) The broker answers the first question with the
  user's tap/typed reply; any remaining questions get an empty `answers:[]` so the
  response is well-formed. Safety net (abandoned card): empty `answers:[]` for all.

- **`mcpServer/elicitation/request`** — `McpServerElicitationRequestParams` is a
  `oneOf` over **form mode** `{serverName, threadId, turnId?, mode:"form", message,
  requestedSchema}` and **url mode** `{…, mode:"url", message, url, elicitationId}`.
  The broker surfaces `message` (+ the url for url-mode) as an **Approve/Decline**
  pending-input card rather than rendering the full typed form (the `requestedSchema`
  is an arbitrary typed object — string/number/boolean/enum fields — too complex for
  the current card UI). Response shape:

  ```json
  {"id": <echo>, "result": {"action": <accept|decline|cancel>, "content"?: {…}}}
  ```

  (`McpServerElicitationRequestResponse`.) Approve → `accept` (no `content` — the
  broker doesn't collect form fields yet, so an accept may fail server-side for a
  required-field schema; this is the documented limitation). Anything else, plus
  the safety net (timeout / EOF / close / parse failure) → `decline` so the turn
  never hangs silently.

### Routing summary (broker)

`handleServerRequest` (codexappserver.go) routes by method via
`codexServerRequestKindFor`:

| Method | Kind | Card | Response |
|---|---|---|---|
| `item/commandExecution/requestApproval` | approval | command + Approve/Deny | `{decision}` |
| `item/fileChange/requestApproval` | approval | path (joined by itemId) + Approve/Deny | `{decision}` (deny→decline) |
| `item/tool/requestUserInput` | userInput | first question + options/free-text | `{answers:{id:{answers:[…]}}}` |
| `mcpServer/elicitation/request` | elicitation | message + Approve/Decline | `{action}` |
| anything else | unknown | — | `{}` (empty ack) |

## Capture technique

Spawn `codex app-server`, run the handshake, then `thread/start` with
`approvalPolicy:"untrusted"` + `sandbox:"read-only"`, then a `turn/start` whose
prompt forces a **write** (e.g. `echo hi > hello.txt`) so the command must
escalate past the read-only sandbox — that reliably triggers
`item/commandExecution/requestApproval`. A plain trusted command (`echo`,
`whoami`) is auto-approved and never prompts. Respond with the request's echoed
`id` and the chosen `decision`. The driver used for this capture lives in the
job tmp dir (`drive2.py`).

## turn/steer (mid-turn redirect) — captured live, v0.132.0

`turn/steer` is the third turn verb (alongside `turn/start` and `turn/interrupt`).
It is meant to redirect a RUNNING turn with new input WITHOUT interrupting it — a
concept claude lacks (claude can only queue a follow-up after the turn ends).

Captured live against `codex-cli 0.132.0` on the dev box (raw JSON-RPC driver in
the job tmp dir, mirroring the approval capture technique). Findings below.

### Request / response shape

The param is `expectedTurnId` (NOT `turnId` — that name is rejected). The `input`
array reuses the `turn/start` content shape.

```
C->S {"id":4,"method":"turn/steer","params":{
        "threadId":"019eb462-c740-…",
        "expectedTurnId":"019eb462-c7c9-…",
        "input":[{"type":"text","text":"Change of plans: only output PINEAPPLE."}]}}
S->C {"id":4,"result":{"turnId":"019eb462-c7c9-…"}}
```

On success the result is just `{"turnId": <same active turn id>}`. The turn is
NOT interrupted: no `turn/completed` fires for it, no new turn id is allocated,
and the existing notification stream (reasoning / agentMessage deltas) continues
under the same `turnId`.

### Error semantics (all JSON-RPC `code:-32600`)

| Condition | Error message |
|---|---|
| `expectedTurnId` omitted | `Invalid request: missing field \`expectedTurnId\`` |
| no turn in flight | `no active turn to steer` |
| `expectedTurnId` != the active turn | ``expected active turn id `X` but found `Y` `` |

The `expectedTurnId` is a compare-and-steer guard: the caller asserts which turn
it believes is running, and codex rejects the steer if a different turn is active
(prevents steering a turn that already rolled over). The broker already latches
the active turn id from `turn/started` (`c.turnID`, used today to target
`turn/interrupt`) — the exact value `turn/steer` needs.

### Original capture note: steer appeared inert in some v0.132.0 test conditions

> **This section records the original capture findings that were later revised.**
> The confirmed-working sequence at the top of this document supersedes this.
> Steer IS functional in codex-cli 0.132.0 when sent while a turn is genuinely
> in progress (turn/started seen, turn/completed not yet seen). The NO-OP result
> below was a test artifact: short turns completed before the steer arrived.

Across three early live attempts (steer sent during reasoning, before the first
`agentMessage`, and mid-`agentMessage`), the RPC was acknowledged with
`{"turnId":…}` every time, but the model appeared to ignore the steered input.
This was later diagnosed as a timing issue — the steer was delivered to turns
that had already finished, which returns the same `{"turnId":…}` ack but is a
no-op (see the `-32600 "no active turn to steer"` error semantics above for
the in-code guard). The steer text did not appear in the persisted rollout
session files in those runs.

**Conclusion (updated 2026-06-17):** steer is protocol-present AND functionally
effective in codex-cli 0.132.0 when timed correctly. The broker plumbing
proposal below remains valid for the app send-path.

### Proposal: surfacing steer in Conduit

UX concept (claude has no equivalent): when the user sends a message while a
codex turn is ACTIVE, offer a choice — **Steer** (redirect the running turn via
`turn/steer`) vs the current behavior (queue / wait for the turn to finish).
Today the codex backend rejects a concurrent `Send` with `errCodexTurnInFlight`
and the app composer is locked while a turn runs; steer would be the one path
that accepts input mid-turn.

Broker plumbing would be small and self-contained: a `Steer(text string)` method
on `*codexAppServerProcess` that writes
`turn/steer {threadId: c.threadID, expectedTurnId: c.turnID, input:[…]}` guarded
by `c.turnActive && c.turnID != ""` (the same guard `Interrupt()` uses), plus a
backend `Steer` entry on the codex `AgentBackend`. No new turn-lifecycle state is
needed — the steered turn continues under the same id and terminates normally.

**Decision at time of original capture: proposal-only, NO broker plumbing added.**
This decision was based on the (incorrect) finding that steer was a no-op.
Steer is now confirmed working (see top of this doc); the broker plumbing proposal
is valid to implement behind the existing single-turn guard. The app send-path
work belongs on the `optimistic-send-pending` branch.

## Multi-agent / sub-agents (collaboration)

Captured live against `codex-cli 0.132.0` on the dev box.

### Feature status

`multi_agent` is **stable and enabled by default** (confirmed: `codex features
list` → `multi_agent  stable  true`). The prior assumption that "codex is
single-agent only" was wrong — it was based on inspecting only `ClientRequest`
methods, which have no multi-agent entry. The actual surface is on the
**notification** side.

Experimental / disabled siblings (do not depend on these):

| Feature | State | Enabled |
|---|---|---|
| `multi_agent_v2` | under development | false |
| `child_agents_md` | under development | false |
| `enable_fanout` | under development | false |
| `goals` | experimental | false |
| `collaboration_modes` | removed | — |

`CollaborationMode/*` and `Thread/goal/*` are largely schema-only today.

### How sub-agents surface on the wire

The model spawns sub-agent threads via an internal collab tool. These surface as
`collabAgentToolCall` **thread items** on the standard `item/started` /
`item/completed` notifications (there is **no** `item/updated`). Each
`item/started` / `item/completed` payload's `.item` has `type:
"collabAgentToolCall"`.

### `CollabAgentToolCallThreadItem` fields

| Field | Type | Notes |
|---|---|---|
| `id` | string | `call_…` prefix |
| `type` | `"collabAgentToolCall"` | |
| `tool` | `CollabAgentTool` enum | `spawnAgent` \| `sendInput` \| `resumeAgent` \| `wait` \| `closeAgent` |
| `status` | `CollabAgentToolCallStatus` | `inProgress` \| `completed` \| `failed` |
| `senderThreadId` | string | threadId of the orchestrating agent |
| `receiverThreadIds` | string[] | for `spawnAgent`: the new sub-agent's threadId; empty on `item/started`, populated on `item/completed` |
| `agentsStates` | map threadId → CollabAgentState | `{status, message}` per known sub-agent |
| `prompt` | string | the prompt sent to the sub-agent |
| `model` | string | model chosen for the sub-agent |
| `reasoningEffort` | string | effort setting passed to the sub-agent |

### `CollabAgentStatus` enum

`pendingInit` | `running` | `interrupted` | `completed` | `errored` |
`shutdown` | `notFound`

### `SubAgentSource` variants

- `"review"` | `"compact"` | `"memory_consolidation"` — string enum for
  well-known internal spawn reasons.
- `ThreadSpawnSubAgentSource` — `{thread_spawn: {depth, parent_thread_id,
  agent_nickname?, agent_path?, agent_role?}}` — structured spawn from a
  thread (most tool-driven spawns).
- `OtherSubAgentSource` — `{other: string}` — catch-all.

### Sub-agent notification streams

Each spawned sub-agent emits its **own full notification stream** tagged with
its `threadId`:

- `turn/started` — sub-agent turn begins
- `item/started` + `item/completed` — items within the sub-agent turn
- `item/agentMessage/delta` — streaming tokens from the sub-agent
- `thread/tokenUsage/updated` — `{total, last, modelContextWindow}` for the
  sub-agent's thread
- `thread/status/changed`
- `turn/completed` — includes `durationMs`; terminates the sub-agent's turn

Per-sub-agent token counts, durations, and full lifecycle are all observable
via these tagged notifications.

### Known broker bug

> **Bug:** `handleNotification` / `codexNotificationToEvent`
> (`codexappserver.go` ~L661, `codexappserverwire.go` ~L374) do **not** filter
> by `threadId`. With `multi_agent` on, sub-agent `agentMessage` completions
> leak into the main chat as stray assistant messages, and a sub-agent
> `turn/completed` can fire `endTurn()` / `finishTurn()` on the parent session
> — prematurely ending the parent turn.
>
> Fix: gate all chat-emission and turn-lifecycle handling on `threadId ==
> parentThreadID` (the value latched from the initial `thread/start` result).
> Sub-agent notifications for other threadIds should be silently discarded (or
> routed to a separate sub-agent observer if one is added later). A separate
> fix is being tracked.

## Assessment: prose "numbered-list menu" -> tappable quick-replies heuristic

(Item 3 — assessment only, NOT implemented.)

**Idea.** Detect when an assistant's PROSE reply ends in a numbered (or bulleted)
list that looks like a menu of choices (e.g. "What next? 1. Fix a bug 2. Add a
feature 3. Review the code") and render those lines as tappable quick-reply
chips, recovering the card UX even when the agent answered in plain text rather
than via the structured ask.

**Where it would live.** App-side, in the chat-message renderer (iOS
`ChatMessageView` / Android equivalent), post-parsing the final assistant text.
The broker streams assistant content verbatim; it has no per-line render model,
so this is a client-side presentation concern, not a broker change.

**Feasibility.** Mechanically easy: a regex for trailing `^\s*\d+[.)]\s+\S` (or
`^\s*[-*]\s+`) lines, optionally requiring a preceding question line. The hard
part is precision, not parsing.

**False-positive risk (high).** Most numbered lists are NOT menus: step-by-step
instructions, ranked findings, code-review items, a list of files changed, an
ordered explanation. Turning "Here's what I did: 1. edited X 2. ran tests 3.
pushed" into tappable buttons is actively wrong and confusing — tapping a
"step" would send it back as a reply. Heuristics to narrow it (must follow a
question, must be the trailing block, items must be short imperatives) shrink the
hit rate and still misfire. There is no reliable signal in free text that
separates "menu of choices for YOU" from "list I'm telling you about."

**Recommendation: do NOT build the heuristic now.** Item 1 (the awareness-prompt
nudge telling agents to route choices through AskUserQuestion / the structured
ask, so they render as real cards by construction) is the clean,
non-heuristic fix and is non-destructive — it changes how the agent ASKS, not how
we guess after the fact. Ship Item 1, observe whether choices now reliably arrive
as structured asks, and only revisit the heuristic if agents keep emitting prose
menus despite the prompt. If revisited, scope it tightly: opt-in, trailing block
only, gated behind a preceding interrogative, and render as low-commitment
"suggested replies" (prefill the composer, not auto-send) to bound the
false-positive cost.
