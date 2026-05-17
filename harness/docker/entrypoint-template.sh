#!/usr/bin/env bash
set -euo pipefail

: "${AGENT_NAME:?AGENT_NAME is required}"
: "${AGENT_BIN:?AGENT_BIN is required}"

HANDOFF_PATH="${KITTY_HANDOFF_PATH:-/workspace/.swe-kitty/HANDOFF.html}"
HANDOFF_OUT_PATH="${KITTY_HANDOFF_OUT_PATH:-/workspace/.swe-kitty/HANDOFF-OUT.html}"
HANDOFF_FLAG="${HANDOFF_FLAG:-}"
HANDOFF_FLAG_MODE="${HANDOFF_FLAG_MODE:-split}"

child_pid=""

write_handoff_and_stop() {
  if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
    cat >"${HANDOFF_OUT_PATH}" <<EOF
<section data-section="handoff">
  <p>${AGENT_NAME} session ended on SIGUSR1.</p>
</section>
EOF
    kill -TERM "${child_pid}" 2>/dev/null || true
  fi
}

trap write_handoff_and_stop SIGUSR1

mkdir -p "$(dirname "${HANDOFF_OUT_PATH}")"

cmd=("${AGENT_BIN}")
if [[ -n "${HANDOFF_FLAG}" ]] && [[ -s "${HANDOFF_PATH}" ]]; then
  case "${HANDOFF_FLAG_MODE}" in
    split)
      cmd+=("${HANDOFF_FLAG}" "${HANDOFF_PATH}")
      ;;
    equals)
      cmd+=("${HANDOFF_FLAG}=${HANDOFF_PATH}")
      ;;
    *)
      echo "unsupported HANDOFF_FLAG_MODE: ${HANDOFF_FLAG_MODE}" >&2
      exit 64
      ;;
  esac
fi
cmd+=("$@")

"${cmd[@]}" &
child_pid=$!
wait "${child_pid}"
