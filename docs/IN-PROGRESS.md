# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **iOS nanosecond RFC3339 ts ordering fix** — iOS-only: conduitConversationTsEpoch now normalizes 1-9 fractional-digit broker timestamps to 3 digits before ISO8601 parse; fixes user AskUserQuestion answers sorting below the agent reply. Branch: `fix/ios-nanosecond-ts-ordering`.
- **Demo chat real renderer + richer cards** — iOS/Android: route demo transcript through the real read-only ChatView/ChatPage seam; add CODE, DIFF, PENDING-INPUT, PLAN, SUBAGENT, HANDOFF demo items. Branch: `feat/demo-rich-chat`.
- **Android chat/project UI parity** — Typing indicator: Column layout, mono uppercase label, neon.accent dots, no robot icon. Generic tool tint: neon.accent. Back button: ChevronLeft + neon.text. Tab strip: NeonSegmentedPill glass-capsule (mirrors iOS). Branch: `fix/android-chat-parity-wins`.
- **Streaming inline markdown + mark-head glow** — iOS/Android: render bold/italic/code live during streaming (not just after settle); iOS mark-head brand glow enabled. Branch: `fix/streaming-inline-markdown`.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
