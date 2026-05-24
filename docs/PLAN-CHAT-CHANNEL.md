# PLAN — chat ↔ agent channel (device bug #6 / task #24)

Date: 2026-05-24. Decision needed from the maintainer before implementing.

## The problem (observed on v0.0.30)

The Chat tab is unreliable in both directions because **there is no
structured chat channel — the broker scrapes the agent's TUI output from
the PTY.**

- Inbound: `ws/server.go` "chat" handler writes `msg + "\r"` to the agent's
  PTY stdin and primes `chatScraper.markUserSent`.
- Outbound: `session/chatscraper.go` buffers raw PTY bytes and, after ~700ms
  idle, emits one `view_event {view:"chat", role:"assistant", content}`.
  It strips ANSI and suppresses the echoed input, but is "deliberately not a
  TUI parser."

Failure modes seen on device:
1. **claude send didn't submit** — `\r` doesn't reliably submit Claude
   Code's Ink TUI; the text sat in the prompt until the user pressed Return
   in the Terminal tab.
2. **Reply only when primed from chat** — the scraper only captures a reply
   when `markUserSent` ran (a chat-tab send). Submitting from the Terminal
   tab leaves `awaiting=false`, so claude's reply never reached Chat.
3. **TUI chrome leaks in** — codex's reply showed as
   `Higpt-5.5 default · /root/.swe-kitty/…`: the scraper caught codex's
   status/header line, not just the message.
4. **Interactive prompts missed** — codex's "trust this directory?" prompt
   never surfaced in Chat (only Terminal).

Root issue: both agents run in **full interactive TUI mode** (`claude
--dangerously-skip-permissions`, `codex --dangerously-bypass-…`), the
richest, messiest possible output to scrape.

## Option A — Harden the scraper (broker-only, incremental)

Improve `chatScraper`: strip status/header lines + box-drawing chrome,
better turn-boundary detection, prime on *any* submit (not just chat-tab
sends), surface interactive prompts as pending-input chat events, and fix
submit (bracketed paste / explicit key event instead of a lone `\r`).

- **Pros:** no agent cooperation; works for any CLI agent; pure Go, locally
  unit-testable; ships in days; keeps the one-PTY model.
- **Cons:** fundamentally a heuristic — always fragile against TUI redraws,
  spinners, partial streaming; never fully clean; tool-call/diff cards stay
  approximate.

## Option B — Structured channel (the real fix)

Drive the **chat** tab from each agent's structured/programmatic output mode
rather than the TUI: e.g. Claude Code's `--print --output-format
stream-json` / Agent SDK, and Codex's equivalent JSON/exec mode — surfaced
to the broker over the already-declared `AGENT_CHAT_PORT`
(`chat_event_port_env` in the TOMLs, currently unwired). The Terminal tab
keeps a PTY for those who want the raw TUI.

- **Pros:** clean messages, reliable submit, real tool-call/diff/pending-
  input events — what the conversation cards were built for. The only path
  to a *trustworthy* chat tab.
- **Cons:** agent-specific integration (each agent's structured mode wired
  separately); larger effort; must reconcile "structured chat process" vs
  "PTY terminal process" (two modes, or derive the terminal from structured
  events); exact flags per agent to confirm.

## Recommendation

**Hybrid, in two steps:**

1. **Now (Option A, small):** harden the scraper so Chat is *usable* —
   strip chrome, prime on any submit, fix claude submit. Broker-only,
   testable, ships fast. Makes the v0.0.31-class experience tolerable.
2. **Next (Option B, the real fix):** wire the structured channel over
   `AGENT_CHAT_PORT`, starting with Claude Code's stream-json/SDK. This is
   what makes Chat actually reliable and unlocks proper cards.

**Decision needed:** (a) hybrid as above, (b) jump straight to Option B
(skip scraper hardening), or (c) Option A only for now. I'll implement once
you pick. My lean: **(a)** — it gets you a working chat tab immediately
without blocking on the bigger per-agent integration.

## DECISION (2026-05-24): Option B — structured channel

Maintainer picked **B**: skip scraper hardening, build the real structured
channel.

### Grounding (verified on the box, not docs)

- **Claude Code 2.1.150** has a turnkey bidirectional protocol:
  `claude -p --input-format stream-json --output-format stream-json
  --include-partial-messages`. Verified event stream (NDJSON, one JSON
  object per line, `type` field):
  - `system`/`init` — session metadata (model, tools, mcp_servers,
    session_id, cwd, permissionMode).
  - `stream_event` — partial deltas (`--include-partial-messages`).
  - `assistant` — `{message:{role,model,content:[{type:"text",text}|
    {type:"tool_use",name,input}]}}`.
  - `result` — terminal per turn: `{subtype,is_error,result,duration_ms,
    total_cost_usd,session_id}`.
  - Input: write `{"type":"user","message":{"role":"user","content":
    [{"type":"text","text":"…"}]}}` to stdin.
- **Codex 0.132.0** has `codex exec` (non-interactive) and `codex
  mcp-server` (stdio MCP). Codex's structured streaming shape still needs a
  short spike (slice 4).

### Mechanism

Per session, the broker runs the agent in **structured stream-json mode** as
the source of truth for the Chat tab: it writes the user's composer messages
to stdin as stream-json `user` events, reads `assistant`/`result`/partial
events from stdout, and emits them as the existing
`view_event{view:"chat", …}` (text → assistant bubbles; `tool_use` →
the structured tool payload the conversation classifier already renders).
No PTY scraping. `chatScraper` is retired for agents that support
stream-json.

### Open sub-decision (need your call before I wire the session)

stream-json is **headless** — there's no TUI to attach the Terminal tab to.
So what becomes of the Terminal tab?

- **B-i (recommended):** the Terminal tab becomes a **real shell** (bash) in
  the session's workspace — genuinely useful (git/ls/build), cleanly
  separated from the agent. Agent = structured chat; terminal = shell.
- **B-ii:** render a **plain-text transcript** of the structured stream in
  the Terminal tab (read-only mirror of chat).
- **B-iii:** **drop** the Terminal tab for stream-json agents.

My lean: **B-i** — it's the most useful and the cleanest separation.

### Slices

1. Broker: `claude` stream-json parser → chat `view_event` (pure, unit-
   tested against the captured fixtures). *(no rearchitecture)*
2. Broker: structured-session mode — spawn claude in stream-json, pipe
   composer messages to stdin, stream events out; feature-flag it per
   adapter (`chat_mode = "stream-json"`).
3. Terminal-tab reconciliation per the sub-decision above.
4. Codex: spike `codex exec`/`mcp-server` structured output; add its adapter.
5. Retire `chatScraper` once both agents are on the structured path.

## Status (2026-05-25): shipped

The structured channel is **implemented and the default for both agents**:

- **claude** — `chat_mode="stream-json"` (embedded default). Runs headless
  `claude -p --input-format stream-json --output-format stream-json
  --include-partial-messages --verbose`; `chatProcess` pipes the composer to
  stdin and maps stdout → chat `view_event`s (`claudestream.go` parser +
  `claudechat.go` mappers). Device-verified (clean replies, shell terminal).
- **codex** — `chat_mode="codex-exec"` (embedded default). `codexChatProcess`
  runs `codex exec --json` (first turn, captures `thread_id`) then `codex
  exec resume <thread_id> --json` per message (`codexstream.go` parser);
  multi-turn context verified on codex-cli 0.132. Sandboxed for now.
- **Backend selection** — a `chatBackend` interface + `structuredChatBackend()`
  pick claude vs codex by `chat_mode`; the session spawns a **bash shell** on
  the PTY (Terminal tab, B-i) and runs the backend headless. `chat_mode==""`
  keeps the legacy PTY-agent + `chatScraper` path **as a fallback** (slice 5
  = "scraper is fallback-only", not deleted).
- **Tool cards** — `tool_use` blocks → `role:"tool"` `"Name: <summary>"`
  events the client classifier renders as cards.
- **Hardening** — an unexpected agent exit publishes a `role:"system"` chat
  notice instead of going silent.

Follow-ups (not blocking, need on-device confirmation of the codex path
first): codex tool-item (`command_execution`) cards; codex
approval/sandbox-bypass for chat; partial-message live typing.
