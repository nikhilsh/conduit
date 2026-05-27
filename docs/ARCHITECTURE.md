# swe-kitty architecture

Entry point for new contributors. For the current feature set, what's next, and
the direction decisions, see [`ROADMAP.md`](ROADMAP.md).

## One-paragraph summary

A native iOS + Android client drives AI coding agents (Claude Code, Codex, …)
running on **`swe-kitty-broker`** — our own Go server that owns tmux-backed
PTYs, git worktrees, and the agent CLI processes it spawns directly on the host.
There is no Docker: per-session isolation is a git worktree + an ephemeral
`$HOME` + the PTY process tree. Each *project* is a session in the app; *within*
a session the user switches between an agent **Chat** (a structured channel,
not TUI scraping), a **Terminal** (a real shell), and a **Browser** preview.
Agents are interchangeable mid-session via `switch_agent`. Sessions are
tmux-backed and checkpointed, so they survive disconnect, backgrounding, agent
crashes, and broker restarts.

## Layers

```
┌────────────────────────────────────────────────┐
│  Mobile clients (iOS SwiftUI · Android Compose) │  ← view rendering only
└────────────────────┬────────────────────────────┘
                     │ UniFFI bindings
┌────────────────────┴────────────────────────────┐
│  swe-kitty-core (Rust)                           │  ← protocol, session model, reconnect,
│                                                  │     conversation classifier, discovery, SSH
└────────────────────┬────────────────────────────┘
                     │ WebSocket (:1977)
┌────────────────────┴────────────────────────────┐
│  swe-kitty-broker (Go)                          │  ← tmux PTYs, worktrees, agents, OAuth,
│                                                  │     AI quick-replies / titles, checkpoints
└────────────────────┬────────────────────────────┘
                     │ pty.Start (no Docker)
┌────────────────────┴────────────────────────────┐
│  Agent processes (claude, codex, …)              │  ← any CLI agent behind a TOML adapter
└──────────────────────────────────────────────────┘
```

## Read these before writing code

The first four are **frozen contracts** — they parallel-decouple work between the
server, the core, and the mobile shells. Each is focused on its own topic; they
cross-link rather than repeat.

| Layer | Doc |
|---|---|
| Wire format (Go ↔ Rust) | [`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md) |
| Long-running sessions | [`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md) |
| Agent integration | [`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md) |
| Structured chat channel | [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md) |
| Inter-agent handoff | [`MEMORY-FORMAT.md`](MEMORY-FORMAT.md) |
| Dev workflow | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |

## Repo layout

```
swe-kitty/
├── .swe-kitty/                  dev harness state (read by swe-kitty-broker on this repo)
│   ├── config.toml
│   ├── agents/                  dev-time adapter TOMLs
│   ├── tasks/                   task briefs for parallel agents
│   └── memory/                  project + session HTML memory
├── broker/                      Go server
│   ├── cmd/swe-kitty-broker/
│   └── internal/{session,ws,agents,auth,oauth,push,memory,termgrid}/
├── core/                        Rust shared core
│   ├── src/{lib,transport,session,views,conversation,discovery}.rs
│   ├── src/store/               shared reducer (SessionStoreCore)
│   ├── src/ssh/                 SSH-bootstrap pairing (russh)
│   └── swe-kitty-core.udl
├── apps/
│   ├── ios/                     SwiftUI — Sources/LitterUI/ is the default tree
│   └── android/                 Jetpack Compose (Material 3)
├── agents/                      production adapter TOMLs
├── scripts/                     install / bootstrap / ghostty fetch
├── website/                     static landing site
├── .github/workflows/           CI + release pipelines
└── docs/                        contracts + ROADMAP + ops docs
```

## Why two adapter directories

- `.swe-kitty/agents/*.toml` — what `swe-kitty-broker` reads when working **on
  this repo** (dev-time).
- `agents/*.toml` — what the broker uses when running the shipped product.

Same schema, separate scopes. A change to dev tooling never breaks the product.
Schema and process model in [`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md).

## Why no Docker

The real deploy is a single-operator box, and the broker already takes a
per-session `cwd` + an ephemeral `$HOME`, so "pick a directory and run the agent
there" needs no container. Docker added install friction (an image pull, a
non-root uid dance) with no benefit for the "my box, my agent, I trust it"
posture. The broker sets `IS_SANDBOX=1` so Claude Code accepts
`--dangerously-skip-permissions` under root. See [`ROADMAP.md`](ROADMAP.md)
"Direction & decisions" and [`SELF-HOST.md`](SELF-HOST.md).

## Why HTML for memory

Renders directly in the in-app browser, machine-readable via `data-section`
attributes, supports embedded code and structured handoff. No Markdown renderer
to ship. Schema in [`MEMORY-FORMAT.md`](MEMORY-FORMAT.md).

## Why interchangeable agents

The agent is just a CLI process. The broker doesn't know what's inside. The only
contract is: read `HANDOFF.html` on start, trap `SIGUSR1` to write
`HANDOFF-OUT.html`. Adding a new agent = one TOML adapter, no code change.
Details in [`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md).

## Why long-running matters

Phones background, networks blip, agents crash, users walk away. A session must
survive all of that without losing context. tmux keeps the PTY alive, and three
on-disk rails (scrollback ring, memory HTML, git worktree) make recovery
possible. Details in [`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md).
