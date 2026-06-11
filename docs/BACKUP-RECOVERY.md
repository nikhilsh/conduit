# VPS Backup & Disaster Recovery

This runbook covers the tier-1 secrets that live only on the VPS and are
unrecoverable by any other means if the box is lost.  Run the backup script
before any risky maintenance (kernel upgrade, disk migration, teardown).

---

## Why GitHub / Cloudflare secret stores are not a backup

Both are write-only from the outside: you can push a value in (via
`gh secret set` or the Cloudflare dashboard) but **you cannot read the raw
secret back out** once stored.  This is intentional for security but means
they cannot substitute for a proper backup of:

- The APNs `.p8` key — Apple issues it once; you can revoke and re-issue but
  that requires a new upload to App Store Connect and a CI / release cycle.
- The pinned `CONDUIT_TOKEN` inside the systemd unit — losing this token forces
  both paired devices to re-pair manually.
- Agent credentials (`~/.claude*`, `~/.codex`, `~/.gemini`) — OAuth tokens /
  session cookies that take human interactive login to regenerate.

---

## Tier-1 items

| Item | Path on disk | Why it matters |
|---|---|---|
| APNs auth key | `/root/.appstoreconnect/AuthKey_<KEY_ID>.p8` | Signs every push notification; Apple issues it once |
| Broker systemd unit | `/etc/systemd/system/conduit-broker.service` | Contains pinned `CONDUIT_TOKEN`; losing it re-pairs devices |
| Claude credentials | `~/.claude` / `~/.claude.json` (and any other `~/.claude*`) | OAuth session for the claude CLI |
| Codex credentials | `~/.codex/` | Session / API config for the codex CLI |
| Gemini credentials | `~/.gemini/` | OAuth session for the gemini CLI |
| Sentry auth token | `~/.config/sentry/auth-token` | Access to crash / error feeds |
| Cloudflare token | `~/.cloudflare-token` | DNS / tunnel access |

---

## Running the backup

```sh
# Default output: ~/conduit-backup-<UTC-timestamp>.tar.gz.gpg
scripts/conduit-backup.sh

# Explicit output path (e.g. external drive):
scripts/conduit-backup.sh /media/usb/conduit-backup.tar.gz.gpg
```

The script:

1. Collects each tier-1 item that exists on disk (skips missing ones with a
   note — not an error if a credential is absent on this box).
2. Writes a `manifest.txt` with included/skipped items and restore notes.
3. Tarballs everything, pipes it through `gpg --symmetric --cipher-algo AES256`,
   and writes the encrypted archive to the output path.
4. **Prompts interactively for a passphrase** — twice.  The passphrase is never
   written to disk, to logs, or to shell history.
5. Sets `chmod 600` on the output file.

The archive is never transmitted anywhere.  Copy it off the box yourself (scp,
USB drive, etc.).

**Keep the passphrase separate from the archive** — if both are lost together
the backup is useless.

---

## Restore on a fresh box

### 1. Decrypt and unpack

```sh
gpg --decrypt conduit-backup-<timestamp>.tar.gz.gpg | tar -xz
```

This will prompt for the passphrase and extract the archive structure into the
current directory.

### 2. APNs auth key

```sh
mkdir -p /root/.appstoreconnect
cp path/to/AuthKey_<KEY_ID>.p8 /root/.appstoreconnect/
chmod 600 /root/.appstoreconnect/AuthKey_<KEY_ID>.p8
```

The Key ID and Team ID are stored as GH secrets `APNS_KEY_ID` / `APNS_TEAM_ID`
(visible in the Actions secrets UI, even though the raw key is not).  Confirm
the filename matches the Key ID before uploading to CI.

### 3. Broker systemd unit (critical — preserves the paired token)

```sh
cp etc/systemd/system/conduit-broker.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now conduit-broker
```

**Do not change the `CONDUIT_TOKEN` value in the unit.**  Using the same token
means both paired devices reconnect automatically.  Changing it forces a manual
re-pair on both devices.

Verify the broker is up:

```sh
systemctl status conduit-broker --no-pager | head -6
ss -ltnp | grep ':1977'
```

See [`BROKER-REDEPLOY.md`](BROKER-REDEPLOY.md) for the full swap/restart
procedure if you also need to deploy a new binary alongside the restored unit.

### 4. Agent credentials

```sh
# Restore files from the home-creds/ subtree back to $HOME.
cp -r home-creds/.claude* ~/
cp -r home-creds/.codex ~/
cp -r home-creds/.gemini ~/
mkdir -p ~/.config/sentry
cp home-creds/.config/sentry/auth-token ~/.config/sentry/
cp home-creds/.cloudflare-token ~/
chmod 600 ~/.cloudflare-token ~/.config/sentry/auth-token
```

After restoring, verify each CLI accepts the credentials:

```sh
claude --version   # should not prompt for login
codex --version
```

If a credential has expired, log in interactively and make a new backup.

---

## Backup cadence

There is no automated schedule.  Run the backup:

- Before any destructive maintenance (kernel upgrade, disk migration, VPS
  teardown or migration).
- After rotating any tier-1 credential (new APNs key, re-pair event, new agent
  login).
- Periodically (monthly is reasonable given the slow rate of credential churn).

---

## Related docs

- [`BROKER-REDEPLOY.md`](BROKER-REDEPLOY.md) — full procedure for swapping the
  broker binary and restarting the systemd unit.
- [`SELF-HOST.md`](SELF-HOST.md) — initial VPS setup reference.
