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
