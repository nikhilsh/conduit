---
description: Redeploy the live broker (systemd) — build off fresh origin/main, atomic mv, restart, verify. Outward-facing; needs an explicit go-ahead.
allowed-tools: Bash
---

Redeploy the live broker. ORCHESTRATOR + outward-facing: this restarts the
service both devices are paired to — get an explicit go-ahead first. App-only
changes need NO redeploy; only broker/ changes do. Full runbook:
docs/BROKER-REDEPLOY.md (read it before touching the live broker).

The box (103.107.51.48) IS this machine — never ssh to it; run locally. The
broker runs under systemd (conduit-broker.service): CONDUIT_TOKEN pinned,
WorkingDirectory=/root, KillMode=process, Restart=always.

```bash
# 1. Build off a throwaway worktree on fresh origin/main (never a dirty tree)
git fetch origin
TMP=$(mktemp -d); git worktree add --detach "$TMP" origin/main
(cd "$TMP/broker" && go build -ldflags "-X main.version=$(git -C "$TMP" describe --tags --always)" -o /root/.conduit/broker-new ./cmd/conduit-broker)
/root/.conduit/broker-new --help        # smoke test
git worktree remove --force "$TMP"

# 2. Atomic swap — mv, NEVER cp (cp over a running binary => ETXTBSY)
mv -f /root/.conduit/broker-new /root/.conduit/conduit-broker-latest

# 3. Restart the unit (agent CLIs die + recover via Resume; tmux survives)
systemctl restart conduit-broker

# 4. Verify
systemctl status conduit-broker --no-pager | head -6     # active (running)
NEW=$(systemctl show -p MainPID --value conduit-broker)
readlink /proc/"$NEW"/exe                                  # the swapped binary
ss -ltnp | grep ':1977'                                    # port listening
grep 'token:' /root/.conduit/broker-latest.log | tail -1   # token UNCHANGED
tmux ls                                                     # sessions survived
```

Footguns: never `pkill -f conduit-broker` (kills your own shell — use systemctl,
or kill by PID confirmed via `ss -ltnp | grep :1977`). Never run a broker by
hand alongside the unit (port conflict -> crash-loop). Don't remove the pinned
CONDUIT_TOKEN (forces both devices to re-pair). The box has ~3.9GB RAM — avoid
unbounded greps over broker-latest.log.
