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
│  PTY · worktrees · agents     │
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

## Delivery Status (May 24, 2026)

Latest release: **`v0.0.29`** (2026-05-24) — IPA + APK + cross-compiled broker binaries via `release.yml`.

### Done (May 24 session)
- **Docker dropped entirely — bare-box model.** The broker runs directly on the host and spawns each agent as a child process (`pty.Start`); per-session isolation is a git worktree + ephemeral `$HOME` + the PTY tree, not a container. Deleted `broker/docker/*`, removed the release GHCR image job, rewrote `remote-bootstrap.sh` to install + run the static binary, made the adapter `image` field legacy/ignored, and rewrote `SELF-HOST.md` / `AGENT-ADAPTERS.md` / `ARCHITECTURE.md` (PRs #161, #163, #164, #165).
- **Agent OAuth v2 wired on both platforms** (broker-driven `start_agent_login` / `agent_login_callback` / `cancel_agent_login`; inbound `agent_login_*` view_events delivered through the Rust core and routed iOS + Android): #152 (iOS UDL bridge), #154 (inbound core delivery + routing — fixed a core bug that dropped `view:"status"` frames), #155 (Android `AgentLoginSheet` via Custom Tabs). Device end-to-end verification still pending.
- **On-device bug fixes** from the first real device test: claude no longer crash-loops under root (`IS_SANDBOX=1`, #158); chat-send failures surface instead of being silently swallowed (#159); the blank Ghostty terminal no longer ships (gated behind Stage-5, always xterm, #160).
- **Push scaffolding (Package 5, broker side):** per-identity device-token `Registry` → `Notifier` → `Sender` fan-out `Dispatcher` with dead-token pruning, plus `register_push_token` / `unregister_push_token` WS handlers (`broker/internal/push/`, #156, #157, #162). APNs/FCM senders + the device-side token registration are the remaining gap.
- Releases `v0.0.26`–`v0.0.29` cut and verified green.

### Done
- Broker runtime and pairing flow are live:
  - one-line installer: `install.sh`
  - `swe-kitty-broker up --local` prints token + pairing QR + `swekitty://` deep link
  - `harness/` → `broker/` rename complete (PR #19); deploys as a single static binary, no container (Docker dropped — see the May 24 session above)
  - `/healthz` endpoint with sidecar liveness probe (PR #26)
  - per-session HOME isolation (PR #126) so concurrent agents don't race on OAuth refresh; empty `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` env vars stripped before spawn (PR #135) so install-template placeholders can't clobber OAuth fallback.
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
- Multi-server persistence + delete affordances:
  - iOS: Keychain-backed saved servers; swipe + context-menu delete with confirmation alert (PR #128)
  - Android: EncryptedSharedPreferences-backed saved servers; long-press dialog mirror (PR #136)
  - both go through `SessionStore.forgetServer` which sweeps the per-id displayName override
- **iOS LitterUI cutover (PR #118 → #127)**: parallel litter-faithful view tree built clean-room, flipped from `experimentalLitterUI` flag to default, legacy tree deleted. iPad NavigationSplitView for regular size class (PR #122). Visual-parity gap audit in [`docs/PLAN-LITTER-VISUAL-PARITY.md`](docs/PLAN-LITTER-VISUAL-PARITY.md) sequences the next 5 per-screen rebuild PRs.
- **iOS Ghostty terminal Stage 4 (PR #129, #131, #133, #134, #137)**: real libghostty App/Surface integration via Lakr233's `libghostty-spm` xcframework with full link path. The terminal tab is xterm.js for now — Ghostty is gated behind Stage-5 and the user-facing toggle was removed in #160 (it rendered a blank screen because the renderer isn't wired yet).
- Test discipline (today, 2026-05-23):
  - iOS `SweKittyTests` target with 20+ tests (PR #20) — adds `SessionStoreForgetServerTests` (PR #128)
  - Android JUnit harness + TerminalBridge tests (PR #21) — adds `SessionStoreForgetServerTest` (PR #136)
  - core E2E WebSocket round-trip tests (PR #25)
  - swift-snapshot-testing + Roborazzi wired (PR #30); CI uploads xcresult + diff dirs on failure (PR #31)

### In Progress
- Package 1 (Rust-first refactor): `core/src/store/` `AppStore` with snapshots + subscriber callbacks; iOS/Android `SessionStore` to project from the Rust store. Slices 1 & 2 (typed conversation classifier + tool-card consumption) shipped; slice 3 (reducer to Rust) open. See [`docs/PLAN-2026-05-19.md`](docs/PLAN-2026-05-19.md) §8.
- Litter visual parity: 5-PR per-screen rebuild plan in [`docs/PLAN-LITTER-VISUAL-PARITY.md`](docs/PLAN-LITTER-VISUAL-PARITY.md). PR 1 (foundation: typography, tokens, glass) is ready to start.
- Agent OAuth v2: wired end-to-end on both platforms (see the May 24 session above); remaining work is device verification and deleting the v1 `OAuthClient` / `set_agent_credentials` path — [`docs/PLAN-AGENT-OAUTH.md`](docs/PLAN-AGENT-OAUTH.md).
- Terminal Stage 3 (selection / copy / paste): iOS done, Android pending — see [`docs/PLAN-TERMINAL-REWRITE.md`](docs/PLAN-TERMINAL-REWRITE.md).

### Planned (not started or partial)
- Discovery view (mDNS browser UI)
- Push notifications + background wake/reconnect (Package 5): broker-side registry + dispatcher landed (`broker/internal/push/`); APNs/FCM senders and the device-side token registration are still to do
- Voice rail B (realtime WebRTC) — rail A (Whisper-style push-to-talk) shipped per `docs/PLAN-2026-05-19.md` §8
- Deeper composer parity (attach sheet, context bar, expanded editor)

Authoritative roadmap remains in:
- [`docs/PLAN.md`](docs/PLAN.md)
- [`docs/PLAN-2026-05-19.md`](docs/PLAN-2026-05-19.md) (execution layer)
- [`docs/RELEASE.md`](docs/RELEASE.md)

## Prior art

The original WebSocket framing took inspiration from [choonkeat/swe-swe](https://github.com/choonkeat/swe-swe), and the layered Rust-core + native-shells split is the same shape [dnakov/litter](https://github.com/dnakov/litter) chose for Codex on mobile. swe-kitty has diverged on auth (bearer-only, no cookie login), on the broker protocol (`switch_agent`, typed `view_event`, the structured memory HTML), and on the entire mobile surface, so neither upstream is a runtime dependency or an interoperability target — they're references, not parents.
