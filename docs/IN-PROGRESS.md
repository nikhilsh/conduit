# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

### feat/apple-review-demo-mode-impl -- Apple reviewer demo mode
Branch: feat/apple-review-demo-mode-impl
PR: (fill in after push)
Description: Adds an in-process "Try Demo" path so App Store reviewers can explore
the app without a real VPS/broker. Fake sessions + scripted chat, no network calls.
iOS + Android, phone + tablet layouts.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
