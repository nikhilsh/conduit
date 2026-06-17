---
title: Broker ops footguns
tags: [broker, ops, systemd, deployment, relay]
scope: repo
source: broker-systemd-unit, broker-redeploy-pgrep-wrapper, broker-autoupdate-dead-on-reconnect, relay-category-deploy-order
status: active
---

# Broker ops footguns

## The broker runs under systemd

Since ~2026-06-06 the live broker runs as a systemd service:
`/etc/systemd/system/conduit-broker.service`, `Restart=always`, logs to
`/root/.conduit/broker-latest.log`, `CONDUIT_TOKEN` pinned in the unit file.

**Redeploy procedure:** build off fresh `origin/main` → `mv -f` the binary over
`/root/.conduit/conduit-broker-latest` → `systemctl restart conduit-broker` →
verify the endpoint answers and the token line is unchanged.

**Never run the broker manually while the unit is enabled.** A manually-launched
broker holding `:1977` while the unit is active causes the unit to crash-loop on
`bind: address already in use`. If the manual instance carries a *different* token
than the unit's pinned token, killing it causes systemd's version to take over and
every paired device gets a 401.

**Never `pkill -f 'conduit-broker'`.** The pattern matches the shell running the
command. Kill by PID only. See docs/BROKER-REDEPLOY.md.

**RAM constraint.** The dev box has ~3.9 GB RAM. Heavy regex greps over the
broker log (can exceed 250 MB) or large JSONL session files can OOM the box.
Use bounded/streaming reads.

## pgrep returns the wrong PID

`pgrep -f 'conduit-broker-latest up'` can return a wrapper PID (e.g. a setsid
parent or the killing shell itself), not the real broker. The real broker process
has PPID 1.

**How to get the right PID:** `ss -ltnp | grep ':1977'` returns the listener PID
directly. Or: after pgrep, verify with `ps -o pid,ppid,cmd -p <pid>` and check
PPID == 1 before killing. After the kill, re-check `ss` to confirm the listener
died. See docs/BROKER-REDEPLOY.md for the canonical procedure.

## Broker auto-update only fires on full re-bootstrap

The `_update_broker_if_stale` logic in `scripts/remote-bootstrap.sh` is correct,
but it only runs when the app invokes the bootstrap script. On a normal reconnect
(tap server pill, brief background) the in-memory russh tunnel may still be alive,
so `reconnect()` bounces only the WebSocket and never re-runs bootstrap. The
version compare is dead code on that path.

**Fix shipped (v0.0.154):** after a successful connect to an SSH box, the app
reads `readiness.broker_version` from `/api/capabilities` and, if it is
semver-older than the app version, triggers a single-flight `attemptSshSelfHeal()`
(the reuse path runs `_update_broker_if_stale`). Gated at-most-once per
`boxID@brokerVersion` per launch to avoid loops.

**Lesson:** when a feature "doesn't work", check whether its code path is
reached on the common path before debugging the logic.

## Deploy the relay before a broker that emits new push categories

The Cloudflare push relay (`relay/`, `relay/src/index.ts` `validPayload`)
validates `payload.category` and returns 400 for unknown values. A broker emitting
a new category against an old relay silently drops those push notifications.

**Rule:** when adding a push category, deploy the relay FIRST, then the broker.
Relay deploys run through GitHub Actions: `gh workflow run relay-deploy` (the
`CLOUDFLARE_API_TOKEN` secret lives only in GitHub; you cannot deploy from the
dev box). No Cloudflare credentials are on the box; worker secrets (APNS_KEY
etc.) are provisioned on the worker and are not touched by code deploys.

Related: [RELEASE-GOTCHAS](RELEASE-GOTCHAS.md)
