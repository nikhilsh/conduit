# Broker Redeploy Runbook

Read this **before** touching the live broker. The procedure below is the
proven one; the footguns are real and have each bitten us at least once.

> A redeploy restarts the live service that both devices are paired to. Treat it
> as an outward-facing action that needs an explicit go-ahead. **App-only changes
> don't need a redeploy — only broker changes do.** And the inverse: **tagging a
> release does NOT deploy the broker** — a `broker/` fix is not live until this
> runbook has been run (see `docs/RELEASE.md`, "If the release contains
> `broker/` changes").

## The box is local

The box at `103.107.51.48` **IS** the machine this agent runs on. **Never `ssh`
to it** — just run commands locally. The broker serves `:1977`; its public URL
is `http://103.107.51.48:1977`.

Live layout:

- `/root/.conduit/conduit-broker-latest` — the running binary.
- `/root/.conduit/broker-latest.log` — stdout/stderr (startup banner + token line).
- `/etc/systemd/system/conduit-broker.service` — the unit (since 2026-06-06 the
  broker runs under **systemd**; the old manual `setsid` relaunch is obsolete).

The unit pins what used to be manual footguns:

- `Environment=CONDUIT_TOKEN=…` — token survives restarts; devices never re-pair.
- `WorkingDirectory=/root` — no stale worktree `./agents` pickup.
- `KillMode=process` — a restart kills only the broker; the tmux server (and
  its scrollback) survives in the cgroup.
- `Restart=always` — crash recovery (the broker exits non-zero on fatal server
  errors since v0.0.117, so a port conflict shows up red in `systemctl status`
  instead of a silent exit-0 restart loop — that loop once spun 64k times).

## Procedure

### 1. Build off `main`

Build in a throwaway worktree so a dirty/feature-branch tree never ships:

```sh
TMP=$(mktemp -d)
git worktree add --detach "$TMP" origin/main
(cd "$TMP/broker" && go build -ldflags "-X main.version=$(git -C "$TMP" describe --tags --always)" -o /root/.conduit/broker-new ./cmd/conduit-broker)
/root/.conduit/broker-new --help   # smoke test
git worktree remove --force "$TMP"
```

The `-ldflags "-X main.version=…"` injection ensures `/api/capabilities` reports the real tag (or short SHA when between tags) instead of `"dev"`, keeping the readiness block and the self-update banner accurate.

### 2. Swap with `mv`, NEVER `cp`

`cp` over the running binary fails with `ETXTBSY`. A same-filesystem `mv -f` is
an atomic rename; the running process keeps its old inode undisturbed:

```sh
mv -f /root/.conduit/broker-new /root/.conduit/conduit-broker-latest
```

### 3. Restart the unit

```sh
systemctl restart conduit-broker
```

**Caveat — agent processes die.** `KillMode=process` keeps the tmux server (and
session scrollback) alive, but agent CLIs are PTY children of the broker and the
broker's graceful shutdown reaps them. Sessions reappear via lazy recovery with
their transcripts; the user taps **Resume** in the app to restart the agent.
Batch redeploys away from in-flight agent turns when possible.

### 4. Verify

```sh
systemctl status conduit-broker --no-pager | head -6   # active (running)
NEW=$(systemctl show -p MainPID --value conduit-broker)
readlink /proc/"$NEW"/exe                               # the swapped binary
ss -ltnp | grep ':1977'                                  # port listening
grep 'token:' /root/.conduit/broker-latest.log | tail -1 # token UNCHANGED
tmux ls                                                  # sessions survived
```

Then the **idle-socket sanity** (the keep-alive regression, ~2 minutes): open a
WS to an existing session and stay quiet — it must survive **>90s** (the
pre-v0.0.117 broker hard-killed every socket at exactly 90s). The probe in
`broker/internal/ws/keepalive_test.go` documents the contract;
`go test ./internal/ws/ -run PongWait` pins it offline.

## Footgun summary

| Footgun | Symptom | Fix |
|---|---|---|
| tag-and-forget | broker fix "released" but never serving | this runbook is part of the release ritual for `broker/` changes |
| `pkill -f conduit-broker` | kills your own shell | use `systemctl`; if hunting PIDs, kill by PID |
| `cp` over running binary | `ETXTBSY` | `mv -f` (atomic rename) |
| manual broker alongside the unit | port conflict; unit crash-loops | never run the broker by hand; check `systemctl status` first |
| removing `CONDUIT_TOKEN` from the unit | both devices forced to re-pair | leave the pinned token alone |
| `ssh root@103.107.51.48` | you're already on the box | run locally |
| redeploy mid-turn | in-flight agent work dies | batch with device-test sessions; Resume restarts the agent |

Before destructive maintenance (disk migration, VPS teardown) run
`scripts/conduit-backup.sh` to snapshot the unit and all tier-1 secrets.
See [`BACKUP-RECOVERY.md`](BACKUP-RECOVERY.md).
