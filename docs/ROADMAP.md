# swe-kitty roadmap

Single source of truth for what swe-kitty does today, what's next, and the
direction decisions that supersede the older `PLAN-*` docs. The forward-looking
content that used to be scattered across those plans now lives here; the plans
themselves are archived once their work ships (see `docs/archive/`).

Last updated: 2026-05-27 (`v0.0.51`).

For wire-level / lifecycle / adapter detail, read the frozen contracts:
[`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md),
[`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md),
[`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md),
[`CHAT-CHANNEL.md`](CHAT-CHANNEL.md),
[`MEMORY-FORMAT.md`](MEMORY-FORMAT.md).

---

## Shipped

Every feature below lands on **iOS and Android together** unless noted, and is
backed by a tagged GitHub Release built from `.github/workflows/release.yml`.

### Sessions & the broker

- **Bare-box broker.** The Go broker (`broker/`) runs directly on the host and
  spawns each agent as a child process (`pty.Start`). No Docker. Per-session
  isolation is a git worktree + an ephemeral `$HOME` + the PTY process tree.
- **tmux-backed PTYs.** Sessions survive disconnect, backgrounding, and broker
  restarts because the PTY lives in a tmux server, not the WebSocket.
- **Three persistence rails** (scrollback ring, memory HTML, git worktree) —
  see [`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md).
- **Session history.** Exited sessions reopen read-only; the transcript is
  persisted to `conversation.jsonl` and served by the broker
  (`broker/internal/session/convlog.go`).
- **Two-tier delete.** Swipe = archive (moves the session dir to
  `archived-sessions/<id>`, keeping `conversation.jsonl` + `work/`); permanent
  delete is only reachable from History (`broker/internal/session/delete.go`).
- **Fork-with-model.** Fork a session onto a fresh one, choosing reasoning
  effort and (optionally) a different model from a per-assistant dropdown —
  claude opus/sonnet/haiku, codex gpt-5-codex
  (`apps/ios/.../LitterForkSheet.swift`, core `fork_session`).
- **Composer attachments.** Images / PDFs / files via core `send_file` → broker
  `uploads/<sessionID>/` (binary upload frame, see
  [`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md) §2.1).
- **Interchangeable agents.** `switch_agent` swaps the agent mid-session,
  preserving the worktree, branch, and git state — see
  [`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md) §4.

### Chat ↔ agent

- **Structured chat channel** (not TUI scraping). claude runs headless
  stream-json (`chat_mode = "stream-json"`); codex runs `codex exec --json`
  (`chat_mode = "codex-exec"`). The Terminal tab is a separate bash shell on the
  PTY. The legacy PTY-scraper survives only as a fallback for adapters with no
  `chat_mode`. Detail in [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md).
- **Rich conversation cards** — tool-call cards, per-file diff rendering,
  pending-input cards with typed reply options, subagent / handoff cards. Driven
  by a typed conversation classifier in the Rust core (`core/src/conversation.rs`).
- **AI quick replies** and **AI session titles** — the broker mints both via a
  fast-gen path (`broker/internal/session/aigen.go`) that makes a direct
  Anthropic haiku Messages API call against the session's OAuth token. Both are
  config-gated and default ON (`SWE_KITTY_AI_QUICKREPLIES`, `SWE_KITTY_AI_TITLES`).

### Terminal

- **xterm.js is the default terminal** on both platforms (iOS `WKTerminalView`,
  Android `WebTerminal`).
- **Native Ghostty terminal** (libghostty + Metal) exists behind
  `AppearanceStore.experimentalNativeTerminal`, default **OFF**. Android has a
  Termux `terminal-view` path behind the same flag, also OFF.
- **Accessory key bar** above the keyboard on both platforms — esc / tab /
  arrows / ctrl-chords / nav keys (`TerminalAccessoryBar.swift`).
- **Touch scrollback** — both terminal paths translate vertical drag into
  scrollback on touch. The native Ghostty path forwards SGR-1006 mouse-wheel
  events to tmux's copy-mode; the xterm.js path drives `term.scrollLines`
  against its own buffer.
- **libghostty pin** — `Lakr233/libghostty-spm` release `storage.1.2.1`
  (`apps/ios/GhosttyVT/Package.swift`, `scripts/fetch-ghostty-kit-xcframework.sh`).

### App shell & connectivity

- **iOS UI is the LitterUI tree** (iOS-26 Liquid Glass design),
  `AppearanceStore.experimentalLitterUI` default **ON**. The legacy
  `apps/ios/Sources/Views/` tree is the fallback. iPad uses `NavigationSplitView`
  on regular size class.
- **Android** is Jetpack Compose (Material 3).
- **OAuth v2** server-side login manager (`broker/internal/oauth/login_session.go`)
  spawns the agent CLI's own `login` subcommand and ferries the loopback
  redirect over WebSocket. Providers: `openai`, `anthropic`.
- **SSH-bootstrap pairing** — the Rust core can SSH into the user's box
  (russh), run `scripts/remote-bootstrap.sh`, and port-forward the WebSocket
  through a `direct-tcpip` channel (`core/src/ssh/`, `SSHLoginSheet` on both
  platforms).
- **LAN discovery** — mDNS on iOS / `NsdManager` on Android (`core/src/discovery.rs`);
  the broker advertises with `--local`.
- **Auto-reconnect worker** in the core + proactive network-change notify on
  both platforms.

### Pipeline

- **Tag-triggered releases.** `release.yml` (on `push` tag `v*` or
  `workflow_dispatch`) builds the IPA + APK + cross-compiled broker binaries and
  deploys the website. Operational detail in [`RELEASE.md`](RELEASE.md) and
  [`RELEASE-IOS.md`](RELEASE-IOS.md).

---

## In progress / next

- **Ghostty on-device verification.** libghostty App/Surface integration +
  CoreText/Metal renderer are wired; remaining work is full device verification
  before flipping `experimentalNativeTerminal` on by default and retiring
  xterm.js. (Continues the work tracked in the archived `PLAN-TERMINAL-REWRITE`.)
- **Push notifications.** Broker-side registry → notifier → dispatcher landed
  (`broker/internal/push/`); the APNs/FCM senders and device-side token
  registration are the remaining gap.
- **OAuth v1 teardown.** v2 is the live path; the v1 `OAuthClient` /
  `set_agent_credentials` code (now dead — both providers reject the
  `swekitty://` custom-scheme redirect) is slated for deletion once v2 is
  device-verified end-to-end on both platforms.
- **Rust-first refactor (final slice).** Both platforms shadow-write into the
  shared reducer (`core/src/store/`); the remaining step is to make both
  platforms *read* from the Rust store and drop their private reducer maps.
- **Codex chat polish.** Codex tool-item (`command_execution`) cards,
  approval/sandbox-bypass for chat, and partial-message live typing —
  follow-ups noted in [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md).
- **Voice rail B** (realtime WebRTC). Rail A (push-to-talk dictation) shipped.

---

## Direction & decisions

These supersede the older `PLAN-*` docs. If an archived plan disagrees, this
section wins.

- **Docker dropped entirely.** Bare-box only — the broker runs on the host and
  the agent runs in a user-picked directory. The old "per-agent container" model
  and the GHCR image job are gone; the adapter `image` field is parsed but
  ignored. Rationale: the real deploy is a single-operator box, and Docker added
  setup friction with no benefit for the "my box, my agent, I trust it" posture.
  (Supersedes the container language in the original `PLAN.md`.)
- **"harness" removed from the product.** The user-facing component is a
  **server** / **broker**, never a "harness". The Go server is `swe-kitty-broker`.
  ("harness" still describes the *internal* multi-agent dev workflow on this
  repo, but nothing user-facing.) (Supersedes `RENAMING-broker.md`, now archived.)
- **Ghostty is the long-term native terminal**, but **xterm.js is the current
  default** until Ghostty is fully verified on device.
- **Chat is structured, never scraped.** The PTY scraper is a fallback only.
- **Quick replies are AI-generated server-side**, not client heuristics — the
  broker mints them with a haiku call (`aigen.go`). This replaced the apps' old
  local detector chips.
- **No web client, no multi-tenant SaaS, no in-app billing.** The mobile apps
  are the product; the broker binary already runs on desktop OSes but desktop is
  not a shipped product.
