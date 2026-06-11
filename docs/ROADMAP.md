# conduit roadmap

What conduit ships today, and what's next. This file is intentionally tight: the
detailed forward-looking specs live in the active `PLAN-*.md` docs (linked
below), and the frozen wire/lifecycle contracts live in their own references.
Completed plans are archived under `docs/archive/` once their work ships.

Last updated: 2026-06-11.

For wire-level / lifecycle / adapter detail, read the frozen contracts:
[`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md),
[`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md),
[`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md),
[`CHAT-CHANNEL.md`](CHAT-CHANNEL.md),
[`MEMORY-FORMAT.md`](MEMORY-FORMAT.md). For agent backend wire shapes:
[`CODEX-APPSERVER-PROTOCOL.md`](CODEX-APPSERVER-PROTOCOL.md),
[`OPENCODE-PROTOCOL.md`](OPENCODE-PROTOCOL.md).

---

## Shipped

Each line lands on **iOS and Android together** unless noted, backed by a tagged
GitHub Release (`.github/workflows/release.yml`).

- **Dynamic model catalog** — broker-served `/api/capabilities` `models` map
  with a static `ForkOptions` fallback; live per-agent model/effort lists drive
  the fork/new-session pickers. (v0.0.130)
- **Push backend + relay** — broker registry → notifier → dispatcher, the vendor
  relay (`relay/`) at push.conduit.nikhil.sh (APNs + FCM); events: turn-complete
  and needs-your-input. (v0.0.131. Archived plan:
  [`archive/PLAN-PUSH.md`](archive/PLAN-PUSH.md).)
- **Agent platform, phases 0–4** — protocol-keyed AgentBackend registry,
  manifest-driven adapters, descriptor-driven apps; codex reached parity (AI
  titles, quick replies, approval cards); **opencode** landed as the pilot third
  agent (one TOML + one backend package); iOS/Android FCM/UnifiedPush device
  registration. (v0.0.132. Archived plan:
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
- **Harness bootstrap** — conduit-awareness system prompt injected via
  `--append-system-prompt` / `AGENTS.md` (Part A), plus "Set up agent harness"
  chip when a project has no `CLAUDE.md`/`AGENTS.md` (Part B); kill-switch
  `CONDUIT_HARNESS_AWARENESS`. PR #468. (v0.0.135. Active plan:
  [`PLAN-HARNESS-BOOTSTRAP.md`](PLAN-HARNESS-BOOTSTRAP.md).)
- **opencode hang fix** — heartbeat-starved watchdog + stale-resume 404. PR
  #469. (v0.0.135)
- **Buy-me-a-coffee link** — Settings row opening external donation URL (not
  IAP; placeholder URL in-source). PR #462. (v0.0.135)

Earlier foundational work (bare-box broker, tmux-backed PTYs, structured chat
channel, xterm.js + native-Ghostty terminal, OAuth v2, SSH-bootstrap pairing,
LAN discovery, fork-with-model, composer attachments, interchangeable agents) is
documented in the frozen contracts above and the archived plans.

---

## Backlog

### Now

- **Codex additional approval/elicitation card types** — only
  `item/commandExecution/requestApproval` renders a card today; the app-server
  also sends `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
  `mcpServer/elicitation/request` (captured EXPERIMENTAL in
  `CODEX-APPSERVER-PROTOCOL.md`).
- **opencode reliability** — shorten the silence timeout (10 min is a long wait
  before the user sees "no response"); let opencode use the user's real provider
  (anthropic/openai key or configured opencode provider) instead of only the
  flaky free Zen default (opencode reads per-provider env keys).

### Next

- **ACP (Agent Client Protocol) backend** — the AgentBackend registry is
  protocol-keyed; ACP (gemini-cli, Zed family) is the next protocol family →
  cheap new agents; plus onboard `pi` as a candidate.
- **Multi-box push registration** — WS-P.3 (#441) registers the device token
  with the active box only; register with all paired boxes so pushes arrive
  regardless of which box is foreground.
- **Push-driven Live Activity updates** — the relay already supports the APNs
  `.push-type.liveactivity` topic; drive lock-screen turn-progress LAs via push.
- **Surface claude catalog richness in the picker** — the live catalog carries
  `supportsFastMode`, usage-rate hints, context-window size; expose a fast-mode
  toggle and rate hints in the model picker.
- **UnifiedPush distributor auto-setup** — `remote-bootstrap.sh --with-ntfy`
  drops a ntfy server next to the broker and the app auto-configures UnifiedPush
  (the Android vendor-free push path; WS-P.4 in the archived push plan). Builds
  on the now-shipped #464 bootstrap hardening.
- **Broker version ldflags in the manual redeploy runbook** — box-built brokers
  report `broker_version:"dev"` in readiness (only CI release builds inject
  `-ldflags -X main.version`); matters for the WS-H.2 self-update banner.
- **Per-identity readiness/push (multi-tenant)** — readiness `signed_in` is
  box-global (host HOME), not per-bearer; left as a documented extension point
  in WS-H.1. Needed for shared boxes.

### Later

- **Google Play distribution** — AAB build, data-safety form, Play-signing SHA
  into the Firebase API-key restriction.
- **VPS backup/disaster-recovery helper** — a `conduit backup` doc or script for
  the tier-1 secrets tarball (`.p8` APNs key, systemd unit with pinned token,
  agent creds); GH/Cloudflare secret stores are write-only and are not a backup.

---

## Open questions

- opencode lime tint is a chosen color (opencode has no official brand color).
- SSH-tunnel ships default-on; there is no UI toggle to disable (flag exists at
  the transport layer).

---

## Operational notes

- **Known CI flakes — rerun, don't "fix":** the libghostty-spm xcframework
  download can 502/404 on the iOS build, and
  `broker/internal/ws/conformance_test.go` occasionally i/o-timeouts. Re-run the
  job before touching either.
- **libghostty pin** — `Lakr233/libghostty-spm` release tags are mutable and can
  be deleted upstream (a 404 on the iOS build means the pinned `storage.*`
  release was removed). The current pin and how to re-pin live in
  `scripts/fetch-ghostty-kit-xcframework.sh` (`apps/ios/GhosttyVT/Package.swift`
  carries the SPM pin). Native Ghostty stays behind
  `AppearanceStore.experimentalNativeTerminal` (default OFF) until fully device-
  verified; xterm.js is the shipped default.
- **Releases are tag-triggered** and broker fixes are **not** live on a tag —
  a `broker/` change requires the redeploy runbook ([`RELEASE.md`](RELEASE.md),
  [`BROKER-REDEPLOY.md`](BROKER-REDEPLOY.md)).
