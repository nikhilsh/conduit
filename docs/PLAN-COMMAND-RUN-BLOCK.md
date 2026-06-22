# PLAN — §10 / §10b Command-run rendering (R3, locked options)

**Status:** building · behind a feature flag, default OFF · iOS (iPhone+iPad) + Android
**Source of truth:** `Conduit Fixes R3 — Handoff.md` §10 / §10b + screenshots 11–14.
**Locked decisions (do NOT build the other options):**
- §10 command-run block → **Option B · Mono block** (screen `11-fix10-command-run-B.png`).
- §10b running ticker → **Option C · Minimal inline** (screen `14-fix10b-running-C.png`).

Screens (read them — absolute paths):
`/root/.conduit/sessions/3ae27921-f557-4b23-a6b7-e8803aa1c848/uploads/3ae27921-f557-4b23-a6b7-e8803aa1c848/swe-kitty-2/handoff-pack/screens/`
- `11-fix10-command-run-B.png` — §10 Mono block (settled).
- `12-fix10b-collapsed.png` / `13-fix10b-expanded.png` — §10b collapse-at-scale.
- `14-fix10b-running-C.png` — §10b Option C running ticker.

---

## Feature flag (consistent across platforms)

- Flag id string: `chat.commandRunBlock`. Default **OFF**.
- iOS: add `var commandRunBlock: Bool` to `FeatureFlags` (key `conduit.flags.chat.commandRunBlock`), mirror exactly how `showCommandDetail` is declared/persisted/surfaced (Debug/Labs row).
- Android: add a persisted labs toggle `commandRunBlock` following the same pattern the existing chat labs toggles use (AppearanceStore/DataStore), default OFF.
- When OFF: render exactly as today (no behavior change). All new code is gated.

## Threshold

- `commandRunCollapseThreshold = 10`. A run of **≥ 10** commands collapses (§10b). Runs of **1–9** render the full §10 Mono block. Single constant, easy to tune.

---

## §10 — Mono block (Option B), settled run

A command-run = a contiguous group of command/tool ConversationItems (already grouped:
iOS `.toolGroup([ConversationItem])` → `ConduitToolBundleCard`; Android
`ChatRenderUnit.ToolCluster(indices)`). Under the flag, render the group as a **flat mono
code surface** — NOT a glowing card:

- Surface: `codeBg` fill, hairline border, the design-system code radius. No accent bars,
  no left status rail, no glow, no traffic-light pips, no per-row "exit 0" pills.
- Header line (faint mono): left = `RUN N` / `commands` (count); right = aggregate status —
  a single muted check ✓ when all pass; **`M failed`** in red when any row failed; while
  running see §10b ticker.
- Each row is a **fixed grid** so `$` / command / status align:
  - leading `$` (faint mono), then the command (mono, `neon.textDim`).
  - **Success = nothing but a single muted trailing check ✓** at the row end.
  - **Exit code shows ONLY when nonzero**, red, right-aligned (e.g. `127`).
  - Command truncates **at the END only (head kept)** — iOS `.truncationMode(.tail)`,
    Android `maxLines=1, TextOverflow.Ellipsis`. NEVER middle-truncate. (This replaces the
    current `ConduitSpineToolRow` `.truncationMode(.middle)` — the exact §10 bug.)
- A **failed** row shows its **stderr tail inline** directly beneath it (auto-expanded),
  mono, on `codeBg`, e.g. `bash: yq: command not found` / `exit code 127`. Failures never hide.
- A run of a single command still renders in this mono surface (one row), per screen 11.

## §10b — Collapse at scale (≥ threshold)

- Default collapsed to **one line**: `[icon] N commands · <total duration> · ✓ passed ⌄`.
- On any failure: stays collapsed but **surfaces only the failed rows inline** (red, Mono-block
  style) under a header `[icon] N commands · <dur> · M failed`, plus a quiet footer
  `K ran clean — show all ›` (K = passed count). Failures are NEVER hidden by collapse.
- Expand → a **height-capped, internally-scrolling ledger**: numbered rows
  (`66.` etc.), each `$ command` + per-row duration + exit (nonzero only, red), with an
  **All / Failed** filter control. iOS `ScrollView` capped via `.frame(maxHeight: ~264)`;
  Android `LazyColumn` `heightIn(max = 264.dp)`. 73 rows must never blow up the transcript.

## §10b — Running ticker (Option C · Minimal inline)

While any command in the run is still executing (anyRunning / streaming), render the ticker
INSTEAD of the settled block — **no card**, a quiet mono run-line on the spine:
- Line 1: a pulse dot + `RUNNING` (left); right = elapsed timer (`0:08`, mm:ss) + progress
  count (`41 / 73`).
- Line 2: `$ <live current command>` (mono, tail-truncated).
- A **determinate progress rule** (thin line) — real progress, **never an indeterminate
  spinner**. Fraction = completed / total when a total is known (use the materialized item
  count as the best-known total; the elapsed timer + completed count are the primary signals).
  If no total is knowable, advance the rule by completed-count against the best-known total —
  but do not fake an indeterminate spinner.
- Respect reduced-motion: `prefers-reduced-motion` (iOS `accessibilityReduceMotion`, Android
  equivalent) stops the pulse-dot animation and the progress sheen (the bar still shows its
  static determinate fill).

---

## Tokens (reuse — do not invent)

`K.green #3EF0A0`, `K.cyan #22D3EE`, `K.claude #FF9D4D`, `red`, hairline/line/surface greys,
`codeBg`/`codeText`. Fonts: Space Grotesk (display/UI) + JetBrains Mono (code) — already wired
(`neon.mono`/`neon.sans` on iOS, `neon.mono`/`neon.sans` on Android). iPad: the iOS views are
shared — verify the Mono block lays out correctly at the capped/centered tablet chat width.

## Instrumentation (standing order)

Drop `Telemetry.breadcrumb("chat", …)` at: command-run block render (count, failCount,
collapsed?), ticker start/stop, ledger expand, filter toggle. No PII (don't log command text).

## Definition of done (per platform PR)

- New code fully gated by `commandRunBlock` (OFF = today's behavior, byte-identical).
- Unit tests where logic is testable (grid/truncation helpers, collapse threshold, failed-row
  surfacing, ticker fraction). iOS `ConduitTests`, Android `:app:testDebugUnitTest`.
- Local gates for what's runnable; flag UI/layout **needs on-device verification**.
- Own worktree; branch off fresh `origin/main`; end at **push + PR open** (do NOT watch CI).
- Commit style: single tight subject line, no body, no Co-Authored-By.
