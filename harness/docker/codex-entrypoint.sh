#!/usr/bin/env bash
set -euo pipefail

export AGENT_NAME="codex"
export AGENT_BIN="codex"
# Assumption: Codex accepts a prompt-prefix file flag.
export HANDOFF_FLAG="--prompt-prefix-file"
export HANDOFF_FLAG_MODE="split"

exec /swekitty/entrypoint-template.sh "$@"
