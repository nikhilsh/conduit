# Chat ↔ agent channel (reference)

How the **Chat** tab is fed. The Chat tab is driven by each agent's
**structured** output mode — not by scraping the TUI. The Terminal tab is a
separate bash shell on the PTY. This is the contract; the wire shape it produces
is [`view_event { view: "chat" }`](WEBSOCKET-PROTOCOL.md#32-server--client).

## Why structured, not scraped

The original design wrote the user's message to the agent's interactive TUI over
the PTY and scraped the reply back out of raw terminal bytes
(`chatScraper`). On device this was unreliable in both directions: `\r` didn't
reliably submit Claude Code's Ink TUI, replies only surfaced when primed from
the chat tab, and TUI chrome (status/header lines, box-drawing) leaked into chat
bubbles. The fix was to drive chat from each agent's programmatic mode instead.
The PTY scraper survives only as a fallback (see §4).

## Mechanism

Per session the broker runs the agent **headless in structured mode** as the
source of truth for Chat: it writes the user's composer messages to the agent's
stdin as structured input events, reads structured events from stdout, and emits
them as `view_event { view: "chat", … }`:

- text deltas → assistant bubbles
- `tool_use` blocks → `role: "tool"` events the conversation classifier renders
  as tool cards (`core/src/conversation.rs`)

A `chatBackend` interface picks the backend by the adapter's `chat_mode`. The
Terminal tab gets a **bash shell** on the PTY (clean separation: agent = chat,
terminal = shell).

## Per-agent backends

| Agent | `chat_mode` | How it runs |
|---|---|---|
| claude | `stream-json` | `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose`; composer → stdin `user` events; stdout → chat events. Parser `claudestream.go`, mappers `claudechat.go`. |
| codex | `codex-exec` | `codex exec --json` for the first turn (captures `thread_id`), then `codex exec resume <thread_id> --json` per message. Parser `codexstream.go`. |

`chat_mode` is an embedded default per adapter. An unexpected agent exit
publishes a `role: "system"` chat notice rather than going silent.

## Fallback

`chat_mode == ""` keeps the legacy PTY-agent + `chatScraper` path as a fallback
for adapters that don't declare a structured mode. The scraper was *not* deleted
— it is fallback-only.

## Open follow-ups

- codex tool-item (`command_execution`) cards
- codex approval / sandbox-bypass for chat
- partial-message live typing
