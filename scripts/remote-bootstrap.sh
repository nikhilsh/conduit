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
#   17  no agent CLI (claude / codex) on PATH and auto-install failed/skipped
#   18  curl not available on the host
#
# Usage:
#   remote-bootstrap.sh <CONDUIT_TOKEN> [ANTHROPIC_API_KEY] [OPENAI_API_KEY] [IGNORED]
#
# The 4th argument (the legacy Docker IMAGE_REF) is accepted but ignored —
# this deploys the bare binary, not a container.
#
# ── Reboot durability ────────────────────────────────────────────────────────
# When user-level systemd is available AND loginctl can enable linger (so the
# user session survives logout/reboot), the broker is installed as a
# ~/.config/systemd/user/conduit-broker.service unit with Restart=always.
# CONDUIT_TOKEN is pinned in the unit Environment so the same token survives
# reboots without re-pairing.
#
# Falls back to the original pidfile/nohup path on any of:
#   - systemctl not found or user bus unreachable (container, non-systemd distro)
#   - loginctl enable-linger fails (no linger permission)
#   - systemctl --user enable --now fails
#
# The reuse check (healthy broker already running) works for both paths.
#
# ── Agent-CLI auto-install ──────────────────────────────────────────────────
# If neither claude nor codex is on PATH, the script attempts a best-effort
# user-space install. Gated by CONDUIT_AUTOINSTALL_AGENT (default: 1 = on).
#   Install order:
#     1. claude — official native installer (https://claude.ai/install.sh),
#        installs to ~/.local/bin/claude; auto-updates in the background.
#     2. codex  — official install script (https://chatgpt.com/codex/install.sh),
#        installs to ~/.local/bin/codex.
#     3. codex via npm (fallback for hosts that have npm but no direct DL).
# Progress goes to stderr so the stdout OK/ERR contract stays clean.
# If all attempts fail → ERR 17 with pointer to docs/SELF-HOST.md.
#
# To opt out:  CONDUIT_AUTOINSTALL_AGENT=0 remote-bootstrap.sh ...
# ────────────────────────────────────────────────────────────────────────────

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

# Agent-CLI auto-install: enabled by default; set to 0 to skip.
CONDUIT_AUTOINSTALL_AGENT="${CONDUIT_AUTOINSTALL_AGENT:-1}"

if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 16 ]; then
  echo "ERR 15 token argument required (>=16 chars)"
  exit 15
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERR 18 curl not found on host; install curl and reconnect"
  exit 18
fi

# ── Reuse path ────────────────────────────────────────────────────────────
# A healthy broker on the port → return immediately.  Works whether the
# broker was launched by systemd (no pidfile) or by the old nohup path.
if curl -fsS "$HEALTH" >/dev/null 2>&1; then
  echo "OK port=$HOST_PORT token=$TOKEN reused=true"
  exit 0
fi

# Also accept: legacy pidfile present + process alive + health passes.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null \
   && curl -fsS "$HEALTH" >/dev/null 2>&1; then
  echo "OK port=$HOST_PORT token=$TOKEN reused=true"
  exit 0
fi

# ── Port-collision guard ───────────────────────────────────────────────────
# Refuse to bind on top of an unrelated service holding the port.
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$HOST_PORT )" 2>/dev/null | grep -q ":$HOST_PORT"; then
    echo "ERR 14 host port $HOST_PORT already in use by another process"
    exit 14
  fi
fi

# ── Install broker binary if missing ──────────────────────────────────────
# Progress goes to stderr so the stdout OK/ERR contract stays clean;
# the app streams stderr as status.
if [ ! -x "$BIN" ]; then
  mkdir -p "$BIN_DIR" "$STATE_DIR"
  if ! curl -fsSL https://github.com/nikhilsh/conduit/releases/latest/download/install.sh \
       | sh -s -- --bin-dir "$BIN_DIR" 1>&2; then
    echo "ERR 16 could not install conduit-broker binary"
    exit 16
  fi
fi

# ── Agent-CLI presence check + optional auto-install ──────────────────────
# The bare deploy needs an agent CLI on PATH (the old Docker image bundled
# them). See docs/SELF-HOST.md for host install instructions.
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  if [ "$CONDUIT_AUTOINSTALL_AGENT" = "0" ]; then
    echo "ERR 17 no agent CLI (claude/codex) on PATH; see docs/SELF-HOST.md"
    exit 17
  fi

  echo "conduit: no agent CLI found; attempting user-space install (set CONDUIT_AUTOINSTALL_AGENT=0 to skip)" >&2

  # Ensure ~/.local/bin is on PATH for this session so a freshly installed
  # binary is immediately visible to command -v checks below.
  LOCAL_BIN="$HOME/.local/bin"
  mkdir -p "$LOCAL_BIN"
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) PATH="$LOCAL_BIN:$PATH" ;;
  esac

  _installed_agent=0

  # Attempt 1: claude — official native installer.
  # https://claude.ai/install.sh installs to ~/.local/bin/claude and
  # auto-updates in the background.  Ref: https://code.claude.com/docs/en/setup
  echo "conduit: trying claude native installer ..." >&2
  if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
    if command -v claude >/dev/null 2>&1; then
      echo "conduit: claude installed successfully" >&2
      _installed_agent=1
    fi
  fi

  # Attempt 2: codex — official install script.
  # https://chatgpt.com/codex/install.sh installs to ~/.local/bin/codex.
  if [ "$_installed_agent" = "0" ]; then
    echo "conduit: claude install failed; trying codex install script ..." >&2
    if curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null 2>&1; then
      if command -v codex >/dev/null 2>&1; then
        echo "conduit: codex installed successfully" >&2
        _installed_agent=1
      fi
    fi
  fi

  # Attempt 3: codex via npm (fallback for hosts with npm but no direct DL).
  if [ "$_installed_agent" = "0" ] && command -v npm >/dev/null 2>&1; then
    echo "conduit: codex script failed; trying npm install -g @openai/codex ..." >&2
    if npm install -g @openai/codex >/dev/null 2>&1; then
      if command -v codex >/dev/null 2>&1; then
        echo "conduit: codex installed via npm" >&2
        _installed_agent=1
      fi
    fi
  fi

  if [ "$_installed_agent" = "0" ]; then
    echo "ERR 17 no agent CLI (claude/codex) on PATH; auto-install failed; see docs/SELF-HOST.md"
    exit 17
  fi
fi

# ── Pass app-chosen bearer + optional API keys to the broker ──────────────
# Only export the API keys when non-empty (the broker strips empty
# ANTHROPIC_API_KEY / OPENAI_API_KEY, but leaving them unset is cleaner).
mkdir -p "$STATE_DIR"
export CONDUIT_TOKEN="$TOKEN"
if [ -n "$ANTHROPIC" ]; then export ANTHROPIC_API_KEY="$ANTHROPIC"; fi
if [ -n "$OPENAI" ]; then export OPENAI_API_KEY="$OPENAI"; fi

# ── Launch: prefer user-level systemd, fall back to pidfile/nohup ─────────
#
# Systemd path requires all of:
#   1. systemctl is on PATH and the user bus responds.
#   2. loginctl enable-linger succeeds (makes the user session survive
#      logout and reboots; may fail in containers or without permission).
#   3. systemctl --user enable --now (or restart) succeeds.
# Any failure falls through to the classic pidfile path so the broker
# still starts — just without reboot durability.

SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/conduit-broker.service"
_use_systemd=0

if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user status >/dev/null 2>&1; then
  _current_user="$(id -un)"
  if loginctl enable-linger "$_current_user" >/dev/null 2>&1; then
    _use_systemd=1
  else
    echo "conduit: loginctl enable-linger unavailable; using pidfile path" >&2
  fi
else
  echo "conduit: user-systemd not available; using pidfile path" >&2
fi

if [ "$_use_systemd" = "1" ]; then
  mkdir -p "$SYSTEMD_UNIT_DIR"

  # Build Environment= lines — CONDUIT_TOKEN always; API keys only when set.
  _env_lines="Environment=\"CONDUIT_TOKEN=$TOKEN\""
  if [ -n "$ANTHROPIC" ]; then
    _env_lines="$_env_lines
Environment=\"ANTHROPIC_API_KEY=$ANTHROPIC\""
  fi
  if [ -n "$OPENAI" ]; then
    _env_lines="$_env_lines
Environment=\"OPENAI_API_KEY=$OPENAI\""
  fi

  # Write (or overwrite) the unit. Overwriting is idempotent for the same
  # token; a changed token causes a deliberate re-install (the app issues a
  # new bootstrap call, which is the correct re-pair signal).
  cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=conduit broker
After=network.target

[Service]
ExecStart=$BIN up --addr 127.0.0.1:$HOST_PORT
Restart=always
RestartSec=5
$_env_lines

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload >/dev/null 2>&1

  # enable + (re)start — idempotent across re-runs.
  if systemctl --user enable conduit-broker >/dev/null 2>&1 \
     && { systemctl --user restart conduit-broker >/dev/null 2>&1 \
          || systemctl --user start conduit-broker >/dev/null 2>&1; }; then
    echo "conduit: broker started via user-systemd (reboot-durable via linger)" >&2
  else
    echo "conduit: systemd enable/start failed; falling back to pidfile path" >&2
    _use_systemd=0
  fi
fi

if [ "$_use_systemd" = "0" ]; then
  # Classic detached path: setsid so the broker survives this one-shot SSH
  # exec.  Bind to 127.0.0.1 — reachable only through the SSH tunnel.
  # (For a reboot-persistent install, use the systemd unit in SELF-HOST.md.)
  setsid "$BIN" up --addr "127.0.0.1:$HOST_PORT" >"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
fi

# ── Wait for /health ───────────────────────────────────────────────────────
# Bare cold-start is fast; systemd may take a moment to exec the unit.
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
