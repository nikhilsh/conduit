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
  this capture omitted it from `availableDecisions`. **For deny, respond with
  `cancel`** (always available; ends the turn cleanly).
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

The broker maps a denied tap → `cancel` (clean turn end, mirrors how a denied
claude AskUserQuestion does not leave the turn spinning), and an approved tap →
`accept`.

### Timeout / disconnect

There is no server-side timeout on the request — it blocks the turn until a
response arrives. The broker mirrors claude's `askcontrol.go` policy: on
timeout, session close, or a lost client, respond `cancel` (deny) so the turn
unwedges rather than hanging forever.

## Generic question / elicitation (probed, not the primary path)

Two server→client requests are the codex analogues of claude's AskUserQuestion
"choice" card, distinct from a command approval. Neither fired during ordinary
shell-command turns (they require specific tool / MCP-server conditions to
trigger), so the shapes below are from the JSON Schema, not a live capture:

- **`item/tool/requestUserInput`** (EXPERIMENTAL) —
  `ToolRequestUserInputParams {itemId, threadId, turnId, questions[]}` where each
  question is `{id, header, question, options?:[{label,description}], isOther?, isSecret?}`.
  Response: `ToolRequestUserInputResponse {answers}`. This is the closest twin of
  AskUserQuestion (a labeled multi-question prompt). Left for a follow-up — it is
  EXPERIMENTAL and did not surface in normal turns.
- **`mcpServer/elicitation/request`** —
  `McpServerElicitationRequestParams {serverName, threadId, turnId?}`. Response:
  `McpServerElicitationRequestResponse {action, content?, _meta?}`. Fires only
  with an MCP server that elicits input.

## Capture technique

Spawn `codex app-server`, run the handshake, then `thread/start` with
`approvalPolicy:"untrusted"` + `sandbox:"read-only"`, then a `turn/start` whose
prompt forces a **write** (e.g. `echo hi > hello.txt`) so the command must
escalate past the read-only sandbox — that reliably triggers
`item/commandExecution/requestApproval`. A plain trusted command (`echo`,
`whoami`) is auto-approved and never prompts. Respond with the request's echoed
`id` and the chosen `decision`. The driver used for this capture lives in the
job tmp dir (`drive2.py`).
