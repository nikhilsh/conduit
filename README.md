# swe-kitty

A phone-first AI coding harness. Drive Claude Code, Codex, and other agents from iOS and Android with per-project tabs for terminal, agent chat, and live preview. Built itself under a multi-agent dev harness.

```
┌───────────────────────────────┐
│  iOS / Android (SwiftUI /     │
│  Compose) — per-project tabs: │
│  Terminal · Chat · Browser    │
└───────────────┬───────────────┘
                │ UniFFI
┌───────────────┴───────────────┐
│  swe-kitty-core (Rust)        │
└───────────────┬───────────────┘
                │ WebSocket
┌───────────────┴───────────────┐
│  swe-kitty-harness (Go)       │
│  PTY · worktrees · Docker     │
└───────────────────────────────┘
```

## Start here

- **Full plan + roadmap:** [`docs/PLAN.md`](docs/PLAN.md)
- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- **Frozen contracts** (read these before writing any harness/core/agent code):
  - [`docs/WEBSOCKET-PROTOCOL.md`](docs/WEBSOCKET-PROTOCOL.md)
  - [`docs/AGENT-ADAPTERS.md`](docs/AGENT-ADAPTERS.md)
  - [`docs/MEMORY-FORMAT.md`](docs/MEMORY-FORMAT.md)
  - [`docs/SESSION-LIFECYCLE.md`](docs/SESSION-LIFECYCLE.md)
- **Working on this repo (under harness):** [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Install (post-v0.4)

- iOS: sideload the signed IPA from the latest [Release](https://github.com/nikhilsh/swe-kitty/releases) via AltStore / Sideloadly. See [`docs/INSTALL-IOS.md`](docs/INSTALL-IOS.md).
- Android: install the signed APK from the latest Release. See [`docs/INSTALL-ANDROID.md`](docs/INSTALL-ANDROID.md).

## Website

- Static landing site scaffold: [`website/`](website)
- Fyrra deploy notes: [`website/DEPLOY.md`](website/DEPLOY.md)

## Status

Bootstrap. See [`docs/PLAN.md`](docs/PLAN.md) Part F — Roadmap.

## References

Stands on the shoulders of:
- [choonkeat/swe-swe](https://github.com/choonkeat/swe-swe) — server-side harness model (Go, PTY, worktrees, WebSocket, per-project multi-view)
- [dnakov/litter](https://github.com/dnakov/litter) — mobile client model (Rust core, UniFFI, iOS+Android shells)
