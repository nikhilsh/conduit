# swe-kitty

A phone-first AI coding broker. Drive Claude Code, Codex, and other agents from iOS and Android with per-project tabs for terminal, agent chat, and live preview.

swe-kitty is its own product — three layers (Rust core, Go broker, native shells) that all ship from this repo. Its WebSocket wire shape is documented in `docs/WEBSOCKET-PROTOCOL.md`; the broker, IPA, APK, and broker binaries all come from `release.yml` in this repo and only this repo.

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
│  swe-kitty-broker (Go)       │
│  PTY · worktrees · Docker     │
└───────────────────────────────┘
```

## Start here

- **Full plan + roadmap:** [`docs/PLAN.md`](docs/PLAN.md)
- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- **Frozen contracts** (read these before writing any broker/core/agent code):
  - [`docs/WEBSOCKET-PROTOCOL.md`](docs/WEBSOCKET-PROTOCOL.md)
  - [`docs/AGENT-ADAPTERS.md`](docs/AGENT-ADAPTERS.md)
  - [`docs/MEMORY-FORMAT.md`](docs/MEMORY-FORMAT.md)
  - [`docs/SESSION-LIFECYCLE.md`](docs/SESSION-LIFECYCLE.md)
- **Working on this repo:** [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **Running your own broker:** [`docs/SELF-HOST.md`](docs/SELF-HOST.md)

## Install (post-v0.4)

- iOS: sideload the signed IPA from the latest [Release](https://github.com/nikhilsh/swe-kitty/releases) via AltStore / Sideloadly. See [`docs/INSTALL-IOS.md`](docs/INSTALL-IOS.md).
- Android: install the signed APK from the latest Release. See [`docs/INSTALL-ANDROID.md`](docs/INSTALL-ANDROID.md).

## Website

- Static landing site scaffold: [`website/`](website)
- Fyra deploy notes: [`website/DEPLOY.md`](website/DEPLOY.md)

## Delivery Status (May 21, 2026)

### Done
- Broker runtime and pairing flow are live:
  - one-line installer: `install.sh`
  - `swe-kitty-broker up --local` prints token + pairing QR + `swekitty://` deep link
  - `harness/` → `broker/` rename complete (PR #19); Dockerfile + docker-compose paths updated (PR #34)
  - `/healthz` endpoint with sidecar liveness probe (PR #26)
- Release pipeline is live:
  - `release-ios`, `release-android`, `release-broker`, `release-orchestrator`
  - website pulls latest release assets and deploys via Fyra
- Mobile chat has moved past plain logs (verified in `apps/ios/Sources/Views/ConversationView.swift` + `apps/android/.../ui/ChatPage.kt`):
  - tool-call cards (`ConversationToolCard`)
  - diff rendering with per-file grouping (`ConversationDiffBlock` / `DiffFileSection`)
  - quick-reply chips (`QuickReplyDetector`)
  - typed conversation-item foundation in shared Rust core (`core/src/conversation.rs`)
  - structured tool payload: `tool_name`, `exit_code`, `duration_ms`, `diff_summary` populated by the Rust classifier
  - pending-input cards with typed reply options (`PendingInputCard` / `ConversationPendingInputCard`)
  - subagent + handoff cards (`SubagentCard` / `HandoffCard` on both platforms)
- Multi-server persistence scaffolding exists in app settings:
  - iOS: Keychain-backed saved servers
  - Android: EncryptedSharedPreferences-backed saved servers
- Test discipline (today, 2026-05-21):
  - iOS `SweKittyTests` target with 20+ tests (PR #20)
  - Android JUnit harness + TerminalBridge tests (PR #21)
  - core E2E WebSocket round-trip tests (PR #25)
  - swift-snapshot-testing + Roborazzi wired (PR #30); CI uploads xcresult + diff dirs on failure (PR #31)

### In Progress
- Package 1 (Rust-first refactor): `core/src/store/` `AppStore` with snapshots + subscriber callbacks; iOS/Android `SessionStore` to project from the Rust store. Slices 1 & 2 (typed conversation classifier + tool-card consumption) shipped; slice 3 (reducer to Rust) open. See [`docs/PLAN-2026-05-19.md`](docs/PLAN-2026-05-19.md) §8.

### Planned (not started or partial)
- Discovery view (mDNS browser UI)
- Push notifications + background wake/reconnect (Package 5; no `broker/internal/push/` yet, no APNs/FCM client)
- Voice rail B (realtime WebRTC) — rail A (Whisper-style push-to-talk) shipped per `docs/PLAN-2026-05-19.md` §8
- Deeper composer parity (attach sheet, context bar, expanded editor)

Authoritative roadmap remains in:
- [`docs/PLAN.md`](docs/PLAN.md)
- [`docs/MOBILE-FEATURE-BACKLOG.md`](docs/MOBILE-FEATURE-BACKLOG.md)
- [`docs/RELEASE.md`](docs/RELEASE.md)

## Prior art

The original WebSocket framing took inspiration from [choonkeat/swe-swe](https://github.com/choonkeat/swe-swe), and the layered Rust-core + native-shells split is the same shape [dnakov/litter](https://github.com/dnakov/litter) chose for Codex on mobile. swe-kitty has diverged on auth (bearer-only, no cookie login), on the broker protocol (`switch_agent`, typed `view_event`, the structured memory HTML), and on the entire mobile surface, so neither upstream is a runtime dependency or an interoperability target — they're references, not parents.
