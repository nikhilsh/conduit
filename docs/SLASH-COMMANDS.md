# Slash-command recognition & routing

How conduit should recognise `/`-prefixed commands typed in the chat
composer (e.g. `/compact`, `/clear`, `/model`, `/loop`) and route each to
the right place: the underlying agent CLI, an in-app handler, or a polite
"not supported here" message.

Status: **design + phased plan.** Slice 0 (this doc) records the mechanism;
the code slices below are scoped but not all shipped.

## How a message flows today

Composer text travels verbatim, end to end — nothing inspects it for a
leading `/`:

- App: `SessionStore.sendChat` → core `send_chat` (core/src/lib.rs) emits
  `{"type":"chat","from":"mobile","msg":<text>}` over the WS.
- Broker: `serveWS` `case "chat"` → `Session.SendChat` → the agent:
  - **Claude** (`chat_mode=stream-json`): `claudechatproc.go` wraps text as
    a stream-json `{"type":"user",...}` line to the subprocess stdin.
  - **Codex** (`chat_mode=codex-exec`): `codexchatproc.go` runs
    `codex exec --json "<msg>"`.
  - **Legacy TUI**: raw `msg + "\r"` into the PTY.

## What the CLIs accept

| Command | Claude (stream-json headless) | Codex (`codex exec`) | Codex app-server |
|---|---|---|---|
| `/compact` | **Yes** — CLI intercepts; broker surfaces compaction events | **No** (exec mode, openai/codex#3641) | **Yes** — broker routes to `thread/compact/start` |
| `/clear` | **Yes** — CLI intercepts; emits new `session_id` on `system/init`, synthetic assistant event suppressed by broker, "✓ Context cleared" system line published | **No** (exec mode) | **Yes** — broker orchestrates fresh `thread/start` on same app-server process; new thread has no memory of old one |
| `/context`, `/usage` | **Yes** — CLI pass-through | **No** | No equivalent |
| `/model`, `/effort` | No — spawn-time only | No | No |
| custom `.claude/commands/*` | **Yes** — SDK-dispatchable | n/a | n/a |
| `/loop`, `/help` | n/a — not a CLI concept | n/a | n/a |

## `/clear` implementation details (shipped)

**Claude stream-json backend** (PR feat/clear-command):
- The CLI intercepts `/clear` from stdin and emits exactly three lines:
  1. `{"type":"system","subtype":"init","session_id":"<NEW-UUID>"}` — new session id; broker re-latches via existing `latchChatSessionID`.
  2. Synthetic assistant: `{"type":"assistant","message":{"model":"<synthetic>",...,"content":[{"type":"text","text":"(no content)"}]}}` — suppressed by `parseClaudeStreamLine` (`model=="<synthetic>"` guard).
  3. `{"type":"result","subtype":"success","num_turns":0}` — turn end; `chatProcess.expectingClear` flag causes `publishChatSystem("✓ Context cleared — starting fresh.")`.
- `supports.clear = true` in `/api/capabilities` for this backend.

**Codex app-server backend** (PR feat/clear-command):
- Codex 0.141.0 has no native clear/reset. The broker sends a new `thread/start` on the SAME running `codex app-server` process.
- Live-verified: a second `thread/start` on the same process returns a distinct thread id with no context from the prior thread.
- `codexAppServerProcess.clearThread()`: allocates a fresh JSON-RPC id, sets `clearReqID + clearRespCh`, writes `thread/start`, waits for result, calls `forceLatchThread(newID)`, publishes "✓ Context cleared".
- `supports.clear = true` in `/api/capabilities` for this backend.

**Capability flag**: `BackendCapabilities.Clear bool` → `AgentSupports.Clear bool` → `supports.clear` JSON field. Apps gate the `/clear` composer action on this flag (separate PR).

Sources: Claude Code SDK slash-commands & CLI reference (code.claude.com),
Codex non-interactive docs (developers.openai.com), openai/codex#3641.

## Classification

Three classes, recognised only when the trimmed draft starts with `/`:

- **pass-through** — send the text to the agent unchanged. Works for
  Claude stream-json (`/compact`, `/clear`, `/context`, `/usage`, custom
  commands). Not available on Codex/TUI → show an in-chat note.
- **app-handled** — conduit intercepts; never reaches the agent:
  - `/model [name]`, `/effort [level]` → open the existing fork-with-model
    / fork-with-effort flow (model can't change mid-session in stream-json).
  - `/loop [interval] [prompt]` → a conduit client loop (repeated
    `sendChat`); unrelated to Claude Code's own interactive `/loop`.
  - `/help` → a client-rendered help card listing recognised commands.
- **terminal-only** — everything else; informational only.

## Phased plan

**Slice 1 — client recognition (no protocol change):**
- A shared `SlashCommandRegistry` (Android `ui/SlashCommandRegistry.kt`,
  iOS `SlashCommandRegistry.swift`): `name`, `aliases`, `class`,
  `agentConstraint`, `description`. Pure data — unit-testable.
- A `/` autocomplete overlay over the composer (Android `ChatPage.kt`, iOS
  `ConduitChatView.swift`), filtered by typed prefix. (Pairs with the upstream
  `@/$//` autocomplete gap in MOBILE-PORT-MATRIX.)
- In the send path, `classify(draft)` before sending: pass-through → send
  as-is (Claude only; Codex → in-chat "not supported with this agent");
  app-handled → run the handler, don't send.

**Slice 2 — feedback (small broker change):**
- `processClaudeStreamOutput` (broker `claudechat.go`) currently ignores
  `system`-subtype events, so a successful `/compact` is invisible. Handle
  the `compact_boundary` system event → publish a chat system message
  ("Context compacted"). **Needs a real stream-json capture to pin the
  exact event shape before coding** (same discipline as the codex fixture
  in `codexstream_test.go`).

**Slice 3 — codex `command_execution` cards (separate, prerequisite: a real capture):**
- `codex exec --json` emits `item.completed{item:{type:"command_execution", …}}`
  which the broker parser drops today (only `agent_message` surfaces — see
  `codexstream.go` / `codexstream_test.go`). To render these as tool cards
  we need a captured `command_execution` line to learn its real field names
  (command / output / exit code); `ClaudeChatEvent` already has
  `ToolName` + `ToolInput` to carry it. Do NOT guess the schema blind.

**Not feasible without upstream / spawn changes:**
- Codex slash-command pass-through (openai/codex#3641, open).
- Mid-session `/model` switch in stream-json (model is spawn-time only;
  use fork).

## First code slice recommendation

Ship Slice 1 (registry + autocomplete + routing) behind the existing chat
composer; it needs no broker/core protocol change and is the highest-value,
lowest-risk start. Slices 2–3 require capturing real CLI output first.
