---
title: SSH bootstrap footguns
tags: [ssh, bootstrap, broker, ios, android, systemd]
scope: repo
source: ssh-bootstrap-broker-download-404, bootstrap-broker-path-missing, ssh-hostkey-prompt-deadlock, ssh-addbox-inline-tofu
status: active
---

# SSH bootstrap footguns

## Never use `/releases/latest/download/` for conduit releases

Every conduit release is published as a GitHub **prerelease**
(`gh release create --prerelease` in `release.yml`). GitHub's `/releases/latest/`
resolves only the latest non-prerelease — there are none — so
`/releases/latest/download/*` 404s on every box.

**Correct pattern:** use a versioned URL: `releases/download/v$CONDUIT_VERSION/<asset>`.
`scripts/remote-bootstrap.sh` now threads `CONDUIT_VERSION` from the app via
`core/src/ssh/mod.rs` (iOS `BuildInfo.marketingVersion`, Android
`BuildConfig.VERSION_NAME`) and constructs the versioned URL. Falls back to
`/latest/download` only when `CONDUIT_VERSION` is unset.

**`curl | sh` masks the exit code.** In a pipeline, the exit status is the last
command's (`sh`), not `curl`'s. On a 404, `sh` gets empty stdin and exits 0.
Guard against this by asserting `[ -x "$BIN" ]` after install before starting
the systemd unit. This produces a clean ERR 16 (install failed) instead of a
silent crash-loop ERR 13 (health timeout).

**Diagnosing a broken bootstrap box:**
- `systemctl --user status conduit-broker` / `journalctl --user-unit conduit-broker`
- `ls ~/.conduit/bin/` (empty = the download failed)
- `gh release view <tag> --json assets` (confirm the asset exists)
- Verify the URL manually: `curl -I https://github.com/.../releases/download/v<ver>/install.sh`

## The systemd broker unit needs an explicit PATH

A broker spawned by systemd does NOT inherit the login shell's PATH. Systemd's
minimal default PATH excludes `~/.local/bin`, where bootstrap installs the agent
CLIs. The broker will start, report healthy, but fail to exec `claude` or `codex`.

**Symptom:** broker `active (running)` on `:1977`, health 200, but broker log
shows `exec: "claude": executable file not found in $PATH` and
`chat disabled`. The binary exists at `~/.local/bin/claude`; only the service's
PATH is missing it.

**Fix (shipped in `scripts/remote-bootstrap.sh`):** the generated broker unit
now includes:
```
Environment="PATH=$HOME/.local/bin:$HOME/.local/share/conduit/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

**Diagnostic:** to check a running service's PATH:
`systemctl show -p Environment <unit>` or
`tr '\0' '\n' </proc/<pid>/environ | grep ^PATH`.
Do NOT check the interactive shell PATH — it is irrelevant for a systemd-managed
process.

**Immediate workaround on an existing broken box:** re-add the box (rewrites the
unit) or write a drop-in:
```sh
mkdir -p ~/.config/systemd/user/conduit-broker.service.d
printf '[Service]\nEnvironment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin\n' \
  > ~/.config/systemd/user/conduit-broker.service.d/path.conf
systemctl --user daemon-reload && systemctl --user restart conduit-broker
```

## iOS SSH host-key prompt deadlock (TOFU over a sheet)

**Root cause:** SwiftUI will not present a second `.sheet` over the first from
the same presentation context. On a first connection to an unknown host,
`SshHostKeyBridge.acceptHostKey` blocks a russh thread on
`DispatchSemaphore.wait()`. If the TOFU prompt is rendered as a `.sheet` on the
root view while `SSHLoginSheet` is already presented, the host-key prompt never
appears, the semaphore never signals, and the bootstrap hangs forever with no
error in Sentry (a silent await, no terminal event).

**Fix (PR #510):** the host-key prompt is now an `.alert` (alerts layer above
presented sheets). A 120-second safety timeout on the semaphore ensures the hang
is bounded even if the UI fails to present.

**Subsequent fix (v0.0.158, PR #595 iOS / #594 Android):** an app-root alert
dismissed the SSHLoginSheet itself. Host-key TOFU now renders inline in the add
sheet's install overlay — a fingerprint-verify card with Trust/Cancel — while
the `sshLoginSheetActive` flag suppresses the root alert/dialog. The root prompt
is kept only for non-sheet reconnect host-key prompts.

**Signs of the deadlock in Sentry:** breadcrumbs up to `ssh_tunnel bootstrap
(tunneled) start`, then nothing — no success, no failure. A flow that only emits
breadcrumbs (no `Telemetry.capture`) is invisible in Sentry until the next
captured event. See [SENTRY-QUOTA-DIAGNOSIS](SENTRY-QUOTA-DIAGNOSIS.md).

**Rule for iOS:** any modal decision that must appear while a sheet is up must use
`.alert` or `.confirmationDialog`, not `.sheet`. Any `DispatchSemaphore.wait()`
blocking on a UI decision must have a timeout.

## Failed adds now persist as retryable entries (v0.0.158)

`SavedServer` carries an optional `status` field (`ready` / `failed(reason)`).
On bootstrap failure an entry is upserted so it appears in Settings as
"Add failed" + reason + a Retry button that reopens the add sheet prefilled with
host/port/username. The secret is deliberately NOT reused — users re-enter it.
Success clears the failure; failed boxes are deletable.

Related: [BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md)
