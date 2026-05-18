#!/usr/bin/env sh
# install.sh — one-command installer for swe-kitty-harness.
#
# Usage:
#   curl -sSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh | sh
#   curl -sSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh | sh -s -- --up [--local]
#
# Flags:
#   --version <vN.N.N>   pin a specific tag instead of `latest`
#   --bin-dir <path>     install location (default: /usr/local/bin if writable, else ~/.local/bin)
#   --up [args...]       after install, immediately exec `swe-kitty-harness up <args>` so
#                        the pairing QR prints in one command.

set -eu

REPO="nikhilsh/swe-kitty"
VERSION=""
BIN_DIR=""
RUN_UP=0
UP_ARGS=""

# Pre-parse our own flags. Anything after --up flows through to `swe-kitty-harness up`.
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
            # Everything else is forwarded to the harness.
            UP_ARGS="$*"
            break
            ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO-"
else
    die "need curl or wget on PATH"
fi

# os / arch detection — must match the matrix in .github/workflows/release-harness.yml.
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
    ASSET="https://github.com/$REPO/releases/latest/download/swe-kitty-harness-${OS}-${ARCH}"
else
    ASSET="https://github.com/$REPO/releases/download/${VERSION}/swe-kitty-harness-${OS}-${ARCH}"
fi

TMP="$(mktemp -t swekitty-harness.XXXXXX)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

echo "→ swe-kitty-harness ${VERSION:-latest} for ${OS}-${ARCH}"
echo "  asset:  $ASSET"
echo "  bin:    $BIN_DIR/swe-kitty-harness"

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
mv "$TMP" "$BIN_DIR/swe-kitty-harness"
trap - EXIT

echo "✓ installed swe-kitty-harness to $BIN_DIR/swe-kitty-harness"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "  note: $BIN_DIR is not on PATH — add it to your shell rc" ;;
esac

# Show pairing QR right away if requested.
if [ "$RUN_UP" = "1" ]; then
    echo
    echo "→ launching swe-kitty-harness up $UP_ARGS"
    # shellcheck disable=SC2086
    exec "$BIN_DIR/swe-kitty-harness" up $UP_ARGS
fi

cat <<EOM

Next: bring the harness up and pair the mobile app.

  swe-kitty-harness up --local     # LAN: mDNS + QR
  swe-kitty-harness up             # explicit URL

Scan the printed QR with the SweKitty iOS / Android app.
EOM
