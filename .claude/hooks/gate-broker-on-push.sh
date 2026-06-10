#!/usr/bin/env bash
# PreToolUse(Bash) hook — broker CI gate on `git push`.
#
# When the about-to-run Bash command is a `git push` AND broker/ differs from
# origin/main on this branch, run the local broker gates (gofmt / go vet /
# go test). Exit 2 BLOCKS the push and shows stderr; exit 0 lets it through.
# Non-broker pushes and non-push commands pass through untouched.
#
# OPT-IN: `go test ./...` can take ~60s (the session suite) and needs the
# sidecar npm deps installed for the termgrid test. Enable only if you want a
# hard pre-push gate. See docs/OPERATING-HARNESS.md.
set -uo pipefail
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
case "$cmd" in
  *"git push"*) ;;
  *) exit 0 ;;
esac
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$root" ] && exit 0
git -C "$root" diff --quiet origin/main -- broker/ 2>/dev/null && exit 0  # no broker change
cd "$root/broker" || exit 0
unformatted=$(gofmt -l . 2>/dev/null)
if [ -n "$unformatted" ]; then
  echo "broker gate FAILED: gofmt -w these files:" >&2; echo "$unformatted" >&2; exit 2
fi
if ! go vet ./... 2>&1; then echo "broker gate FAILED: go vet" >&2; exit 2; fi
if ! go test ./... 2>&1; then echo "broker gate FAILED: go test" >&2; exit 2; fi
exit 0
