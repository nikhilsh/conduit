# Neon UI — core (Rust) fields still needed

The Neon Terminal mobile re-skin (PR #275, `worktree-neon-theme`) implements
every §4 component and §5 screen from `design_handoff_neon_mobile_ui/`. A few
components are **scaffolded but dormant** because the data they render is **not
emitted by the Rust core** today. The handoff is explicit (README §6): *"if a
field you need isn't surfaced over UniFFI yet, add it to the view model in core
rather than re-parsing in the shell."* This doc is that list.

## Where things live

- View-model + classifier: `core/src/conversation.rs`
  - `ConversationItem` — `#[derive(uniffi::Record)]` struct returned to the apps.
  - Input event: `ChatEvent { role, content, ts, files }` (`core/src/views.rs`).
    There is **no `meta` field today** — the classifier derives everything from
    `content`. Tier 2 below requires ADDING a structured carrier (e.g. a new
    `meta: Option<String>` JSON field on `ChatEvent`) plus a broker producer, so
    it is the heaviest tier.
  - `ConversationItem` is defined in TWO places that must stay in sync:
    `core/src/swe_kitty_core.udl` (`dictionary ConversationItem` — the UniFFI
    source of truth) and the matching Rust struct in `conversation.rs`.
  - `item_from_chat_event(...)` builds each `ConversationItem`; helpers
    `classify_kind` / `classify_status` / `looks_like_handoff` /
    `looks_like_subagent` / `extract_command` / `summarize_diff` /
    `extract_pending_options` already parse from `content`.
  - Tests: `mod tests` in the same file.
- Generated bindings (committed): `core/generated/swe_kitty_core.swift`,
  `core/generated/sweKittyCore.kt`. Regenerate with the Makefile target
  (`make` / the uniffi-bindgen invocation at the top of the Makefile) after any
  struct change.
- CI gate: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`.

## Current `ConversationItem` fields (all the apps can rely on)

`id, role, kind, status, content, ts, files[], tool_name?, command?, exit_code?,
duration_ms?, diff_summary?, pending_options[]`

`kind ∈ {message, tool, diff, pending_input, handoff, subagent, system}`
`status ∈ {done, running, failed, pending}`

## What the Neon UI wants (additive — keep every new field Optional / default-empty)

### Tier 1 — derivable from `content` now (move the heuristic into core)
The iOS shell currently does a weak client-side parse for these; promote it to
core so iOS + Android share one source of truth and the cards stop guessing.

| Field | Type | Feeds | Notes |
|---|---|---|---|
| `source_agent` | `Option<String>` | HandoffCard §4.2 "from" | first agent name in a `handoff` content |
| `target_agent` | `Option<String>` | HandoffCard §4.2 "to" | word after "… to " |
| `task_text` | `Option<String>` | HandoffCard §4.2 TASK block | the delegated instruction line(s) |
| `result_summary` | `Option<String>` | HandoffCard §4.2 result block | parsed from `HANDOFF-OUT` `data-section="handoff"` when present |

### Tier 2 — needs a NEW structured channel from the broker / agent-adapters
These cannot be reliably recovered from free-text `content`. `ChatEvent` has no
`meta` field yet, so this tier means: (1) ADD `meta: Option<String>` (JSON) to
`ChatEvent` in `core/src/views.rs`, (2) have the broker/agent-adapter populate
it, (3) parse it in the classifier into the typed fields below. Until that
producer side lands, these stay `None` and the cards degrade gracefully
(already do). This is heavier than Tier 1/3 and is explicitly deferred.

| Field | Type | Feeds | Producer |
|---|---|---|---|
| `cwd` | `Option<String>` | CommandCard §4.1 meta strip (folder) | broker exec event |
| `host` | `Option<String>` | CommandCard §4.1 meta strip (`mac-studio`) | broker exec event |
| `token_count` | `Option<u64>` | HandoffCard §4.2 "subagent · N tokens" | adapter usage |
| `progress_done` / `progress_total` | `Option<u32>` | HandoffCard §4.2 nested progress strip | adapter |

### Tier 3 — new event kinds (no representation today)

| Need | Shape | Feeds |
|---|---|---|
| **Plan / todo** | new `kind == "plan"` + `plan_steps: Vec<PlanStep>` where `PlanStep { text: String, state: String /* done\|active\|todo */ }` (a new `uniffi::Record`) | PlanCard §4.3 — currently built but dormant; nothing in core emits a plan/todo event |
| **Agent swap in progress** | extend `status` vocabulary with `"swapping"` (transient, before `running`) | SwapNotice §4.2 inline divider — built but unwired |

## Constraints for whoever implements this

1. **Additive only.** New fields must be `Option<_>` / `Vec<_>` with sensible
   empty defaults so existing producers, tests, and the already-merged mobile
   code keep compiling. Don't reorder or rename existing fields.
2. **Regenerate + commit bindings.** After editing the struct, regenerate
   `core/generated/*.swift` + `*.kt` (Makefile) and commit them — CI builds the
   apps against the committed bindings.
3. **Update construction sites.** The generated Swift `ConversationItem` has a
   hand-written memberwise `init`; any test/mock that constructs a
   `ConversationItem` by hand (iOS `*Tests`, Android `*Test.kt`) must add the
   new args. Grep both apps for `ConversationItem(` before finishing.
4. **Tests.** Add `mod tests` cases in `conversation.rs` for each new
   classification/parse path (Tier 1 + Tier 3). Keep `cargo fmt`/`clippy -D
   warnings`/`cargo test` green.
5. **Mobile wiring is a follow-up.** This task is core-only. Once the fields
   exist, the dormant cards (PlanCard, SwapNotice) and the dropped sub-blocks
   (CommandCard cwd/host, HandoffCard TASK/progress/result) get wired in a
   separate mobile PR — they already reference these exact field names in
   comments.
