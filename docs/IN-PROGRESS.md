# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Review & Ship from phone** — line-level diff viewer (uncommitted/branch
  scopes) + line-anchored annotations batched into one send-to-agent prompt +
  stage/commit/push/PR from the app. Design: `PLAN-REVIEW-SHIP.md` (PR #963).
  Broker endpoints branch `review-ship-broker`; iOS `review-ship-ios`; Android
  `review-ship-android`. Capability flag `features.review_ship`.
- **Session hibernation** — broker auto-pauses idle resumable sessions
  (no attached client, ≥30 min idle) and transparently resumes on
  attach/message; RAM relief for the 3.8GB box. Design:
  `PLAN-SESSION-HIBERNATION.md` (PR #963). Branch `session-hibernation`.
  Capability flag `features.hibernation`; env kill-switch
  `CONDUIT_HIBERNATE_DISABLED=1`.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
