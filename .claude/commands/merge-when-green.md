---
description: Watch a PR's CI to green using the correct pending-count pattern, then merge. Never trusts gh's exit code.
argument-hint: <pr-number>
allowed-tools: Bash
---

Merge PR #$1 only after CI is genuinely green. This is an ORCHESTRATOR task —
agents end at push+PR and never run this.

THE FOOTGUN this encodes: `gh pr checks` exits NON-ZERO when any check failed,
so `until out=$(gh pr checks N) && ...` loops never fire on failure (only on
all-green). Always capture with `|| true` and decide from the OUTPUT, not `$?`.
Bit us twice on 2026-06-10. And NEVER `gh pr merge` before reading the failure
count — two red PRs got merged that way once.

Watch loop (orchestrator bash until-loop watchers are nearly free; agent
CI-watch loops are expensive — keep this on the orchestrator):

```bash
N=$1
while :; do
  out=$(gh pr checks "$N" 2>/dev/null || true)        # || true: ignore exit code
  pending=$(printf '%s\n' "$out" | grep -ciE 'pending|in_progress|queued')
  failed=$(printf '%s\n'  "$out" | grep -ciE '\bfail')
  printf '%s  pending=%s failed=%s\n' "$(date +%T)" "$pending" "$failed"
  [ "$pending" -eq 0 ] && break
  sleep 60
done
if [ "$failed" -gt 0 ]; then
  echo "RED — $failed failing check(s). Read the log; do NOT merge."
  gh pr checks "$N"            # show the table
  # Known flakes (rerun, don't fix): ghostty-spm 502/404; conformance_test.go
  # i/o-timeout. Otherwise delegate to ci-fixer with the failing log.
else
  echo "GREEN — merging."
  gh pr merge "$N" --squash --delete-branch
fi
```

After merge, run the Definition of Done: roadmap/memory updated, shared checkout
clean (no leaked files / stale worktrees), broker redeployed IF broker/ changed
(/broker-redeploy — tagging does NOT deploy the broker).
