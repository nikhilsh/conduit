# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Appetize screenshot pipeline** — manual `workflow_dispatch`
  (`.github/workflows/appetize.yml`) that uploads the iOS sim `.app` + Android
  debug `.apk` to Appetize.io so builds can be poked from a phone. Branch
  `feat/appetize-screenshots`, PR #811 (upload jobs). Onboarding
  auto-screenshots (`@appetize/playwright` → PNG artifacts) land in a
  fast-follow PR.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
