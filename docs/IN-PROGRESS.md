# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Fix pending-ask resolution (Bug A/B1/B2)** — iOS/Android: `hasPendingAsk` scans for last non-user pending_input ignoring trailing assistant items; home banner routes through resolution-aware gate; live-activity card clears on resolved pending_input; prompt never shows `[[conduit:resolved]]` marker. Branch: `fix/pending-ask-resolution`.
- **Demo chat real renderer + richer cards** — iOS/Android: route demo transcript through the real read-only ChatView/ChatPage seam; add CODE, DIFF, PENDING-INPUT, PLAN, SUBAGENT, HANDOFF demo items. Branch: `feat/demo-rich-chat`.
- **Android chat/project UI parity** — Typing indicator: Column layout, mono uppercase label, neon.accent dots, no robot icon. Generic tool tint: neon.accent. Back button: ChevronLeft + neon.text. Tab strip: NeonSegmentedPill glass-capsule (mirrors iOS). Branch: `fix/android-chat-parity-wins`.
- **Streaming inline markdown + mark-head glow** — iOS/Android: render bold/italic/code live during streaming (not just after settle); iOS mark-head brand glow enabled. Branch: `fix/streaming-inline-markdown`.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
