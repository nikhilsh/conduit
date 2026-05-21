#!/bin/sh
# swe-kitty remote bootstrap — invoked by the mobile app over SSH to
# stand up the swe-kitty-broker Docker container on a remote host
# without requiring the user to install anything by hand.
#
# Output contract (the mobile app parses these exact lines):
#   OK port=<int> token=<bearer> reused=<bool>
#   ERR <code> <message>
#
# Exit codes:
#   0   ok
#   11  docker not installed
#   12  docker not runnable as current user (group / daemon missing)
#   13  broker container started but never returned a usable state
#   14  port collision with a non-swe-kitty process
#   15  bad usage (missing args)
#
# Usage:
#   remote-bootstrap.sh <SWE_KITTY_TOKEN> [ANTHROPIC_API_KEY] [OPENAI_API_KEY] [IMAGE_REF]
#
# IMAGE_REF defaults to ghcr.io/nikhilsh/swe-kitty:latest. Callers SHOULD
# override with a digest pin (e.g. ghcr.io/...@sha256:abc...) when the
# release pipeline starts emitting them, so a tag rewrite can't push a
# malicious image to existing users on reconnect.

set -eu

TOKEN="${1:-}"
ANTHROPIC="${2:-}"
OPENAI="${3:-}"
IMAGE="${4:-ghcr.io/nikhilsh/swe-kitty:latest}"
CONTAINER_NAME="${SWE_KITTY_CONTAINER:-swe-kitty}"
HOST_PORT="${SWE_KITTY_HOST_PORT:-1977}"

if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 16 ]; then
  echo "ERR 15 token argument required (>=16 chars)"
  exit 15
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERR 11 docker not installed; ask your hoster to apt-get install docker.io"
  exit 11
fi

if ! docker ps >/dev/null 2>&1; then
  echo "ERR 12 cannot run docker as $(id -un); usermod -aG docker $(id -un) and reconnect"
  exit 12
fi

# Reuse path: an existing container with the right name is already up.
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  # Discover which host port it's bound to (operator may have used
  # SWE_KITTY_HOST_PORT in a previous run).
  EXISTING_PORT=$(docker port "$CONTAINER_NAME" 1977 2>/dev/null | \
                  awk -F: 'NR==1 { print $NF }' | tr -d '[:space:]')
  if [ -z "$EXISTING_PORT" ]; then EXISTING_PORT="$HOST_PORT"; fi
  echo "OK port=$EXISTING_PORT token=$TOKEN reused=true"
  exit 0
fi

# Clean a stopped-but-not-removed container with our name so the run below
# doesn't trip on a naming conflict.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Pre-flight the host port — refuse to bind on top of an unrelated service.
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$HOST_PORT )" 2>/dev/null | grep -q "$HOST_PORT"; then
    echo "ERR 14 host port $HOST_PORT already in use by another process"
    exit 14
  fi
fi

# Bind to 127.0.0.1 so the broker is only reachable through the
# SSH tunnel the mobile app sets up. Public exposure is opt-in via
# `docs/SELF-HOST.md` (Caddy + wss).
DOCKER_RUN_ARGS="-d --restart unless-stopped --name $CONTAINER_NAME -p 127.0.0.1:$HOST_PORT:1977"
DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS -e SWE_KITTY_TOKEN=$TOKEN"
if [ -n "$ANTHROPIC" ]; then
  DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS -e ANTHROPIC_API_KEY=$ANTHROPIC"
fi
if [ -n "$OPENAI" ]; then
  DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS -e OPENAI_API_KEY=$OPENAI"
fi

# `docker run` auto-pulls the image on first use, so "image missing" is
# transparent to the caller. Show progress to stderr (the contract is on
# stdout) so the mobile UI can stream it as a status indicator.
# shellcheck disable=SC2086
if ! docker run $DOCKER_RUN_ARGS "$IMAGE" >/dev/null 2>&1; then
  echo "ERR 13 docker run failed; check the host's docker daemon logs"
  exit 13
fi

# Wait for the broker to start serving — health endpoint returns 200
# once routes are registered. Retry briefly because cold-start pulls the
# image (10-30s on a fresh host).
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if docker exec "$CONTAINER_NAME" curl -fsS http://127.0.0.1:1977/health \
     >/dev/null 2>&1; then
    echo "OK port=$HOST_PORT token=$TOKEN reused=false"
    exit 0
  fi
  sleep 2
done

echo "ERR 13 broker did not become healthy within 30s; docker logs $CONTAINER_NAME"
exit 13
