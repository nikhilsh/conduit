# Broker Redeploy Runbook

Read this **before** touching the live broker. The procedure below is the
proven one; the footguns are real and have each bitten us at least once.

> A redeploy restarts the live service that both devices are paired to. Treat it
> as an outward-facing action that needs an explicit go-ahead. **App-only changes
> don't need a redeploy — only broker changes do.**

## The box is local

The box at `103.107.51.48` **IS** the machine this agent runs on. **Never `ssh`
to it** — just run commands locally. The broker serves `:1977`; its public URL
is `http://103.107.51.48:1977`.

Live layout (under `/root/.conduit/`):

- `conduit-broker-latest` — the running binary.
- `broker-latest.log` — its stdout/stderr (this is where the `token:` line is).

## Procedure

### 1. Build off `main`

Build in a throwaway worktree so a dirty/feature-branch tree never ships:

```sh
TMP=$(mktemp -d)
git worktree add --detach "$TMP" origin/main
(cd "$TMP/broker" && go build -o /root/.conduit/broker-new ./cmd/conduit-broker)
/root/.conduit/broker-new --help   # smoke test
```

### 2. Capture the CURRENT token (so devices don't re-pair)

The auth store is **in-memory** and accepts any token ≥ 16 chars
(`broker/internal/auth/auth.go`). The running token is **not** in the
environment unless it was passed in — so read it back from the log:

```sh
TOKEN=$(grep 'token:' /root/.conduit/broker-latest.log | tail -1 | awk '{print $2}')
echo "$TOKEN"   # sanity-check it's non-empty and >= 16 chars
```

If you relaunch **without** pinning this exact token via `CONDUIT_TOKEN`, the
broker mints a fresh one and **both devices are forced to re-pair.**

### 3. Swap with `mv`, NEVER `cp`

`cp` over the running binary fails with `ETXTBSY`. A same-filesystem `mv -f` is
an atomic rename; the running process keeps its old inode and is undisturbed
until you stop it:

```sh
mv -f /root/.conduit/broker-new /root/.conduit/conduit-broker-latest
```

### 4. Stop the old broker BY PID

**Never `pkill -f 'conduit-broker'`** — the pattern matches the shell command
running the `pkill`, so you kill your own process. Find the PID and kill it:

```sh
OLD=$(pgrep -f 'conduit-broker-latest up' | head -1)
kill "$OLD"
timeout 15 tail --pid="$OLD" -f /dev/null   # wait for clean exit
kill -9 "$OLD" 2>/dev/null || true          # SIGKILL fallback
```

### 5. Relaunch detached FROM `/root`

The cwd matters: launching from a worktree picks up that worktree's stale
`./agents` dir. Always `cd /root` first, and pass the captured token:

```sh
cd /root && CONDUIT_TOKEN="$TOKEN" setsid \
  /root/.conduit/conduit-broker-latest up \
    --local --addr :1977 --public-url http://103.107.51.48:1977 \
  >> /root/.conduit/broker-latest.log 2>&1 </dev/null &
```

### 6. Verify

```sh
NEW=$(pgrep -f 'conduit-broker-latest up' | head -1)
readlink /proc/"$NEW"/exe                       # points at conduit-broker-latest
ss -ltnp | grep ':1977'                          # port is listening
grep 'token:' /root/.conduit/broker-latest.log | tail -1   # token UNCHANGED
```

Confirm:

- the new PID's `/proc/<pid>/exe` is the swapped binary,
- `:1977` is listening,
- the `token:` line matches the token from step 2,
- tmux sessions survived (they're independent of the broker process).

## Footgun summary

| Footgun | Symptom | Fix |
|---|---|---|
| `pkill -f conduit-broker` | kills your own shell | kill by PID |
| `cp` over running binary | `ETXTBSY` | `mv -f` (atomic rename) |
| relaunch from a worktree cwd | stale `./agents` picked up | `cd /root` first |
| relaunch without `CONDUIT_TOKEN` | both devices forced to re-pair | pin the captured token |
| `ssh root@103.107.51.48` | you're already on the box | run locally |
