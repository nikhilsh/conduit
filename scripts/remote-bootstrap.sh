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
# When --with-ntfy (or CONDUIT_WITH_NTFY=1) is set, a self-hosted ntfy
# server is also installed and started as a user-systemd service next to
# the broker.  The ntfy base URL is appended to the OK line:
#   OK port=<int> token=<bearer> reused=<bool> ntfy=http://<host>:<port>
# The Android app reads features.ntfy_url from /api/capabilities (which
# the broker populates from CONDUIT_NTFY_URL) to auto-configure
# UnifiedPush without Firebase or any third-party distributor.
#
# Exit codes:
#   0   ok
#   13  broker started but never became healthy
#   14  port collision with a non-conduit process
#   15  bad usage (missing / short token)
#   16  could not download/install the broker binary
#   18  curl not available on the host
#
# NOTE: exit 17 (no agent CLI) has been removed.  An agent CLI is NOT
# required for the broker to start or for the app to connect.  "No agent
# CLI" is reported on stderr and the broker continues normally.  The
# broker's own readiness block (cli_present:false / signed_in:false) and
# the post-pair checklist in the app inform the user of any next steps.
#
# Usage:
#   remote-bootstrap.sh [--with-ntfy] <CONDUIT_TOKEN> [ANTHROPIC_API_KEY] [OPENAI_API_KEY] [IGNORED]
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
# Agent CLIs (claude / codex) are NOT installed eagerly at bootstrap time.
# They are installed on-demand by the broker when a session starts with an
# agent whose CLI is missing — the broker runs the adapter's install_cmd,
# shows a progress message in the Chat tab, then retries the spawn.
# This avoids installing binaries the user may never use and keeps bootstrap
# fast. See broker/internal/session/agentinstall.go.
#
# ── ntfy (UnifiedPush distributor) ──────────────────────────────────────────
# When --with-ntfy is passed (or CONDUIT_WITH_NTFY=1 is set), the script
# installs a self-hosted ntfy server next to the broker.  ntfy acts as a
# UnifiedPush distributor — a private one owned by this broker's operator,
# requiring no Firebase and no third-party push vendor.
#
# Install behaviour:
#   - Binary downloaded to ~/.conduit/bin/ntfy (static Linux binary from
#     GitHub; idempotent — reuses existing binary if present).
#   - Config written to ~/.conduit/ntfy/server.yml (base-url + listen port,
#     idempotent — overwritten on each run to stay in sync with port).
#   - Started as ~/.config/systemd/user/conduit-ntfy.service (Restart=always,
#     same linger mechanism as the broker); falls back to nohup on no-systemd
#     hosts.
#   - CONDUIT_NTFY_URL is injected into the broker's systemd unit so the
#     broker advertises it in /api/capabilities features.ntfy_url.
#   - The OK line gains a ntfy= field:
#       OK port=1977 token=... reused=false ntfy=http://HOST:2586
#   - Idempotent: a healthy ntfy is reused; the unit is (re)written on
#     every run so the URL stays pinned in the broker unit.
#
# ntfy port is CONDUIT_NTFY_PORT (default: 2586).  The ntfy server binds
# on 0.0.0.0 within the user session; it is only reachable through the
# SSH tunnel (same as the broker itself).
# ────────────────────────────────────────────────────────────────────────────

set -eu

# ── Network / install timeout caps ───────────────────────────────────────────
# All curl calls and installer pipelines are bounded so nothing can cause an
# indefinite hang that leaves the app stuck on "Starting server…".
CURL_CONNECT_TIMEOUT=15        # seconds: TCP connect
CURL_MAX_TIME=180              # seconds: total curl transfer (broker install)
CURL_HEALTH_MAX_TIME=5         # seconds: health-check curls (fast local calls)
CURL_API_MAX_TIME=10           # seconds: GitHub API / version lookups
CURL_NTFY_DL_MAX_TIME=120      # seconds: ntfy binary download
# ── Argument parsing ──────────────────────────────────────────────────────
# Accept optional --with-ntfy flag before the positional args so callers
# can pass  remote-bootstrap.sh --with-ntfy <TOKEN> ...
_with_ntfy="${CONDUIT_WITH_NTFY:-0}"

# Consume --with-ntfy / --no-ntfy flags from the front of $@.
while [ $# -gt 0 ]; do
  case "$1" in
    --with-ntfy)  _with_ntfy=1; shift ;;
    --no-ntfy)    _with_ntfy=0; shift ;;
    --)           shift; break ;;
    -*)           echo "ERR 15 unknown flag: $1" >&2; exit 15 ;;
    *)            break ;;
  esac
done

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

# ntfy defaults (only used when _with_ntfy=1).
NTFY_PORT="${CONDUIT_NTFY_PORT:-2586}"
NTFY_BIN="$BIN_DIR/ntfy"
NTFY_CONFIG_DIR="$STATE_DIR/ntfy"
NTFY_CONFIG="$NTFY_CONFIG_DIR/server.yml"
NTFY_LOGFILE="$STATE_DIR/ntfy.log"
NTFY_PIDFILE="$STATE_DIR/ntfy.pid"
NTFY_HEALTH="http://127.0.0.1:$NTFY_PORT/v1/health"

if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 16 ]; then
  echo "ERR 15 token argument required (>=16 chars)"
  exit 15
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERR 18 curl not found on host; install curl and reconnect"
  exit 18
fi

# ── Idempotent unit-ensure ────────────────────────────────────────────────
# Called on the reuse path (broker already healthy) to guarantee the systemd
# unit is up-to-date.  Boxes bootstrapped by an older build may have a unit
# that lacks the Environment=PATH= line; re-adding the box MUST self-heal
# without any manual steps.
#
# Detection: check whether the unit file contains an Environment=PATH= line.
# If absent (stale unit) → rewrite with the correct content and restart.
# If already correct → do NOTHING (don't restart a healthy broker needlessly;
# restarting reaps in-flight agent sessions).
#
# The token used in the rewritten unit is the one the caller passed ($TOKEN),
# which is the same token already in the unit on a normal re-add.  A caller
# that intentionally changes the token gets the new token written in — which
# is the correct re-pair behaviour.
_ensure_broker_unit() {
  # Only act when user-systemd is available and linger is enabled.
  if ! command -v systemctl >/dev/null 2>&1; then return 0; fi
  if ! systemctl --user status >/dev/null 2>&1; then return 0; fi

  _unit_dir="$HOME/.config/systemd/user"
  _unit_file="$_unit_dir/conduit-broker.service"

  # If the unit doesn't exist at all there's nothing to fix on the reuse path
  # (the broker is running via the nohup/pidfile fallback — that path also
  # exports PATH in the environment, so it self-heals on the next re-add).
  if [ ! -f "$_unit_file" ]; then return 0; fi

  # If the unit already has the PATH environment line, nothing to do.
  if grep -q 'Environment=.PATH=' "$_unit_file"; then return 0; fi

  # ---- Stale unit detected: rewrite and restart ----
  echo "conduit: unit lacks Environment=PATH=; rewriting for self-heal" >&2

  # Build Environment= lines (mirrors the fresh-install path exactly).
  _eu_env_lines="Environment=\"PATH=$HOME/.local/bin:$HOME/.local/share/conduit/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
  _eu_env_lines="$_eu_env_lines
Environment=\"CONDUIT_TOKEN=$TOKEN\""
  if [ -n "$ANTHROPIC" ]; then
    _eu_env_lines="$_eu_env_lines
Environment=\"ANTHROPIC_API_KEY=$ANTHROPIC\""
  fi
  if [ -n "$OPENAI" ]; then
    _eu_env_lines="$_eu_env_lines
Environment=\"OPENAI_API_KEY=$OPENAI\""
  fi
  # Preserve a pre-existing CONDUIT_NTFY_URL in the unit if present, so we
  # don't drop ntfy on a reuse-path rewrite.
  _eu_existing_ntfy="$(grep 'Environment=.CONDUIT_NTFY_URL=' "$_unit_file" 2>/dev/null | head -1 | sed 's/^Environment=//;s/^"//;s/"$//')"
  if [ -n "$_eu_existing_ntfy" ]; then
    _eu_env_lines="$_eu_env_lines
Environment=\"$_eu_existing_ntfy\""
  elif [ -n "${_ntfy_url:-}" ]; then
    _eu_env_lines="$_eu_env_lines
Environment=\"CONDUIT_NTFY_URL=$_ntfy_url\""
  fi

  mkdir -p "$_unit_dir"
  cat > "$_unit_file" <<_UNIT
[Unit]
Description=conduit broker
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=$BIN up --addr 127.0.0.1:$HOST_PORT
Restart=on-failure
RestartSec=10
$_eu_env_lines

[Install]
WantedBy=default.target
_UNIT

  systemctl --user daemon-reload >/dev/null 2>&1
  systemctl --user restart conduit-broker >/dev/null 2>&1 || true

  # Give the broker a moment to come back; the existing health-wait loop in
  # the caller will re-confirm readiness before emitting OK.
  _wr=0
  _wi=1
  while [ "$_wi" -le 15 ]; do
    if curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$HEALTH" >/dev/null 2>&1; then
      _wr=1
      break
    fi
    sleep 1
    _wi=$((_wi + 1))
  done
  if [ "$_wr" = "0" ]; then
    echo "conduit: broker did not recover after unit rewrite within 15s" >&2
  else
    echo "conduit: broker unit rewritten and broker healthy" >&2
  fi
}

# ── Reuse path ────────────────────────────────────────────────────────────
# A healthy broker on the port → ensure the unit is correct, then return.
# Works whether the broker was launched by systemd (no pidfile) or by the
# old nohup path.
echo "STEP reuse_check" >&2
if curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$HEALTH" >/dev/null 2>&1; then
  _ensure_broker_unit
  _ntfy_suffix=""
  if [ "$_with_ntfy" = "1" ] && curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$NTFY_HEALTH" >/dev/null 2>&1; then
    _ntfy_suffix=" ntfy=http://127.0.0.1:$NTFY_PORT"
  fi
  echo "OK port=$HOST_PORT token=$TOKEN reused=true${_ntfy_suffix}"
  exit 0
fi

# Also accept: legacy pidfile present + process alive + health passes.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null \
   && curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$HEALTH" >/dev/null 2>&1; then
  _ensure_broker_unit
  _ntfy_suffix=""
  if [ "$_with_ntfy" = "1" ] && curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$NTFY_HEALTH" >/dev/null 2>&1; then
    _ntfy_suffix=" ntfy=http://127.0.0.1:$NTFY_PORT"
  fi
  echo "OK port=$HOST_PORT token=$TOKEN reused=true${_ntfy_suffix}"
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
  echo "STEP download_broker" >&2
  mkdir -p "$BIN_DIR" "$STATE_DIR"

  # Build the release base URL.  All conduit GitHub releases are tagged as
  # prereleases, so /releases/latest/download/ resolves only the latest
  # *stable* (non-prerelease) release and 404s for every prerelease build.
  # When the app passes CONDUIT_VERSION (without leading 'v', e.g. "0.0.141")
  # we use a versioned URL that resolves correctly regardless of prerelease
  # status.  Fall back to /latest/ only when the version is unknown (gives a
  # path forward if a stable release is ever published).
  if [ -n "${CONDUIT_VERSION:-}" ]; then
    _rel_base="https://github.com/nikhilsh/conduit/releases/download/v${CONDUIT_VERSION}"
    _version_arg="--version v${CONDUIT_VERSION}"
  else
    _rel_base="https://github.com/nikhilsh/conduit/releases/latest/download"
    _version_arg=""
  fi

  # Download and pipe install.sh.  IMPORTANT: in POSIX sh a pipe's exit
  # status is the last command's (sh), NOT curl's.  If curl fails
  # (network error, 404, etc.) sh receives empty stdin and exits 0 —
  # the if-check passes but the binary was never written.  We therefore
  # check that the binary is actually present and executable right after,
  # regardless of the pipe exit status.
  _install_failed=0
  # shellcheck disable=SC2086
  if ! curl -fsSL \
       --connect-timeout "$CURL_CONNECT_TIMEOUT" \
       --max-time "$CURL_MAX_TIME" \
       "${_rel_base}/install.sh" \
       | sh -s -- --bin-dir "$BIN_DIR" ${_version_arg} 1>&2; then
    _install_failed=1
  fi
  # Definitive check: assert the binary landed at the expected path.
  # This catches both an explicit installer failure AND the silent-curl
  # case where sh exited 0 on empty input but wrote nothing.
  if [ "$_install_failed" = "1" ] || [ ! -x "$BIN" ]; then
    echo "ERR 16 could not install conduit-broker binary (expected: $BIN)"
    exit 16
  fi
fi

# ── ntfy install + start (opt-in via --with-ntfy / CONDUIT_WITH_NTFY=1) ──
# ntfy is a UnifiedPush distributor.  Running it locally means the Android
# app can register its UnifiedPush endpoint against this broker's own ntfy
# instance — no Firebase, no third-party vendor.
#
# Architecture detection: ntfy publishes static Linux binaries for
# amd64 and arm64 (named linux_amd64 / linux_arm64 in the release tarball).
# We download the stripped binary directly and install it to BIN_DIR.
# ntfy release convention: https://github.com/binwiederhier/ntfy/releases
#
# Idempotent: skips download if ~/.conduit/bin/ntfy already exists.
# Config is always (re)written so port changes take effect on restart.
_ntfy_url=""
if [ "$_with_ntfy" = "1" ]; then
  echo "conduit: --with-ntfy: setting up self-hosted ntfy distributor ..." >&2
  mkdir -p "$BIN_DIR" "$NTFY_CONFIG_DIR"

  # Detect host architecture → ntfy binary name.
  _arch="$(uname -m 2>/dev/null || true)"
  case "$_arch" in
    x86_64|amd64)   _ntfy_arch="linux_amd64" ;;
    aarch64|arm64)  _ntfy_arch="linux_arm64" ;;
    armv7l|armv6l)  _ntfy_arch="linux_armv7" ;;
    *)
      echo "conduit: ntfy: unsupported architecture $_arch; skipping ntfy install" >&2
      _with_ntfy=0
      ;;
  esac

  if [ "$_with_ntfy" = "1" ]; then
    # Download ntfy binary if not already present.
    if [ ! -x "$NTFY_BIN" ]; then
      echo "conduit: ntfy: downloading binary for $_ntfy_arch ..." >&2
      # Fetch the latest release tag from GitHub API, then download the
      # matching tarball.  The binary inside is at ntfy_<ver>_<arch>/ntfy.
      _ntfy_ver=""
      if command -v curl >/dev/null 2>&1; then
        _ntfy_ver="$(curl -fsSL \
          --connect-timeout "$CURL_CONNECT_TIMEOUT" \
          --max-time "$CURL_API_MAX_TIME" \
          'https://api.github.com/repos/binwiederhier/ntfy/releases/latest' \
          2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"
      fi
      if [ -z "$_ntfy_ver" ]; then
        # Hardcoded fallback to a known-good release if API is unreachable.
        _ntfy_ver="v2.11.0"
        echo "conduit: ntfy: GitHub API unreachable; falling back to $_ntfy_ver" >&2
      fi
      _ntfy_ver_num="${_ntfy_ver#v}"  # strip leading 'v' for path component
      _ntfy_tarball="ntfy_${_ntfy_ver_num}_${_ntfy_arch}.tar.gz"
      _ntfy_url_dl="https://github.com/binwiederhier/ntfy/releases/download/${_ntfy_ver}/${_ntfy_tarball}"
      _ntfy_tmp="$(mktemp -d)"
      if curl -fsSL \
           --connect-timeout "$CURL_CONNECT_TIMEOUT" \
           --max-time "$CURL_NTFY_DL_MAX_TIME" \
           "$_ntfy_url_dl" -o "$_ntfy_tmp/$_ntfy_tarball" 2>&1 >&2; then
        tar -xzf "$_ntfy_tmp/$_ntfy_tarball" -C "$_ntfy_tmp" 2>&1 >&2
        # The binary lives at ntfy_<ver>_<arch>/ntfy inside the tarball.
        _ntfy_extracted="$_ntfy_tmp/ntfy_${_ntfy_ver_num}_${_ntfy_arch}/ntfy"
        if [ -f "$_ntfy_extracted" ]; then
          mv "$_ntfy_extracted" "$NTFY_BIN"
          chmod +x "$NTFY_BIN"
          echo "conduit: ntfy: installed $_ntfy_ver to $NTFY_BIN" >&2
        else
          echo "conduit: ntfy: binary not found in tarball; skipping ntfy" >&2
          _with_ntfy=0
        fi
      else
        echo "conduit: ntfy: download failed; skipping ntfy" >&2
        _with_ntfy=0
      fi
      rm -rf "$_ntfy_tmp"
    else
      echo "conduit: ntfy: binary already present at $NTFY_BIN" >&2
    fi
  fi

  if [ "$_with_ntfy" = "1" ]; then
    # Write minimal ntfy server config.  listen-http binds on all
    # interfaces within the user session; reachable only through the SSH
    # tunnel.  base-url is needed for ntfy to construct correct
    # UnifiedPush endpoint URLs in its responses.
    cat > "$NTFY_CONFIG" <<NTFY_CFG
# ntfy server config — managed by conduit remote-bootstrap.sh
# Edit CONDUIT_NTFY_PORT to change the port and re-run bootstrap.
base-url: "http://127.0.0.1:$NTFY_PORT"
listen-http: ":$NTFY_PORT"
cache-file: "$NTFY_CONFIG_DIR/cache.db"
auth-file: "$NTFY_CONFIG_DIR/auth.db"
# Keep messages for 12 hours; small footprint for a personal distributor.
cache-duration: "12h"
# Disable rate-limiting for a single-operator private instance.
visitor-subscription-limit: 0
NTFY_CFG

    # ── Start ntfy under user-systemd (same mechanism as the broker) ───────
    SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
    NTFY_UNIT="$SYSTEMD_UNIT_DIR/conduit-ntfy.service"
    _use_ntfy_systemd=0

    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user status >/dev/null 2>&1; then
      _current_user="$(id -un)"
      if loginctl enable-linger "$_current_user" >/dev/null 2>&1; then
        _use_ntfy_systemd=1
      fi
    fi

    if [ "$_use_ntfy_systemd" = "1" ]; then
      mkdir -p "$SYSTEMD_UNIT_DIR"
      cat > "$NTFY_UNIT" <<NTFY_UNIT
[Unit]
Description=ntfy UnifiedPush distributor (conduit)
After=network.target

[Service]
ExecStart=$NTFY_BIN serve --config $NTFY_CONFIG
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
NTFY_UNIT

      systemctl --user daemon-reload >/dev/null 2>&1
      if systemctl --user enable conduit-ntfy >/dev/null 2>&1 \
         && { systemctl --user restart conduit-ntfy >/dev/null 2>&1 \
              || systemctl --user start conduit-ntfy >/dev/null 2>&1; }; then
        echo "conduit: ntfy started via user-systemd (reboot-durable via linger)" >&2
      else
        echo "conduit: ntfy systemd enable/start failed; falling back to pidfile path" >&2
        _use_ntfy_systemd=0
      fi
    fi

    if [ "$_use_ntfy_systemd" = "0" ]; then
      # Fallback: kill old pidfile process if any, then detach with setsid.
      if [ -f "$NTFY_PIDFILE" ]; then
        _old_ntfy_pid="$(cat "$NTFY_PIDFILE" 2>/dev/null)"
        if [ -n "$_old_ntfy_pid" ] && kill -0 "$_old_ntfy_pid" 2>/dev/null; then
          kill "$_old_ntfy_pid" 2>/dev/null || true
        fi
      fi
      setsid "$NTFY_BIN" serve --config "$NTFY_CONFIG" >"$NTFY_LOGFILE" 2>&1 &
      echo $! > "$NTFY_PIDFILE"
    fi

    # Wait for ntfy /v1/health (up to 10s).
    _ni=1
    _ntfy_ready=0
    while [ "$_ni" -le 10 ]; do
      if curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$NTFY_HEALTH" >/dev/null 2>&1; then
        _ntfy_ready=1
        break
      fi
      sleep 1
      _ni=$((_ni + 1))
    done

    if [ "$_ntfy_ready" = "1" ]; then
      _ntfy_url="http://127.0.0.1:$NTFY_PORT"
      echo "conduit: ntfy healthy at $_ntfy_url" >&2
    else
      echo "conduit: ntfy did not become healthy within 10s; continuing without it (see $NTFY_LOGFILE)" >&2
      _ntfy_url=""
    fi
  fi
fi

# ── Pass app-chosen bearer + optional API keys to the broker ──────────────
# Only export the API keys when non-empty (the broker strips empty
# ANTHROPIC_API_KEY / OPENAI_API_KEY, but leaving them unset is cleaner).
mkdir -p "$STATE_DIR"
# Ensure ~/.local/bin exists — agent installers (claude/codex) write here.
# Cheap insurance even if no install happens this run.
mkdir -p "$HOME/.local/bin"
export CONDUIT_TOKEN="$TOKEN"
if [ -n "$ANTHROPIC" ]; then export ANTHROPIC_API_KEY="$ANTHROPIC"; fi
if [ -n "$OPENAI" ]; then export OPENAI_API_KEY="$OPENAI"; fi

# ── Launch: prefer user-level systemd, fall back to pidfile/nohup ─────────
echo "STEP start_broker" >&2
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

  # Build Environment= lines — PATH first (so the broker can find agent CLIs
  # installed in ~/.local/bin by the post-OK install step or by hand);
  # CONDUIT_TOKEN always; API keys only when set;
  # CONDUIT_NTFY_URL when ntfy was installed successfully (so the broker
  # advertises it in /api/capabilities features.ntfy_url).
  # Use $HOME (expanded at write time) rather than %h so the shell heredoc
  # does not need quoting gymnastics; both are equivalent in user units.
  _env_lines="Environment=\"PATH=$HOME/.local/bin:$HOME/.local/share/conduit/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
  _env_lines="$_env_lines
Environment=\"CONDUIT_TOKEN=$TOKEN\""
  if [ -n "$ANTHROPIC" ]; then
    _env_lines="$_env_lines
Environment=\"ANTHROPIC_API_KEY=$ANTHROPIC\""
  fi
  if [ -n "$OPENAI" ]; then
    _env_lines="$_env_lines
Environment=\"OPENAI_API_KEY=$OPENAI\""
  fi
  if [ -n "$_ntfy_url" ]; then
    _env_lines="$_env_lines
Environment=\"CONDUIT_NTFY_URL=$_ntfy_url\""
  fi

  # Write (or overwrite) the unit. Overwriting is idempotent for the same
  # token; a changed token causes a deliberate re-install (the app issues a
  # new bootstrap call, which is the correct re-pair signal).
  cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=conduit broker
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=$BIN up --addr 127.0.0.1:$HOST_PORT
Restart=on-failure
RestartSec=10
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
  # Export PATH so the broker inherits ~/.local/bin and can find agent CLIs
  # (same guarantee as the systemd unit's Environment=PATH= line above).
  export PATH="$HOME/.local/bin:$HOME/.local/share/conduit/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  # Inject CONDUIT_NTFY_URL when ntfy was started so the broker advertises it.
  if [ -n "$_ntfy_url" ]; then
    CONDUIT_NTFY_URL="$_ntfy_url" setsid "$BIN" up --addr "127.0.0.1:$HOST_PORT" >"$LOGFILE" 2>&1 &
  else
    setsid "$BIN" up --addr "127.0.0.1:$HOST_PORT" >"$LOGFILE" 2>&1 &
  fi
  echo $! > "$PIDFILE"
fi

# ── Wait for /health ───────────────────────────────────────────────────────
# Bare cold-start is fast; systemd may take a moment to exec the unit.
echo "STEP wait_ready" >&2
i=1
while [ "$i" -le 15 ]; do
  if curl -fsS --max-time "$CURL_HEALTH_MAX_TIME" "$HEALTH" >/dev/null 2>&1; then
    _ntfy_suffix=""
    if [ -n "$_ntfy_url" ]; then
      _ntfy_suffix=" ntfy=$_ntfy_url"
    fi
    # OK reflects "broker is up and connectable" — agent CLI is not required.
    # Agent CLIs are installed on-demand by the broker when a session starts
    # (see broker/internal/session/agentinstall.go).
    echo "OK port=$HOST_PORT token=$TOKEN reused=false${_ntfy_suffix}"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done

echo "ERR 13 broker did not become healthy within 15s; see $LOGFILE on the host"
exit 13
