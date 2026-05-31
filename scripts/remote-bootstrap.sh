#!/bin/sh
# conduit remote bootstrap — invoked by the mobile app over SSH to
# stand up the conduit-broker *binary* on a remote host, bare (no
# Docker). Installs the broker if missing, starts it detached, and prints
# the pairing line the app parses.
#
# Output contract (parsed by core/src/ssh/bootstrap.rs — keep verbatim):
#   OK port=<int> token=<bearer> reused=<bool>
#   ERR <code> <message>
#
# Exit codes:
#   0   ok
#   13  broker started but never became healthy
#   14  port collision with a non-conduit process
#   15  bad usage (missing / short token)
#   16  could not download/install the broker binary
#   17  no agent CLI (claude / codex) on PATH
#   18  curl not available on the host
#
# Usage:
#   remote-bootstrap.sh <CONDUIT_TOKEN> [ANTHROPIC_API_KEY] [OPENAI_API_KEY] [IGNORED]
#
# The 4th argument (the legacy Docker IMAGE_REF) is accepted but ignored —
# this deploys the bare binary, not a container.

set -eu

TOKEN="${1:-}"
ANTHROPIC="${2:-}"
OPENAI="${3:-}"
# arg 4 (legacy image ref) intentionally ignored — no Docker.

HOST_PORT="${CONDUIT_HOST_PORT:-1977}"
BIN_DIR="${CONDUIT_BIN_DIR:-$HOME/.conduit/bin}"
STATE_DIR="${CONDUIT_STATE_DIR:-$HOME/.conduit}"
BIN="$BIN_DIR/conduit-broker"
PIDFILE="$STATE_DIR/broker.pid"
LOGFILE="$STATE_DIR/broker.log"
HEALTH="http://127.0.0.1:$HOST_PORT/health"

if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 16 ]; then
  echo "ERR 15 token argument required (>=16 chars)"
  exit 15
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERR 18 curl not found on host; install curl and reconnect"
  exit 18
fi

# Reuse path: our broker is already running + healthy on the port.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null \
   && curl -fsS "$HEALTH" >/dev/null 2>&1; then
  echo "OK port=$HOST_PORT token=$TOKEN reused=true"
  exit 0
fi

# Refuse to bind on top of an unrelated service holding the port.
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$HOST_PORT )" 2>/dev/null | grep -q ":$HOST_PORT"; then
    echo "ERR 14 host port $HOST_PORT already in use by another process"
    exit 14
  fi
fi

# Install the broker binary if missing. Progress goes to stderr so the
# stdout OK/ERR contract stays clean; the app streams stderr as status.
if [ ! -x "$BIN" ]; then
  mkdir -p "$BIN_DIR" "$STATE_DIR"
  if ! curl -fsSL https://github.com/nikhilsh/conduit/releases/latest/download/install.sh \
       | sh -s -- --bin-dir "$BIN_DIR" 1>&2; then
    echo "ERR 16 could not install conduit-broker binary"
    exit 16
  fi
fi

# The bare deploy needs an agent CLI on PATH (the old Docker image bundled
# them). See docs/SELF-HOST.md for host install instructions.
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo "ERR 17 no agent CLI (claude/codex) on PATH; see docs/SELF-HOST.md"
  exit 17
fi

# Pass the app-chosen bearer + optional API keys through the environment.
# Only export the API keys when non-empty (the broker strips empty
# ANTHROPIC_API_KEY / OPENAI_API_KEY, but leaving them unset is cleaner).
mkdir -p "$STATE_DIR"
export CONDUIT_TOKEN="$TOKEN"
if [ -n "$ANTHROPIC" ]; then export ANTHROPIC_API_KEY="$ANTHROPIC"; fi
if [ -n "$OPENAI" ]; then export OPENAI_API_KEY="$OPENAI"; fi

# Start detached so the broker survives this one-shot SSH exec. Bind to
# 127.0.0.1 — reachable only through the SSH tunnel the app sets up.
# (For a reboot-persistent install, use the systemd unit in SELF-HOST.md.)
setsid "$BIN" up --addr "127.0.0.1:$HOST_PORT" >"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

# Wait for the broker to serve /health (bare cold-start is fast).
i=1
while [ "$i" -le 15 ]; do
  if curl -fsS "$HEALTH" >/dev/null 2>&1; then
    echo "OK port=$HOST_PORT token=$TOKEN reused=false"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done

echo "ERR 13 broker did not become healthy within 15s; see $LOGFILE on the host"
exit 13
