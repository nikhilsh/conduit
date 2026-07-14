#!/usr/bin/env bash
# conduit agent memory watchdog
# ------------------------------------------------------------------------------
# Kills any runaway agent process (claude / codex / gemini / opencode, incl.
# claude's versioned worker subprocesses) BEFORE it can exhaust the box and
# trigger a global OOM + reboot (which happened 2026-06-24: a single claude
# worker hit 2.5 GB on this 3.8 GB box). The broker itself is NEVER a target.
#
# Two thresholds:
#   HARD  — kill immediately (already runaway territory).
#   SOFT  — kill only if sustained for SOFT_DURATION (transient spikes are fine).
#
# All tunables are env-overridable from the systemd unit. Set MEMWATCH_DRYRUN=1
# to log "WOULD KILL" instead of killing (used to validate the matcher).
#
# This is the repo-committed source of truth for the box-local watchdog first
# installed manually 2026-06-24 (see docs/BROKER-REDEPLOY.md "Agent memwatch").
# It is installed by scripts/remote-bootstrap.sh next to the broker so a
# re-bootstrap never silently loses OOM protection.
set -u

LOG=${MEMWATCH_LOG:-/root/.conduit/agent-memwatch.log}
SOFT_KILL_MB=${MEMWATCH_SOFT_MB:-1500}
HARD_KILL_MB=${MEMWATCH_HARD_MB:-2200}
SOFT_DURATION=${MEMWATCH_SOFT_SECS:-120}
INTERVAL=${MEMWATCH_INTERVAL:-15}
DRYRUN=${MEMWATCH_DRYRUN:-}
# Empty (default) queries the SYSTEM bus, matching the live root-system-unit
# install. Set to "--user" when installed as a user-systemd unit (the
# remote-bootstrap.sh path, since the broker itself is a user unit there).
SYSTEMCTL_SCOPE=${MEMWATCH_SYSTEMCTL_SCOPE:-}

SOFT_KB=$(( SOFT_KILL_MB * 1024 ))
HARD_KB=$(( HARD_KILL_MB * 1024 ))

declare -A high_since

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

broker_pid() { systemctl $SYSTEMCTL_SCOPE show conduit-broker -p MainPID --value 2>/dev/null; }

kill_proc() {
  local pid=$1 why=$2 rss_mb=$3 cmd=$4
  if [ -n "$DRYRUN" ]; then
    log "WOULD KILL pid=$pid rss=${rss_mb}MB reason=$why cmd=[$cmd]"
    return
  fi
  log "KILL pid=$pid rss=${rss_mb}MB reason=$why cmd=[$cmd]"
  kill -TERM "$pid" 2>/dev/null
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || { log "  pid=$pid exited after SIGTERM"; return; }
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null
  log "  pid=$pid SIGKILLed (did not exit on TERM)"
}

log "agent-memwatch started: soft=${SOFT_KILL_MB}MB/${SOFT_DURATION}s hard=${HARD_KILL_MB}MB interval=${INTERVAL}s dryrun=${DRYRUN:-0}"

while true; do
  bpid=$(broker_pid)
  now=$(date +%s)
  declare -A seen=()
  while read -r pid rss args; do
    [ -z "${pid:-}" ] && continue
    [ "$pid" = "$bpid" ] && continue
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue
    # Only manage actual agent CLIs; never the broker or this watchdog.
    case "$args" in
      *conduit-broker*|*agent-memwatch*) continue ;;
      *claude*|*codex*|*gemini*|*opencode*) : ;;
      *) continue ;;
    esac
    seen[$pid]=1
    if [ "$rss" -ge "$HARD_KB" ]; then
      kill_proc "$pid" "hard>=${HARD_KILL_MB}MB" "$(( rss/1024 ))" "${args:0:90}"
      unset 'high_since[$pid]'
      continue
    fi
    if [ "$rss" -ge "$SOFT_KB" ]; then
      if [ -z "${high_since[$pid]:-}" ]; then
        high_since[$pid]=$now
        log "WATCH pid=$pid rss=$(( rss/1024 ))MB >= ${SOFT_KILL_MB}MB; kill if sustained ${SOFT_DURATION}s cmd=[${args:0:60}]"
      else
        elapsed=$(( now - high_since[$pid] ))
        if [ "$elapsed" -ge "$SOFT_DURATION" ]; then
          kill_proc "$pid" "soft>=${SOFT_KILL_MB}MB for ${elapsed}s" "$(( rss/1024 ))" "${args:0:90}"
          unset 'high_since[$pid]'
        fi
      fi
    else
      unset 'high_since[$pid]'
    fi
  done < <(ps -eo pid=,rss=,args= --sort=-rss 2>/dev/null)
  # Forget pids that are gone or have dropped back below the soft threshold.
  for pid in "${!high_since[@]}"; do
    [ -z "${seen[$pid]:-}" ] && unset 'high_since[$pid]'
  done
  sleep "$INTERVAL"
done
