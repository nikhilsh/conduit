#!/usr/bin/env bash
set -euo pipefail

export AGENT_NAME="claude"
export AGENT_BIN="claude"
export HANDOFF_FLAG="--system-prompt-file"
export HANDOFF_FLAG_MODE="split"

exec /swekitty/entrypoint-template.sh "$@"
