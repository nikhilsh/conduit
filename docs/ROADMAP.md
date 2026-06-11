# conduit roadmap

Single source of truth for what conduit does today, what's next, and the
direction decisions that supersede the older `PLAN-*` docs. The forward-looking
content that used to be scattered across those plans now lives here; the plans
themselves are archived once their work ships (see `docs/archive/`).

Last updated: 2026-06-11.

For wire-level / lifecycle / adapter detail, read the frozen contracts:
[`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md),
[`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md),
[`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md),
[`CHAT-CHANNEL.md`](CHAT-CHANNEL.md),
[`MEMORY-FORMAT.md`](MEMORY-FORMAT.md).

---

## In review (pending device verification)

These PRs are open and CI-green as of 2026-05-29 but have **not been verified
on a physical device**. The dev box is CI-compile-only; on-device confirmation
is required before these land under "Shipped".

- **#261** — Android: pairing QR decodes when picked from the gallery
  (`BitmapFactory` premultiplied a 1-bit indexed PNG to black; fix normalises
  onto a white canvas + binarizer fallbacks). Also: Licenses screen z-order
  fixed — hosted in a full-screen `Dialog` so it presents over the Settings
  bottom sheet instead of behind it.
- **#262** — Agent starts in the user-selected folder: `cwd` threaded through
  Rust core (`SpawnOverride` → WS `cwd=` query param) → broker; apps stop
  faking it with a terminal `cd`. Per-session ephemeral agent `$HOME` relocated
  out of the user's repo into broker storage.
- **#263** — iOS: Liquid Glass home buttons now read as glass — added a
  brand-tinted `AppBackdrop` (the home background was a flat colour, so glass
  had nothing to refract) + `.interactive()` on icon/pill glass. Addresses
  device-bug #28.
- **#264** — Android: parallel glass bump — `glassCircle`/`glassCapsule` on
  home buttons + pills, strengthened copper background glows behind button
  clusters. Also addresses device-bug #28. (No Compose BOM bump; backward-
  compatible to minSdk 26.)

Device-bug **#28** ("main-menu buttons missing glass") is addressed on both
platforms in #263/#264, pending device verification.

> **Note:** `docs/MOBILE-PORT-MATRIX.md` currently exists only on the
> unmerged worktree branch `docs-upstream-progress` and should be reconciled to
> `main` once that branch merges.

---

## Shipped

Every feature below lands on **iOS and Android together** unless noted, and is
backed by a tagged GitHub Release built from `.github/workflows/release.yml`.

### 2026-06-10/11 — Agent platform, push, model catalog (v0.0.130–0.0.132)

- **Dynamic model catalog (v0.0.130).** Both agent CLIs expose canonical model + effort
  lists at runtime; the broker probes, normalizes, and serves them via `/api/capabilities`
  (`agents{}` map + top-level `models` map). Pickers derive from live data with a static
  fallback. Implementation: `broker/internal/session/modelcatalog.go` (6 h TTL, 5 min
  retry floor). Picker UI needs on-device verification.
- **Agent platform refactor (v0.0.131).** Phases 0–4 of `docs/PLAN-AGENT-PLATFORM.md`
  shipped as a single train:
  - Phase 0 (parity): codex AI titles + quick replies (provider-routed `aigen`); codex
    approval cards (`item/commandExecution/requestApproval` → deny/cancel); claude
    login validated as code-paste flow; `on_start` hook now invoked.
  - Phase 1: adapter TOML manifest (`protocol`/`config_dir`/`cred_files`/`resume_args`/
    `model_args`/`effort_args`/`login_provider`/`permission_modes`) + `applyLegacyDefaults`
    backfill; golden argv tests.
  - Phase 2: protocol-keyed `AgentBackend` registry (`broker/internal/session/backend.go`
    + `backend_streamjson`/`codex`/`opencode` packages) — `Spawn`/`CatalogProbe`/
    `Usage`/`Capabilities`; OAuth provider registry; per-assistant `agents{}` descriptors
    in `/api/capabilities`. Note: protocol must alias `chat_mode` (not adapter name) or
    the legacy scrape path breaks.
  - Phase 3: descriptor-driven apps — iOS (#447) + Android (#448) decode `/api/capabilities`
    `agents{}` to drive slash-command availability, login provider, effort visibility,
    and generic rendering for unknown agents. Needs on-device verification.
  - Phase 4: opencode backend (`protocol = "opencode-server"`, REST + SSE, live-verified
    on the box). Protocol documented in `docs/OPENCODE-PROTOCOL.md`. Files outside
    `agents/opencode.toml` + the new backend package: ≤ 3 (plan's success metric met).
- **Push notifications (v0.0.131).** Full end-to-end delivery — see "In progress / next"
  for the status.

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
  (`apps/ios/.../ConduitForkSheet.swift`, core `fork_session`).
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
  config-gated and default ON (`CONDUIT_AI_QUICKREPLIES`, `CONDUIT_AI_TITLES`).

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

- **iOS UI is the ConduitUI tree** (iOS-26 Liquid Glass design),
  `AppearanceStore.experimentalConduitUI` default **ON**. The legacy
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
- **Push notifications shipped (v0.0.131).** Cloudflare Worker relay
  (`push.conduit.nikhil.sh`, `relay/`) holds the APNs `.p8` and FCM service-account
  key; broker senders (`broker/internal/push/`) + registration API
  (`POST /api/push/register`); iOS APNs token registration; Android UnifiedPush +
  FCM fallback (Firebase project `conduit-42af1`). Both APNs and FCM smoke-verified
  through the relay. Full tap-to-session path needs on-device verification.
- **OAuth v1 teardown.** v2 is the live path; the v1 `OAuthClient` /
  `set_agent_credentials` code (now dead — both providers reject the
  `conduit://` custom-scheme redirect) is slated for deletion once v2 is
  device-verified end-to-end on both platforms.
- **Rust-first refactor (final slice).** Both platforms shadow-write into the
  shared reducer (`core/src/store/`); the remaining step is to make both
  platforms *read* from the Rust store and drop their private reducer maps.
- **Codex chat polish.** Codex tool-item (`command_execution`) cards,
  approval/sandbox-bypass for chat, and partial-message live typing —
  follow-ups noted in [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md).
- **Voice rail B** (realtime WebRTC). Rail A (push-to-talk dictation) shipped.

---

## Backlog (prioritized)

Items below are NOT yet built. Ordered by priority as of 2026-06-11.
Companion plans where they exist: `docs/PLAN-AGENT-PLATFORM.md`, `docs/PLAN-PUSH.md`,
`docs/PLAN-CONNECTION-HEALTH.md`, `docs/PLAN-SSH-TUNNEL.md` (drafted).

1. **SSH-tunnel transport** (flow-1 keystone) — keep the bootstrap SSH connection alive
   and forward the broker port through it, so the broker binds only on localhost
   (no public `:1977`) and the token stays SSH-encrypted. Core PR in progress on branch
   `ssh-tunnel-core`; app wiring is the follow-up.

2. **Broker self-update prompt** (WS-H.2) — app compares `readiness.broker_version`
   against the latest release and shows an "update available" banner, with a one-tap
   re-bootstrap for flow-1 or a curl one-liner for flow-2. Requires WS-H.1 readiness
   block (PR #450).

3. **Post-pair readiness gate** (WS-H.3) — surface the readiness checklist to the user
   on pair/connect instead of silently failing the session when prerequisites are
   missing (no signed-in agent, no broker version, etc.).

4. **Harness bootstrap** — the marquee differentiator, deferred from the original plan.
   A "Set up agent harness" chip when a project lacks `CLAUDE.md`/`AGENTS.md` (seeds
   `initialPrompt`); the broker injects a conduit-awareness system prompt (preview
   `$PORT`, uploads dir, `AskUserQuestion` cards, memory paths) via
   `--append-system-prompt` (claude) / `AGENTS.md` (codex). Rides the `on_start` hook
   fixed in WS-0.4.

5. **Reboot durability for flow-1** — user-systemd unit + `loginctl enable-linger` so
   the broker survives a VPS reboot; pidfile fallback for non-systemd hosts.

6. **Agent-CLI auto-install in `remote-bootstrap.sh`** — install claude/codex during
   bootstrap (litter refuses to auto-install agent CLIs; the bootstrap script is the
   natural place).

7. **UnifiedPush distributor auto-setup** (WS-P.4) — extend `remote-bootstrap.sh` with
   an optional `--with-ntfy` flag that drops an ntfy server binary alongside the broker
   and prints the topic URL; the app auto-configures Android UnifiedPush via the ntfy
   distributor. Zero-vendor Android push in one flag.

8. **Onboarding telemetry funnel** — Sentry breadcrumbs covering `pair → connect →
   first-session → first-turn` to measure drop-off. Currently invisible.

9. ~~**Donation link**~~ — shipped (PR #462, Settings/About row; placeholder URL in
   source pending a live BMC/Ko-fi/Stripe link).

10. **Codex additional approval/elicitation types** — today only
    `item/commandExecution/requestApproval` renders a card; the app-server also
    defines `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
    `mcpServer/elicitation/request` (marked EXPERIMENTAL in
    `docs/CODEX-APPSERVER-PROTOCOL.md`). Map each to an appropriate card.

11. **Multi-box push registration** — WS-P.3 (#441) registers the device token with
    the active box only; register with all paired boxes so pushes arrive regardless of
    which box is foreground.

12. **ACP (Agent Client Protocol) backend** — the `AgentBackend` registry is
    protocol-keyed; ACP (gemini-cli, Zed family) is the next protocol family → adding
    a new agent costs one TOML + one backend package. `pi` remains a candidate after
    the opencode pilot.

13. **Push-driven Live Activity updates** — the relay already accepts the APNs
    `.push-type.liveactivity` topic; drive lock-screen turn-progress Live Activities
    via push (ties to the existing LA work).

14. **Broker version in the manual redeploy runbook** — box-built brokers report
    `broker_version:"dev"` in `/api/capabilities` because only CI release builds inject
    the `-ldflags -X main.version` flag. Add the ldflag to the redeploy build so the
    readiness block is truthful (required for the WS-H.2 self-update banner).

15. **Per-identity readiness/push (multi-tenant)** — `readiness.signed_in` is
    box-global (host `$HOME`), not per-bearer; WS-H.1 left this as a documented
    extension point. Needed for shared boxes where multiple identities are paired.

16. **Surface catalog richness in the model picker** — the live catalog carries
    `supportsFastMode`, usage-rate hints ("~2× faster than Opus"), and 1M-context
    pricing entries; expose a fast-mode toggle and rate hints in the picker UI.

17. **VPS backup/disaster-recovery helper** — a `conduit backup` command or runbook
    for the tier-1 secrets tarball (APNs `.p8` files, systemd unit with pinned token,
    agent credentials). GitHub and Cloudflare secret stores are write-only, so they
    are not a backup.

18. **opencode reliability** — two follow-ups from the 2026-06-11 hang investigation
    (PR #469): (a) shorten the opencode silence timeout (10 min is too long before the
    user sees a "no response" error), and (b) let opencode use the user's real provider
    (anthropic/openai key or a configured opencode provider) instead of the flaky free
    "OpenCode Zen" default; the broker could pass provider env keys or configure the
    provider in the session `$HOME`.

19. **Codex `turn/steer`** — the codex app-server exposes steering a running turn
    mid-generation (redirect without interrupting); claude has no equivalent. **Investigated
    live (codex 0.132.0): protocol-present but functionally inert** — `turn/steer` (param
    `expectedTurnId`, not `turnId`) is ACKed and the turn continues under the same id, but
    the model ignores the steered text and finishes the original task (verified ×3; nothing
    on the wire or in the rollout file). Plumbing deferred — a `Steer(text)` guarded like
    `Interrupt()` is scoped in `docs/CODEX-APPSERVER-PROTOCOL.md`, to wire once a newer
    codex demonstrably steers. No app "Steer" button until then (would silently no-op).

20. **Choice-cards over prose** — agents often offer options as a plain numbered list
    (renders as text, not tappable cards). Fix: nudge in the awareness prompt to use
    `AskUserQuestion`/structured-ask so the agent emits a real ask-tool call (branch
    `codex-steer-and-choice-cards`). **Decided (Nikhil, 2026-06-11): nudge only.** A
    heuristic to guess when prose numbered-lists should render as cards is explicitly
    declined — too fragile / false-positive-prone. Fix the source, don't parse the prose.

21. **Message-send robustness** — backgrounding mid-send silently drops the message on
    both agents; no pending/queued state. In progress on branch `optimistic-send-pending`
    (optimistic send + pending state + flush on reconnect).

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
  **server** / **broker**, never a "harness". The Go server is `conduit-broker`.
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
