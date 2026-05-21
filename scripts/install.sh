#!/usr/bin/env sh
# install.sh — one-command installer for swe-kitty-broker (server).
#
# Usage:
#   curl -sSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh | sh
#   curl -sSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh | sh -s -- --up [--local]
#   curl -sSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh | sudo sh -s -- --service [--addr :1977] [--local]
#
# Flags:
#   --version <vN.N.N>   pin a specific tag instead of `latest`
#   --bin-dir <path>     install location (default: /usr/local/bin if writable, else ~/.local/bin)
#   --up [args...]       after install, immediately exec `swe-kitty-broker up <args>` so
#                        the pairing QR prints in one command.
#   --service            install as a long-running systemd service under the `swekitty`
#                        user, with an ExecStartPre that mirrors the deploying user's
#                        ~/.claude + ~/.codex OAuth credentials so broker-spawned agents
#                        can use the existing login without an ANTHROPIC_API_KEY /
#                        OPENAI_API_KEY. Requires root. Args after --service flow through
#                        to `swe-kitty-broker up` in the unit's ExecStart.

set -eu

REPO="nikhilsh/swe-kitty"
VERSION=""
BIN_DIR=""
RUN_UP=0
UP_ARGS=""
RUN_SERVICE=0
SERVICE_UP_ARGS=""

# Pre-parse our own flags. Anything after --up flows through to `swe-kitty-broker up`.
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:-}"; shift 2
            ;;
        --version=*)
            VERSION="${1#*=}"; shift
            ;;
        --bin-dir)
            BIN_DIR="${2:-}"; shift 2
            ;;
        --bin-dir=*)
            BIN_DIR="${1#*=}"; shift
            ;;
        --up)
            RUN_UP=1; shift
            # Everything else is forwarded to the broker.
            UP_ARGS="$*"
            break
            ;;
        --service)
            RUN_SERVICE=1; shift
            # Everything else is forwarded to the broker unit's ExecStart.
            SERVICE_UP_ARGS="$*"
            break
            ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "install.sh: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

die() { echo "install.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need uname
need chmod
need mkdir
need mv

# Stage G: the broker spawns a Node-based xterm.js sidecar so terminal
# snapshots can be reflowed to the attaching client's viewport size.
# Without Node the broker still runs, but falls back to raw PTY-byte
# snapshots which look wrong on any client whose viewport differs from
# the original PTY size. Warn loudly so users know to install it.
if command -v node >/dev/null 2>&1; then
    node_version="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0)"
    if [ "${node_version:-0}" -lt 20 ]; then
        echo "install.sh: WARNING — node $(node --version 2>/dev/null) detected; the broker sidecar needs Node 20+." >&2
        echo "  Install Node 20+ (https://nodejs.org or https://github.com/nvm-sh/nvm) for size-correct snapshots." >&2
    fi
else
    echo "install.sh: WARNING — node is not on PATH." >&2
    echo "  The broker will still run, but terminal snapshots on (re)attach will not be reflowed to the client viewport." >&2
    echo "  Install Node 20+ from https://nodejs.org or via NVM (https://github.com/nvm-sh/nvm) and re-run if you want size-correct snapshots." >&2
fi

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO-"
else
    die "need curl or wget on PATH"
fi

# os / arch detection — must match the matrix in .github/workflows/release-broker.yml.
OS_RAW="$(uname -s)"
case "$OS_RAW" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)      die "unsupported OS: $OS_RAW (linux + darwin only)" ;;
esac

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    *)                   die "unsupported arch: $ARCH_RAW (amd64 + arm64 only)" ;;
esac

# Resolve install location. Prefer a system bin if writable; fall back to
# a user-scoped dir so plain users don't need sudo.
if [ -z "$BIN_DIR" ]; then
    if [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
        BIN_DIR="/usr/local/bin"
    else
        BIN_DIR="$HOME/.local/bin"
    fi
fi
mkdir -p "$BIN_DIR"

# Pick the release tag.
if [ -z "$VERSION" ]; then
    TAG_URL="https://github.com/$REPO/releases/latest"
else
    TAG_URL="https://github.com/$REPO/releases/tag/$VERSION"
fi
# `releases/latest/download/<asset>` follows the same redirect as a
# specific tag URL, so this asset URL works for both forms.
if [ -z "$VERSION" ]; then
    ASSET="https://github.com/$REPO/releases/latest/download/swe-kitty-broker-${OS}-${ARCH}"
else
    ASSET="https://github.com/$REPO/releases/download/${VERSION}/swe-kitty-broker-${OS}-${ARCH}"
fi

TMP="$(mktemp -t swekitty-broker.XXXXXX)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

echo "→ swe-kitty-broker ${VERSION:-latest} for ${OS}-${ARCH}"
echo "  asset:  $ASSET"
echo "  bin:    $BIN_DIR/swe-kitty-broker"

# shellcheck disable=SC2086
$FETCH "$ASSET" > "$TMP" || die "download failed: $ASSET"

# Tiny sanity check so we don't drop a 404 HTML page on disk.
if [ ! -s "$TMP" ]; then
    die "downloaded asset is empty — release $VERSION may not have a $OS-$ARCH binary"
fi
case "$(head -c 4 "$TMP" | od -An -c 2>/dev/null | tr -d ' ')" in
    *html*|*HTML*|*404*)
        die "asset URL returned an HTML page (likely 404): $ASSET"
        ;;
esac

chmod +x "$TMP"
mv "$TMP" "$BIN_DIR/swe-kitty-broker"
trap - EXIT

# Strategy A migration: the server binary was renamed from
# swe-kitty-harness to swe-kitty-broker. If an older binary is sitting
# alongside the new one, remove it so we don't end up with two server
# binaries on disk. The systemd unit (if installed via --service below)
# is rewritten further down to point at the new binary; otherwise this
# is a no-op for fresh installs.
if [ -e "$BIN_DIR/swe-kitty-harness" ]; then
    rm -f "$BIN_DIR/swe-kitty-harness"
    echo "✓ removed legacy $BIN_DIR/swe-kitty-harness"
fi

echo "✓ installed swe-kitty-broker to $BIN_DIR/swe-kitty-broker"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "  note: $BIN_DIR is not on PATH — add it to your shell rc" ;;
esac

# Install as a systemd service if requested.
if [ "$RUN_SERVICE" = "1" ]; then
    [ "$(id -u)" = "0" ] || die "--service requires root (writes to /etc/systemd/system)"
    need systemctl
    need install
    need id
    need useradd
    SVC_USER="swekitty"
    SVC_HOME="/opt/swe-kitty"
    DEPLOYER_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
    [ -n "$DEPLOYER_HOME" ] || DEPLOYER_HOME="/root"

    if ! id "$SVC_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$SVC_HOME" --shell /usr/sbin/nologin "$SVC_USER"
        mkdir -p "$SVC_HOME"
        chown "$SVC_USER:$SVC_USER" "$SVC_HOME"
        echo "✓ created $SVC_USER user with home $SVC_HOME"
    fi

    cat > /usr/local/bin/swekitty-mirror-auth <<MIRROR
#!/bin/bash
# Idempotent ExecStartPre — copies the deployer's Claude + Codex OAuth
# credentials into the broker user's home so agents skip the
# ANTHROPIC_API_KEY / OPENAI_API_KEY path. Only copies when source is
# newer; safe to re-run on every service start.
set -eu
DEPLOYER_HOME="$DEPLOYER_HOME"
SVC_HOME="$SVC_HOME"
SVC_USER="$SVC_USER"
mkdir -p "\$SVC_HOME/.claude" "\$SVC_HOME/.codex"
# Created by root via ExecStartPre — agents need to write their own
# runtime state (codex tracks PATH + history in here), so reassign
# ownership before the processes start.
chown "\$SVC_USER:\$SVC_USER" "\$SVC_HOME/.claude" "\$SVC_HOME/.codex"
sync_one() {
    src=\$1; dst=\$2; mode=\$3
    [ -f "\$src" ] || return 0
    if [ ! -f "\$dst" ] || [ "\$src" -nt "\$dst" ]; then
        install -m "\$mode" -o "\$SVC_USER" -g "\$SVC_USER" "\$src" "\$dst"
    fi
}
sync_one "\$DEPLOYER_HOME/.claude/.credentials.json" "\$SVC_HOME/.claude/.credentials.json" 600
sync_one "\$DEPLOYER_HOME/.claude.json"              "\$SVC_HOME/.claude.json"              600
sync_one "\$DEPLOYER_HOME/.codex/auth.json"          "\$SVC_HOME/.codex/auth.json"          600
sync_one "\$DEPLOYER_HOME/.codex/config.toml"        "\$SVC_HOME/.codex/config.toml"        644
exit 0
MIRROR
    chmod +x /usr/local/bin/swekitty-mirror-auth

    # Make the binary discoverable from a stable system path so the unit
    # never breaks when --bin-dir is set to something exotic.
    install -m 755 "$BIN_DIR/swe-kitty-broker" "$SVC_HOME/swe-kitty-broker"
    chown "$SVC_USER:$SVC_USER" "$SVC_HOME/swe-kitty-broker"

    # Strategy A migration: existing installs had the binary at
    # $SVC_HOME/swe-kitty-harness. The unit gets rewritten further
    # down to point at the new path; drop the old binary so we don't
    # leave a dead file in place. Idempotent on fresh installs.
    if [ -e "$SVC_HOME/swe-kitty-harness" ]; then
        rm -f "$SVC_HOME/swe-kitty-harness"
        echo "✓ removed legacy $SVC_HOME/swe-kitty-harness"
    fi

    SVC_ARGS="up"
    if [ -n "$SERVICE_UP_ARGS" ]; then
        SVC_ARGS="up $SERVICE_UP_ARGS"
    fi

    cat > /etc/systemd/system/swe-kitty.service <<UNIT
[Unit]
Description=swe-kitty broker
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
Type=simple
WorkingDirectory=$SVC_HOME
ExecStartPre=/usr/local/bin/swekitty-mirror-auth
ExecStart=$SVC_HOME/swe-kitty-broker $SVC_ARGS
Restart=always
RestartSec=2s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now swe-kitty.service
    echo "✓ enabled swe-kitty.service (user=$SVC_USER, home=$SVC_HOME)"
    sleep 3
    echo
    echo "Pairing info from journal:"
    journalctl -u swe-kitty --since '15 seconds ago' --no-pager 2>/dev/null \
        | grep -E '(url:|token:|pairing:)' | tail -3 || echo "  (check 'journalctl -u swe-kitty' if missing)"
    exit 0
fi

# Show pairing QR right away if requested.
if [ "$RUN_UP" = "1" ]; then
    echo
    echo "→ launching swe-kitty-broker up $UP_ARGS"
    # shellcheck disable=SC2086
    exec "$BIN_DIR/swe-kitty-broker" up $UP_ARGS
fi

cat <<EOM

Next: bring the broker up and pair the mobile app.

  swe-kitty-broker up --local     # LAN: mDNS + QR
  swe-kitty-broker up             # explicit URL

Scan the printed QR with the SweKitty iOS / Android app.
EOM
