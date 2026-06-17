---
title: Sentry quota diagnosis and telemetry-dark postmortem
tags: [sentry, telemetry, ios, android, quota, debugging]
scope: repo
source: sentry-quota-and-noise
status: active
---

# Sentry quota diagnosis and telemetry-dark postmortem

When telemetry goes dark (no Sentry events from new builds), check quota
FIRST before assuming a code or SDK regression. Quota exhaustion and a real
regression are indistinguishable from the event feed alone.

## How to diagnose in one API call

Sentry auth token: `/root/.config/sentry/auth-token` (user me@nikhil.sh).
Org: `swe-kitty`. Projects: `conduit-ios`, `conduit-android`.

Check usage/outcomes:
```sh
curl -H "Authorization: Bearer $(cat /root/.config/sentry/auth-token)" \
  'https://sentry.io/api/0/organizations/swe-kitty/stats_v2/?statsPeriod=30d&field=sum(quantity)&category=error&groupBy=outcome'
```
Look for `rate_limited` or `dropped` in the outcomes. Each quota category
(error / transaction / profile / replay) has its own limit.

Check per-release last-event timestamps:
```sh
curl -H "Authorization: Bearer $(cat /root/.config/sentry/auth-token)" \
  'https://sentry.io/api/0/projects/swe-kitty/conduit-ios/releases/'
```
A cliff where releases stop having events (even though builds continued) =
when ingestion died.

## What exhausted the quota (June 2026 postmortem)

`Telemetry.debug` creates a full Sentry event per call (only consecutive-dup
dedupe). High-frequency callers blew the quota:
- `keyboard will hide/show` — 1,090 events
- `iOS disconnected from harness` — 676 events
- `SessionStore: Code 0` — 673 events
- `[agent_login] start` — hundreds of events

## Guards shipped (v0.0.139, PR #504)

- **`beforeSend` denylist** (iOS `Telemetry.swift` + Android `Telemetry.kt`):
  drops INFO-level `diag` events in high-frequency categories
  (keyboard/layout/scroll/terminal_resize/frame) and routine-noise messages
  (disconnect / "Code 0") before upload. ERROR/FATAL always kept.
- **High-frequency `Telemetry.debug` calls** downgraded to
  `Telemetry.breadcrumb` (ring-buffered, zero quota, attached to the next
  captured event).
- **60-second per-category throttle** on `Telemetry.debug` as a backstop.
- **Sampling cut:** `sessionSampleRate` 1.0→0.1, `tracesSampleRate` 0.2→0.1.

## Breadcrumbs are not queryable alone

Breadcrumbs appear only attached to a captured event. A flow that emits only
`Telemetry.breadcrumb` calls (no `Telemetry.capture`) shows nothing in Sentry
even when telemetry is working. This is why the SSH add-box hang was
invisible — the flow emitted breadcrumbs up to the deadlock and then went
silent. Always add a `Telemetry.capture` ERROR at the failure terminus.

See [SSH-BOOTSTRAP-FOOTGUNS](SSH-BOOTSTRAP-FOOTGUNS.md) for the deadlock case.

## Convention for new flows

Per CLAUDE.md: instrument every new flow with `Telemetry.breadcrumb` at each
meaningful step (screen open, network start/finish/fail, OAuth steps, session
create, connect/reconnect) and `Telemetry.capture` ERROR at every failure
terminus. Breadcrumbs are cheap (ring-buffered); scatter them freely. The goal:
any crash or error is self-diagnosing from Sentry without a device.
