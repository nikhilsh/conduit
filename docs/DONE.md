# Done

Features verified on-device and considered complete.

---

## Foundational (long-in-production)

- **Bare-box broker** — single Go binary; connects over WebSocket, token-auth,
  persistent sessions.
- **tmux-backed PTYs** — full terminal with session persistence; tmux survives
  broker restarts.
- **Structured chat channel** — turn/message protocol, approval cards, quick
  replies; wire contract in [`CHAT-CHANNEL.md`](CHAT-CHANNEL.md).
- **xterm.js + native-Ghostty terminal** — xterm.js default; native Ghostty
  behind `AppearanceStore.experimentalNativeTerminal` (off by default pending
  fuller device verification).
- **OAuth v2** — claude CLI OAuth flow; token stored in iOS Keychain / Android
  EncryptedSharedPreferences; refresh handled in-app.
- **SSH-bootstrap pairing** — `remote-bootstrap.sh` installs broker on a fresh
  VPS; app pairs via SSH handshake; no pre-existing agent CLI required.
- **LAN discovery** — mDNS-based local-network box discovery.
- **Fork with model** — fork a session to a different model mid-conversation.
- **Composer attachments** — file/image attachments in the message composer.
- **Interchangeable agents** — protocol-keyed AgentBackend registry; swap claude,
  codex, opencode, and future agents without app changes.

## Shipped features (verified)

- **Dynamic model catalog** — broker-served `/api/capabilities` `models` map with
  static `ForkOptions` fallback; live per-agent model/effort lists drive the
  fork/new-session pickers. (v0.0.130)
- **Push backend + relay** — broker registry → notifier → dispatcher; relay at
  push.conduit.nikhil.sh (APNs + FCM); events: turn-complete and
  needs-your-input. (v0.0.131. Archived plan:
  [`archive/PLAN-PUSH.md`](archive/PLAN-PUSH.md).)
- **Agent platform, phases 0–4** — manifest-driven adapters, descriptor-driven
  apps; codex approval cards + AI titles + quick replies; opencode as third
  pilot agent; iOS/Android FCM/UnifiedPush device registration. (v0.0.132.
  Archived plan:
  [`archive/PLAN-AGENT-PLATFORM.md`](archive/PLAN-AGENT-PLATFORM.md).)
- **Connection-health readiness** — broker post-connect `/api/capabilities`
  readiness block; app no longer races a half-ready broker. PR #450. (v0.0.133.
  Active plan: [`PLAN-CONNECTION-HEALTH.md`](PLAN-CONNECTION-HEALTH.md).)
- **PR-CI lint gate** — `lintVitalRelease` added to CI so release-only lint
  errors no longer slip past green PRs. PR #454. (v0.0.133)
- **Device-feedback fixes** — codex approval UX (decline-not-cancel on deny),
  picker corrections (Opus label, effort labels, opaque dropdown), opencode logo
  + lime tint, push `category` omitempty relay fix, push enable affordance from
  Settings. (v0.0.134)
- **SSH-tunnel transport** — Rust core (`ssh-tunnel-core` #451) + app wiring
  (#463); SSH-paired boxes route through the held tunnel, no public `:1977`
  required. (v0.0.135. Active plan: [`PLAN-SSH-TUNNEL.md`](PLAN-SSH-TUNNEL.md).)
- **Broker self-update banner + post-pair readiness checklist** (WS-H.2/H.3)
  — PR #466. (v0.0.135)
- **Onboarding telemetry funnel** — pair→connect→first-session→first-turn→
  first-reply breadcrumbs. PR #465. (v0.0.135)
- **SSH-bootstrap reboot-durability + agent-CLI auto-install** — user-systemd +
  `loginctl enable-linger`; opt-in `claude`/`codex` install during bootstrap
  (`CONDUIT_AUTOINSTALL_AGENT`). PR #464. (v0.0.135)
- **Harness bootstrap** — conduit-awareness system prompt via
  `--append-system-prompt` / `AGENTS.md` (Part A); "Set up agent harness" chip
  when a project has no `CLAUDE.md`/`AGENTS.md` (Part B); kill-switch
  `CONDUIT_HARNESS_AWARENESS`. PR #468. (v0.0.135. Active plan:
  [`PLAN-HARNESS-BOOTSTRAP.md`](PLAN-HARNESS-BOOTSTRAP.md).)
- **opencode hang fix** — heartbeat-starved watchdog + stale-resume 404. PR
  #469. (v0.0.135)
- **Buy-me-a-coffee link** — Settings row opening external donation URL. PR
  #462. (v0.0.135)
- **ACP protocol research doc** — wire facts + conduit backend design notes for
  ACP. PR #486. (v0.0.138, docs only)
- **Harness hygiene rules + codex multi-agent protocol doc** — agent harness
  conventions and codex collab-thread wire protocol documented. PR #493.
  (v0.0.138, docs only)
