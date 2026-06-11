# conduit roadmap

What conduit is building and what comes next. This file is intentionally tight:
the detailed forward-looking specs live in the active `PLAN-*.md` docs (linked
below), and the frozen wire/lifecycle contracts live in their own references.
Completed plans are archived under `docs/archive/` once their work ships.

Last updated: 2026-06-11.

**Lifecycle:** [ROADMAP.md](ROADMAP.md) (backlog) →
[IN-PROGRESS.md](IN-PROGRESS.md) (building) →
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) (merged, awaiting on-device verification) →
[DONE.md](DONE.md) (verified)

For wire-level / lifecycle / adapter detail, read the frozen contracts:
[`WEBSOCKET-PROTOCOL.md`](WEBSOCKET-PROTOCOL.md),
[`SESSION-LIFECYCLE.md`](SESSION-LIFECYCLE.md),
[`AGENT-ADAPTERS.md`](AGENT-ADAPTERS.md),
[`CHAT-CHANNEL.md`](CHAT-CHANNEL.md),
[`MEMORY-FORMAT.md`](MEMORY-FORMAT.md). For agent backend wire shapes:
[`CODEX-APPSERVER-PROTOCOL.md`](CODEX-APPSERVER-PROTOCOL.md),
[`OPENCODE-PROTOCOL.md`](OPENCODE-PROTOCOL.md).

---

## Backlog

### Now

- **Codex additional approval/elicitation card types** — broker handles
  `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
  `mcpServer/elicitation/request` (#473); confirm whether app-side card UI
  renders these types or whether app card rendering is missing.
- **Surface claude catalog richness — fast-mode toggle** — usage hints and
  `supportsFastMode` availability label shipped (#475); remaining: actionable
  fast-mode toggle (iOS shows a read-only label; Android has nothing).

### Next

- **Push-driven Live Activity updates** — the relay already supports the APNs
  `.push-type.liveactivity` topic; drive lock-screen turn-progress LAs via push.
- **Per-identity readiness/push (multi-tenant)** — readiness `signed_in` is
  box-global (host HOME), not per-bearer; left as a documented extension point
  in WS-H.1. Needed for shared boxes.

### Later

- **Google Play distribution** — AAB build, data-safety form, Play-signing SHA
  into the Firebase API-key restriction.

---

## Direction & decisions

- **opencode real-provider support** — shipped for host-API-key and
  host-configured-provider (#485); OAuth-only users still fall back to Zen
  (opencode needs a raw API key; no workaround without one).
- **ACP backend pilot** — gemini-cli, not `pi`; `pi` does not speak ACP natively
  and is a later native `pi --mode rpc` candidate.

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
