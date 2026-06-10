---
description: End-to-end task flow — branch, delegate or implement, gates, PR, merge-when-green, then roadmap+memory update and cleanup. The one-liner-to-done playbook.
argument-hint: <task description>
---

Carry $ARGUMENTS from start to finish without further hand-holding. You are the
ORCHESTRATOR: plan in detail, delegate execution, gate, merge, clean up.

0. NEW TASK? If $ARGUMENTS is unrelated to the current conversation, the user
   should `/clear` first (CC has no auto new-task detection). Note it and proceed.

1. PLAN. Decide scope and pick the executor per .claude/agents/:
   - protocol capture / web research / coupling inventory -> researcher (opus)
   - interface/protocol design, risky multi-file refactor -> architect (opus)
   - Go broker change with a clear spec -> broker-engineer (sonnet)
   - iOS/Android change -> app-engineer (sonnet)
   - red PR + log -> ci-fixer (sonnet)
   - plan/guide/roadmap from a spec -> doc-writer (sonnet)
   - TRULY trivial 1-liner -> just do it yourself (spawning costs more).
   Cap concurrency ~3 (box RAM). Give each agent the standard scaffold
   (verify pwd; run gates; end at push+PR; do NOT watch CI) — it is already in
   each agent file, so a one-line task pointer suffices.

2. EXECUTE. Branch off fresh origin/main. Agents implement + run local gates +
   open the PR. You do not hand-code unless trivial.

3. GATE + MERGE. Per PR run /merge-when-green <N>: watch via the
   `gh pr checks <N> || true` pending-count pattern (NEVER the exit code);
   read the failure count before any merge. Delegate red CI to ci-fixer
   (skip known flakes — rerun those).

4. DEPLOY IF NEEDED. broker/ changed and it must be live? /broker-redeploy
   (tagging does NOT deploy the broker). Cutting a release? /cut-release vX.Y.Z.

5. DEFINITION OF DONE (self-apply; do not report "done" until all hold):
   [ ] local gates green (broker/core); iOS/Android flagged needs-device-verify
   [ ] CI watched to GREEN via the correct pattern; no red merges
   [ ] docs/ROADMAP.md updated if scope shifted
   [ ] memory updated (new footgun/decision -> a memory note + index entry)
   [ ] SHARED checkout clean: no leaked untracked files, finished worktrees
       removed (`git worktree list`)
