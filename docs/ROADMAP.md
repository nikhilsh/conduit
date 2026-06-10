# conduit roadmap

What conduit ships today, and what's next. This file is intentionally tight: the
detailed forward-looking specs live in the active `PLAN-*.md` docs (linked
below), and the frozen wire/lifecycle contracts live in their own references.
Completed plans are archived under `docs/archive/` once their work ships.

Last updated: 2026-06-10.

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

- **Model catalog** — broker-served `/api/capabilities` `models` map with a
  static `ForkOptions` fallback; live per-agent model lists in the fork/new
  pickers. (v0.0.130)
- **Agent platform, phases 0–4** — protocol-keyed backends, manifest-driven
  adapters, descriptor-driven apps; codex reached parity (AI titles, quick
  replies, approval cards); **opencode** landed as the pilot third agent proving
  a new agent costs ~one TOML + one backend package. (Archived plan:
  [`archive/PLAN-AGENT-PLATFORM.md`](archive/PLAN-AGENT-PLATFORM.md).)
- **Push notifications** — broker registry → notifier → dispatcher, the vendor
  **relay** (`relay/`), and iOS APNs + Android FCM/UnifiedPush device
  registration; events: turn-complete and needs-your-input. (Archived plan:
  [`archive/PLAN-PUSH.md`](archive/PLAN-PUSH.md).)
- **Connection-health readiness** — broker post-connect readiness block so the
  app no longer races a half-ready broker.
- **Conduit rebrand** — full rename from swe-kitty to Conduit across core /
  broker / iOS / Android / website. (Archived plan:
  [`archive/CONDUIT-REBRAND.md`](archive/CONDUIT-REBRAND.md).)

Earlier foundational work (bare-box broker, tmux-backed PTYs, structured chat
channel, xterm.js + native-Ghostty terminal, OAuth v2, SSH-bootstrap pairing,
LAN discovery, fork-with-model, composer attachments, interchangeable agents) is
documented in the frozen contracts above and the archived plans.

---

## Backlog

### Now

- **SSH-tunnel transport** — the flow-1 keystone. Rust core is done; remaining
  work is the app wiring on both platforms.
- **Broker self-update prompt (WS-H.2)** — the app detects a stale broker and
  offers to update it.
- **Post-pair readiness gate (WS-H.3)** — a checklist surfaced right after
  pairing so a misconfigured box is caught immediately.

### Next

- **Harness bootstrap** (the marquee differentiator) — a "Set up agent harness"
  chip plus a broker conduit-awareness system prompt injected via
  `--append-system-prompt` / `AGENTS.md`, riding the existing `on_start` hook.
- **Reboot durability for flow-1** — survive a box reboot via user-systemd +
  `loginctl enable-linger`. *(in review — branch `ssh-bootstrap-hardening`;
  needs on-device VPS test before merge)*
- **Agent-CLI auto-install** in `scripts/remote-bootstrap.sh` (install `claude`
  / `codex` if missing during bootstrap; gated on `CONDUIT_AUTOINSTALL_AGENT`).
  *(in review — branch `ssh-bootstrap-hardening`; needs on-device VPS test
  before merge)*

### Later

- **UnifiedPush distributor auto-setup** — `remote-bootstrap.sh --with-ntfy`
  drops a ntfy server next to the broker and the app auto-configures UnifiedPush
  (the Android purist, fully vendor-free push path; WS-P.4 in the archived push
  plan).
- **Onboarding telemetry funnel** — instrument the pairing/first-session funnel
  so drop-off is visible in Sentry.
- **Google Play distribution** — AAB build, data-safety form, and folding the
  Play-signing SHA into the Firebase API-key restriction.

---

## Standing human items

- **Device-test v0.0.132** — on-device verification (the dev box is
  CI-compile-only; UI/runtime is never confirmed by CI alone).

Nothing else is pending on a human.

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
