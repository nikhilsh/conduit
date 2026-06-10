#!/usr/bin/env bash
# SessionStart hook — surface the operating-harness playbook index as context.
# Non-blocking; injects additionalContext so a one-liner task knows the model.
set -uo pipefail
cat <<'CTX'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Operating harness active. Playbooks: /ship /merge-when-green /cut-release /broker-redeploy. Delegate per .claude/agents/ (researcher,architect=opus; broker/app/ci/doc-engineer=sonnet); orchestrator keeps planning, merge-gating, CI-watch, trivial 1-liners. Starting an UNRELATED task? /clear first (CC has no auto new-task detection). DoD before done: local gates green; CI watched to green via `gh pr checks <N> || true` pending-count (NEVER the exit code); roadmap+memory updated; SHARED checkout clean (no leaked untracked files / stale worktrees). Full model: docs/OPERATING-HARNESS.md and CLAUDE.md Operating model."}}
CTX
