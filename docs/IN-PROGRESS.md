# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **/clear routing gate + send diagnostics** (`fix/clear-routing-diagnostics`,
  PR #849) — device report "no replies after /clear" (#844 verification).
  Repro against the real claude CLI (fresh / resume / resume-of-cleared) proved
  the broker+CLI reply path healthy, so the failure is client-side routing.
  Fixes the `/clear` capability gate (was reading `supports.compact`, now
  `supports.clear` with a compact fallback) on both platforms, and adds a
  `chat / send routing` breadcrumb capturing `turn_active`/`pending_ask`/
  `has_client`/`is_slash` so the next occurrence is self-diagnosing in Sentry.
  Needs on-device verification.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
