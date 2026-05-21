# swe-kitty architecture

Entry point for new contributors. For full motivation, roadmap, and v1 scope, see [`PLAN.md`](PLAN.md).

## One-paragraph summary

A native iOS + Android client drives AI coding agents (Claude Code, Codex, …) running on **`swe-kitty-broker`** — our own Go server that owns PTYs, git worktrees, and Docker-spawned agent containers. Each *project* is a tab in the app; *within* a project, the user switches between Terminal / Agent Chat / Browser-preview views. Agents are interchangeable mid-session via a structured HTML handoff document. The broker checkpoints session state every 60s; long-running sessions survive crashes, network blips, and agent swaps.

## Layers

```
┌────────────────────────────────────────────────┐
│  Mobile clients (iOS SwiftUI · Android Compose) │  ← view rendering only
└────────────────────┬────────────────────────────┘
                     │ UniFFI bindings
┌────────────────────┴────────────────────────────┐
│  swe-kitty-core (Rust)                           │  ← protocol, session model, discovery
└────────────────────┬────────────────────────────┘
                     │ WebSocket
┌────────────────────┴────────────────────────────┐
│  swe-kitty-broker (Go)                          │  ← PTY, worktrees, Docker, checkpoints
└────────────────────┬────────────────────────────┘
                     │ docker run
┌────────────────────┴────────────────────────────┐
│  Agent containers (claude, codex, …)             │  ← any CLI agent behind a TOML adapter
└──────────────────────────────────────────────────┘
```

## Read these before writing code

| Layer | Doc |
|---|---|
| Wire format (Go ↔ Rust) | [`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md) |
| Agent integration | [`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md) |
| Inter-agent handoff | [`MEMORY-FORMAT.md`](MEMORY-FORMAT.md) |
| Long-running sessions | [`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md) |
| Dev workflow | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |

These four `docs/*.md` are **frozen contracts** — they parallel-decouple work between server, core, and mobile shells.

## Repo layout

```
swe-kitty/
├── .swe-kitty/                  dev harness state (read by swe-kitty-broker)
│   ├── config.toml
│   ├── agents/                  dev-time adapter TOMLs
│   ├── tasks/                   task briefs for parallel agents
│   └── memory/                  project + session HTML memory
├── broker/                     Go server
│   ├── cmd/swe-kitty-broker/
│   └── internal/{session,ws,agents,auth,memory}/
├── core/                        Rust shared core
│   ├── src/{lib,transport,session,views,discovery}.rs
│   └── swe-kitty-core.udl
├── apps/
│   ├── ios/                     SwiftUI + SwiftTerm
│   └── android/                 Compose + termux-terminal-view
├── agents/                      production adapter TOMLs
├── .github/workflows/           CI + release pipelines
└── docs/                        the four contracts + PLAN.md
```

## Why two adapter directories

- `.swe-kitty/agents/*.toml` — what `swe-kitty-broker` reads when working **on this repo** (dev-time)
- `agents/*.toml` — what **swe-kitty-broker** uses when running the shipped product

Same schema, separate scopes. A change to dev tooling never breaks the product.

## Why HTML for memory

Renders directly in the in-app browser, machine-readable via `data-section` attributes, supports embedded code and structured handoff. No Markdown renderer to ship. Schema in `MEMORY-FORMAT.md`.

## Why interchangeable agents

The agent is just a CLI in a Docker container connected to a PTY. The broker doesn't know what's inside. The only contract is: read `HANDOFF.html` on start, trap `SIGUSR1` to write `HANDOFF-OUT.html`. Adding a new agent = one TOML + one Dockerfile.

## Why long-running matters

Phones background, networks blip, agents crash, users walk away. A v1 session must survive all of that without losing context. Three rails on disk (scrollback ring, memory HTML, git worktree) make this possible. Details in `SESSION-LIFECYCLE.md`.
