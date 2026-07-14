# conduit roadmap

What conduit is building and what comes next. This file is intentionally tight:
the detailed forward-looking specs live in the active `PLAN-*.md` docs (linked
below), and the frozen wire/lifecycle contracts live in their own references.
Completed plans are archived under `docs/archive/` once their work ships.

Last updated: 2026-06-30 (v0.0.204+).

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

### Next

- **True multi-box connect (N concurrent live links)** — deferred from R3 fix 4
  (the handoff asserted `connectBox(id)`/`primaryBoxID` already existed; they
  did not). SessionStore on both platforms holds ONE live endpoint; v0.0.149
  ships live state-at-rest + seamless per-row switching instead. Real
  concurrent links = architect-scale refactor (per-box session/harness/usage
  state, merged session lists, reconnect fan-out).

- **Cross-box agent OAuth sync** — sign an agent in (e.g. claude OAuth) on one
  box and have that credential propagate to every paired box, with refresh
  rebroadcast, so you don't re-authenticate per box. Shape: fan the agent OAuth
  blob to all boxes on sign-in + rebroadcast on token refresh. Queued as the
  next feature after the v0.0.148 reliability/onboarding batch. (Distinct from
  the Deferred per-identity readiness/push refactor below — this is
  credential propagation across a single owner's boxes, not multi-tenant.)

### Later

- **Google Play distribution** — AAB build, data-safety form, Play-signing SHA
  into the Firebase API-key restriction. Needs the owner's Play dev account;
  the AAB build pipeline is the codeable part.

### Deferred

- **Per-identity readiness/push** — making `signed_in` readiness per-bearer
  (not box-global) is an architect-sized multi-tenant refactor: auth
  bearer→identity mapping, credential-store crypto/layout, per-bearer readiness
  state, and per-bearer push registration. Not being built now; tracked here as
  a documented extension point (WS-H.1).

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
