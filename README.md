# swe-kitty

A phone-first AI coding agent. Drive Claude Code, Codex, and other CLI agents
on your own remote box from iOS and Android — with per-project tabs for an agent
chat, a terminal, and a live browser preview.

swe-kitty is its own product. Three layers ship from this one repo: a Rust core,
a Go server (the broker), and native iOS / Android shells. The IPA, APK, and
broker binaries all come from `release.yml` in this repo and only this repo.

## Architecture

```
┌───────────────────────────────────┐
│  iOS (SwiftUI) / Android (Compose) │  per-project tabs: Chat · Terminal · Browser
└─────────────────┬─────────────────┘
                  │ UniFFI
┌─────────────────┴─────────────────┐
│  swe-kitty-core (Rust)            │  protocol, session model, reconnect, discovery, SSH bootstrap
└─────────────────┬─────────────────┘
                  │ WebSocket
┌─────────────────┴─────────────────┐
│  swe-kitty-broker (Go, :1977)     │  tmux-backed PTYs, worktrees, agent processes, OAuth
└─────────────────┬─────────────────┘
                  │ spawn + PTY
┌─────────────────┴─────────────────┐
│  agent CLIs (claude, codex, …)     │  any CLI agent behind a TOML adapter
└───────────────────────────────────┘
```

The broker runs **directly on the host** (no Docker) and spawns each agent as a
child process in a user-picked directory. Per-session isolation is a git
worktree + an ephemeral `$HOME` + the PTY process tree. Sessions are
tmux-backed, so they survive disconnect, backgrounding, and broker restarts.

## What it does

- **Structured agent chat** — clean messages, tool-call cards, per-file diffs,
  pending-input prompts, subagent / handoff cards. Driven by each agent's
  structured mode (claude stream-json, codex `exec --json`), not TUI scraping.
- **AI quick replies + AI session titles** — minted server-side by the broker.
- **Terminal** — a real bash shell per session (xterm.js by default; a native
  Ghostty path is behind an experimental flag), with an accessory key bar.
- **Interchangeable agents** — swap claude ↔ codex mid-session without losing
  the worktree, branch, or git state.
- **Fork-with-model** — fork a session onto a different model / reasoning effort.
- **Composer attachments** — send images, PDFs, and files.
- **Session history** — reopen exited sessions read-only; archive on swipe,
  permanent delete from History.
- **Connect anywhere** — LAN discovery (mDNS / NsdManager), SSH-bootstrap
  pairing, auto-reconnect, and server-side OAuth login for the agents.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full shipped / in-progress list
and the direction decisions.

## Install

- **iOS:** sideload the signed IPA from the latest
  [Release](https://github.com/nikhilsh/swe-kitty/releases) via AltStore /
  Sideloadly — [`docs/INSTALL-IOS.md`](docs/INSTALL-IOS.md).
- **Android:** install the signed APK from the latest Release —
  [`docs/INSTALL-ANDROID.md`](docs/INSTALL-ANDROID.md).

## Run your own broker

Install and run the broker on your box, then pair from the app —
[`docs/SELF-HOST.md`](docs/SELF-HOST.md).

## Docs

- **Roadmap & direction:** [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- **Frozen contracts** (read before touching broker / core / agent code):
  - [`docs/WEBSOCKET-PROTOCOL.md`](docs/WEBSOCKET-PROTOCOL.md)
  - [`docs/SESSION-LIFECYCLE.md`](docs/SESSION-LIFECYCLE.md)
  - [`docs/AGENT-ADAPTERS.md`](docs/AGENT-ADAPTERS.md)
  - [`docs/CHAT-CHANNEL.md`](docs/CHAT-CHANNEL.md)
  - [`docs/MEMORY-FORMAT.md`](docs/MEMORY-FORMAT.md)
- **Working on this repo:** [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **Releases:** [`docs/RELEASE.md`](docs/RELEASE.md), [`docs/RELEASE-IOS.md`](docs/RELEASE-IOS.md)

## Prior art

The WebSocket framing took inspiration from
[choonkeat/swe-swe](https://github.com/choonkeat/swe-swe), and the layered
Rust-core + native-shells split is the shape [dnakov/litter](https://github.com/dnakov/litter)
chose for Codex on mobile. swe-kitty has diverged on auth (bearer-only, no
cookie login), on the broker protocol (`switch_agent`, typed `view_event`,
structured chat), and on the entire mobile surface — neither upstream is a
runtime dependency or an interoperability target.
