# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **G1 push-to-start Live Activity** — broker + relay backend that emits an
  APNs push-to-start (`event:"start"`) when a turn needs the LA and the app is
  backgrounded/closed. Broker: new `/api/push/register-start` endpoint, new
  `apns-liveactivity-start` platform in the persisted alert Registry,
  `emitLAStart` in push_notify.go branched off `emitLAUpdateImmediate`. Relay:
  `buildBody` start branch + priority-10 for start. iOS half (§1) in a parallel
  PR. Branch: `g1-broker-relay` — PR TBD. Relay must deploy BEFORE broker.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
