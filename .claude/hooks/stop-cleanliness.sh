#!/usr/bin/env bash
# Stop hook — non-blocking DoD cleanliness reminder.
# If the checkout has leaked untracked files or stale harness worktrees, emit a
# systemMessage. NEVER blocks (always exit 0) — it nudges, it does not gate.
#
# OPT-IN: noisy on this box during multi-agent sessions (many live worktrees).
# Enable for solo sessions where a clean tree at Stop is the expectation.
set -uo pipefail
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$root" ] && exit 0
untracked=$(git -C "$root" status --porcelain 2>/dev/null | grep -c '^??')
wt=$(git -C "$root" worktree list 2>/dev/null | grep -c '.claude/worktrees/')
msg=""
[ "$untracked" -gt 0 ] && msg="DoD: $untracked untracked file(s) in the checkout — clean before finishing. "
[ "$wt" -gt 0 ] && msg="${msg}$wt worktree(s) under .claude/worktrees/ — remove finished ones."
[ -n "$msg" ] && printf '{"systemMessage":%s}\n' "$(jq -Rn --arg m "$msg" '$m')"
exit 0
