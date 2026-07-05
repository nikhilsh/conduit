# PLAN — Harness Builder

Status: design. A user-facing visual composer for multi-agent setups. "Harness"
is the product name for what the shipped **pipeline** subsystem
(`broker/internal/pipeline/`) becomes once each block carries its own agent,
model, reasoning effort, and instructions. Users stack blocks vertically (Apple
Shortcuts shape), see the topology, and configure each block.

This EXTENDS the pipeline subsystem — it does not fork a parallel one. Every
delta below lands on an existing type, handler, or screen.

Style + scope reference: `docs/PLAN-AGENT-PIPELINE.md`,
`docs/PLAN-PIPELINE-FANOUT-STEP.md`. Ground-truth seams verified against
`origin/main` @ bbc13be6.

---

## 0. What exists today (reused verbatim)

- **Pipeline subsystem is SHIPPED.** Capability flags `pipeline` /
  `gate_preview` / `resume` / `templates` / `fanout` are on
  (`ws/api.go:211-215`). `Step` (`pipeline.go:70-91`) carries
  `Index/AgentType/Role/PromptTemplate/InputFromPrev/GateAfter/SessionID/Phase/
  Retries/Fanout`. State machine: `PENDING → RUNNING(k) → STEP_DONE →
  (AWAITING_GATE?) → RUNNING(k+1) → COMPLETE`, terminals `FAILED` / `CANCELLED`
  / `AWAITING_PICK` (`pipeline.go:19-31`).
- **Session start already accepts per-session overrides.** `startSessionRequest`
  (`ws/api.go:244-266`) carries `reasoning_effort` / `model` / `permission_mode`
  / `fast_mode` → `session.SpawnOverride` (`override.go:17-36`) →
  `CreateOptions.Override` (`manager.go:2109-2114`). The override argv/mode
  plumbing (`extraArgsForAdapter`, `applyPermissionModeFromManifest`,
  `acpModeForOverride`) is all present and validated — a bad value is silently
  dropped, never breaks a spawn.
- **Model catalogs already served.** `/api/capabilities` returns `resp.Models`
  (`ModelCatalog()`) + `resp.Agents` (`AgentDescriptors()`, `api.go:216-217`),
  each agent an `AgentDescriptor{DisplayName, LoginProvider, Supports, Models[]}`
  with per-model `{ID, DisplayName, IsDefault, Efforts[], SupportsFastMode}`
  (`backend.go:92-110`). The fork / new-session pickers already consume this.
- **Prompt rendering** is literal `{{task}}` / `{{prev}}` `ReplaceAll`
  (`orchestrator.go:305-349`). Handoff contract: `BuildPrev(workdir, transcript,
  mode)` modes `none/output/memory/memory+output`; `HANDOFF-OUT.html`
  (`handoff.go`).
- **#881 (merged, in origin/main)**: completed/failed step sessions are reaped
  after handoff harvest via `terminateStepSession` (`orchestrator.go:231,256,
  265,274`); the fanout pick kills losers (`orchestrator.go:620-691`). Residual
  RAM risk is CONCURRENT fanout width, addressed in §5.

### The three drops this plan closes

1. **`Step` / `FanoutConfig` / `TemplateStep` carry no per-block model, effort,
   permission_mode, or instructions.** `pipeline.go:70-91`, `pipeline.go:54-67`,
   `templates.go:28-34`.
2. **The pipeline `SessionManager` seam drops the override on the floor.**
   `pipelineSessionManager.CreateSession(agentType, cwd, prompt, branch)`
   (`ws/pipeline.go:38-55`) builds `session.CreateOptions{CWD, Branch}` with
   `Override` left zero. The `pipeline.SessionManager` interface
   (`orchestrator.go:32-54`) has no override parameter. Widening this seam is the
   core Phase-1 change.
3. **Builder UIs hardcode the agent list and expose no model/effort/instruction
   controls.** iOS `agentOptions = ["claude","codex","opencode"]`
   (`ConduitPipelineBuilderView.swift:81`); Android `AGENT_TYPES =
   listOf("claude","codex","opencode")` (`PipelineBuilderScreen.kt:117`). Gemini
   is absent because the list is static, not driven by `capabilities.agents`.

---

## 1. Design decisions (decide once, here)

### 1.1 Instructions: user-turn prefix (default), NOT system prompt

Per-block `instructions` are delivered as a **prefix prepended to the rendered
`prompt_template`** before it becomes the initial user turn. Rationale:

- **Paid once into context**, not on every API call. The claude
  `--append-system-prompt` path (`conduitprompt.go`) rides EVERY request in the
  turn — costly, and claude-only. The global awareness prompt
  (`conduitprompt.go:52-61`) already rides every call; adding per-block system
  text multiplies that cost per step with no upside for a one-shot block.
- **Agent-agnostic.** A user-turn prefix works identically for claude, codex,
  and gemini. `--append-system-prompt` is claude-only; codex would need an
  AGENTS.md managed block; gemini has no equivalent. A system-prompt design
  would silently do nothing on two of three agents.
- **Composes with the existing renderer.** The prefix is prepended in
  `spawnStepOpts` right where `{{task}}`/`{{prev}}` are substituted
  (`orchestrator.go:305-349`) — one code path, no new delivery mechanism.

Wire shape: instructions render as a fenced preamble so the agent reads them as
standing guidance for this block, then the task:

```
<block-instructions>
{instructions}
</block-instructions>

{rendered prompt_template}
```

Empty `instructions` → no preamble, byte-identical to today. A future
`instructions_delivery: "system"` enum value can opt a claude block into
`--append-system-prompt` if a real need appears — schema below leaves room, v1
does not build it (Non-goal §7).

### 1.2 Per-block `permission_mode`: EXPOSED in v1, defaulted to auto

The override plumbing already honors `permission_mode` for claude
(`applyClaudePermissionMode`), codex (`applyCodexPermissionMode`), and gemini
(`acpModeForOverride` set_mode). It costs nothing to carry per block and it is
the single most useful safety control for a multi-agent harness (e.g. a "review"
block runs `plan` = read-only). Default `""`/`auto` = today's full-auto bypass,
so unset blocks are unchanged. Only two values in the v1 picker: **Auto** and
**Plan (read-only)** — matching the two the adapters actually implement.

### 1.3 Vertical block stack, not a canvas

Blocks are an ordered vertical list (Apple Shortcuts). Drag to reorder. Each
block is a `Card` with inline parameter chips (agent · model · effort · mode)
and a config sheet. Fanout is an indented cluster under its parent block (the
Monitor already renders this indented shape). Conditional branch (Phase 3) is a
block with two indented sub-stacks — NOT a graph editor (§6, Non-goal §7).

---

## 2. Phase 1 — mechanical plumb-through (broker + apps, no new UX)

Goal: every block can already carry model/effort/permission_mode/instructions
end-to-end, and gemini appears in the picker. NO new visual builder yet — the
existing Builder gains per-step controls. This is the load-bearing seam widening;
Phase 2 is pure UX on top.

### 2.1 Schema deltas

Add four fields to `Step`, `FanoutRun` (per-run override), `FanoutConfig`
(index-aligned parallel arrays, mirroring `AgentTypes`), and `TemplateStep`
(**lockstep — the silent-drop trap**). All optional; zero value = adapter
default → byte-identical to today.

`pipeline.Step` (`pipeline.go:70-91`) gains:

```json
{
  "model":            "sonnet",        // optional; "" = adapter default
  "reasoning_effort": "high",          // optional; "" = adapter default
  "permission_mode":  "plan",          // optional; "" / "auto" = full-auto
  "instructions":     "Be terse. Only touch the parser."   // optional; "" = none
}
```

`pipeline.TemplateStep` (`templates.go:28-34`) gains the **same four fields**.
Guard: a shared `StepConfig` embedded struct so the two cannot drift —

```go
// stepconfig.go (new, ~20 lines)
type StepConfig struct {
    Model           string `json:"model,omitempty"`
    ReasoningEffort string `json:"reasoning_effort,omitempty"`
    PermissionMode  string `json:"permission_mode,omitempty"`
    Instructions    string `json:"instructions,omitempty"`
}
```

Embed `StepConfig` in both `Step` and `TemplateStep`. One definition, no lockstep
bug possible. `FanoutConfig` gains index-aligned optional arrays (parallel to
its existing `AgentTypes []string`):

```json
{
  "count": 3,
  "agent_types":       ["claude", "codex", "gemini"],
  "models":            ["opus", "gpt-5-codex", ""],
  "reasoning_efforts": ["high", "high", ""],
  "permission_modes":  ["", "", "plan"],
  "instructions":      ["", "", "focus on tests"]
}
```

Per-run resolution: `models[i]` falls back to the step's `Step.Model`, which
falls back to the adapter default. Same for the other three. (Keeping fanout as
parallel arrays, not a `[]StepConfig`, matches the shipped `AgentTypes` shape and
the wire the apps already send.)

### 2.2 Widen the `SessionManager` seam (the core change)

`pipeline.SessionManager.CreateSession` (`orchestrator.go:32-54`) gains an
override param. Minimal, explicit — pass the resolved config, not the whole Step
(the interface must not import pipeline's Step, and the orchestrator already owns
resolution):

```go
// orchestrator.go
type StepOverride struct {
    Model, ReasoningEffort, PermissionMode, Instructions string
}
CreateSession(agentType, cwd, initialPrompt, branch string, ov StepOverride) (string, error)
```

`pipelineSessionManager.CreateSession` (`ws/pipeline.go:38-55`) maps
`StepOverride` → `session.SpawnOverride` and sets `CreateOptions.Override`:

```go
opts := session.CreateOptions{CWD: cwd, Branch: branch, Override: session.SpawnOverride{
    Model:           ov.Model,
    ReasoningEffort: ov.ReasoningEffort,
    PermissionMode:  ov.PermissionMode,
}}
```

Instructions are NOT part of `SpawnOverride` (they are prompt content, not argv).
The orchestrator prepends them to the rendered prompt (§2.3) and passes them out
of `CreateSession`'s prompt argument — so `ov.Instructions` on `StepOverride` is
only carried for the fanout per-run path where the orchestrator renders per run;
for the normal path the orchestrator has already folded instructions into
`initialPrompt`. (Documented on the struct so a reader doesn't double-apply.)

### 2.3 Instructions rendering

In `spawnStepOpts`, after the `{{task}}`/`{{prev}}` substitution
(`orchestrator.go:349`), prepend the block-instructions preamble (§1.1) when
`step.Instructions != ""`. One `if` + one `Sprintf`. The `overridePrompt` resume
path (`orchestrator.go:300-303`) skips this — a resume reuses the amended prompt
verbatim, and re-prepending would double the preamble.

### 2.4 API deltas

- `POST /api/pipeline` `createPipelineStepRequest` (`ws/pipeline.go:154-162`)
  gains the four fields + fanout parallel arrays. Copied into `pipeline.Step` at
  `ws/pipeline.go:209`.
- `POST /api/pipeline-templates` `templateStepRequest` (`ws/pipeline.go:546`)
  gains the four fields. Both marshal for free once `StepConfig` is embedded.
- `GET /api/pipeline/{id}` returns them for free (serves `pipeline.json`).
- New capability flag `pipeline_block_config` (`ws/api.go`, alongside
  `PipelineFanout`) so an app can detect a broker that honors per-block config
  vs an old one that would silently drop it. **Apps must gate the config UI on
  this flag** — an old broker ignores the fields and every block runs adapter
  defaults with no error (the drift this flag prevents).

### 2.5 Builder pickers driven by `capabilities.agents`

Replace the hardcoded `agentOptions` / `AGENT_TYPES` with the live
`capabilities.agents` list (iOS `ConduitPipelineBuilderView.swift:81`, Android
`PipelineBuilderScreen.kt:117`). Gemini appears automatically. For the selected
agent, the model picker reads that agent's `Models[]`, the effort picker reads
the chosen model's `Efforts[]` (empty → hide the effort control, e.g. gemini),
and permission mode shows Auto/Plan gated on `supports.plan_mode`. This is the
same catalog the fork / new-session pickers already consume — reuse that view
model, do not re-fetch.

**Gemini caveat surfaced in the UI:** a gemini model picker is a **silent no-op**
until Phase 3 — `SpawnOverride.Model` is ignored for ACP
(`backend_acpwire.go:611-613`: gemini picks its model at `session/new`), and
gemini has modes not efforts. In Phase 1 the gemini model row is **hidden
entirely** (owner decision, §8.3 — a visible control must always be honored),
and the effort control is hidden (its `Efforts[]` is empty). Permission mode
(Auto/Plan) DOES work for gemini via `acpModeForOverride`, so it stays enabled.

### 2.6 Files touched — Phase 1

Broker (must stay ≤ small surface):
- `broker/internal/pipeline/stepconfig.go` (new, embedded `StepConfig`)
- `broker/internal/pipeline/pipeline.go` (embed in `Step`; fanout arrays)
- `broker/internal/pipeline/templates.go` (embed in `TemplateStep`)
- `broker/internal/pipeline/orchestrator.go` (interface param; resolve + prepend)
- `broker/internal/ws/pipeline.go` (request structs; map to `SpawnOverride`)
- `broker/internal/ws/api.go` (`pipeline_block_config` flag)

Apps (iOS + Android, parity):
- iOS `ConduitPipelineBuilderView.swift` (dynamic agents; model/effort/mode/
  instructions on `PipelineStep` + request encoders at `:758,:880`)
- Android `PipelineBuilderScreen.kt` (same on `PipelineStepDraft:69`, request
  encoders)

Backend-abstraction budget: a new backend still touches ≤3 files outside its
package — this plan adds NO new name-switch; agents come from the descriptor
list.

### 2.7 Ships broker-only vs app

- Broker schema + seam widening + flag: **broker-only, redeploy required** (it is
  a `broker/` change and must be live for the app config to take effect — a hard
  gate per CLAUDE.md).
- Builder controls: **app**, CI-compile-only, gated on `pipeline_block_config`.
  Ship broker first, redeploy, then the app degrades gracefully against any
  broker.

### 2.8 Test strategy — Phase 1

- Broker unit: `StepConfig` round-trips through `Step` and `TemplateStep` JSON
  (guards the lockstep). A fake `SessionManager` asserts `CreateSession` receives
  the resolved `StepOverride` for both normal and fanout (per-run fallback:
  `models[i]` empty → step model → adapter default). Instructions-preamble is
  present for a normal spawn and ABSENT on the resume/`overridePrompt` path.
- A malformed/unknown model or effort must NOT fail the spawn (the override layer
  already drops it — add a test asserting the pipeline still reaches RUNNING).
- iOS `ConduitTests` / Android unit: request encoder emits the four fields;
  decoder tolerates a response without them (old broker).

### 2.9 RAM / token cost — Phase 1

- RAM: unchanged. No new concurrency; one live child per sequential step, fanout
  width already bounded 1–6 (§5 caps concurrency in Phase 3).
- Tokens: instructions preamble is paid **once** into the block's context (§1.1),
  ~tens–hundreds of tokens per block. Per-block model/effort can REDUCE cost
  (cheaper model / lower effort on trivial blocks) — a net win the current
  one-model-per-pipeline shape can't express.

---

## 3. Phase 2 — visual builder UX (app only, iOS + Android + both tablets)

Goal: the Shortcuts-style vertical builder. No broker change — Phase 1 already
made the schema expressive. Pure composition from the component library.

### 3.1 Screens / components

- **Block card** (`Card`, radius 14): leading tinted agent symbol, title
  (role), inline parameter chips (`Chip`) for `agent · model · effort · mode`.
  Tapping opens the config sheet. A drag handle reorders.
- **Config sheet**: agent picker (from `capabilities.agents`), model picker,
  effort picker (hidden when `Efforts[]` empty), permission mode (Auto/Plan,
  gated on `supports.plan_mode`), `input_from_prev` selector, `gate_after`
  toggle, and an instructions text field. Fanout toggle expands the indented
  per-run cluster (reuses the Phase-1 parallel-array editor).
- **Topology preview**: a compact read-only rail rendering the stack top-to-
  bottom with gate/fanout markers — the same shape the Monitor already draws for
  a running pipeline, reused as a preview of the not-yet-started harness.
- **Reuse:** `Card`, `ListRow`/`valueRow`/`toggleRow`, `Chip`, `PillButton`,
  `Header` (iOS `ConduitUI/Components`; Android `ui/components` mirror). No raw
  color/radius/hex. New recurring shapes (e.g. the block card, if not expressible
  as `Card` + chips) become a component in BOTH libraries value-for-value.

### 3.2 Tablet parity (mandatory)

Per the app-UI-parity default: ship iOS phone + iPad AND Android phone + tablet
in the same PR. Tablet layout = two-pane (block list rail | selected-block config
inspector) instead of a modal sheet; phone = stacked list + sheet. Both read the
same view model.

### 3.3 Files touched — Phase 2

- iOS: `ConduitPipelineBuilderView.swift` rework into block-card stack +
  config sheet; possible new `ConduitUI/Components` block card; iPad two-pane.
- Android: `PipelineBuilderScreen.kt` mirror; `ui/components` block card; tablet
  two-pane.
- No broker files. No capability flag (rides `pipeline_block_config` from P1).

### 3.4 Test strategy — Phase 2

- Cross-platform ARGB component tests stay green (any new component).
- iOS `ConduitTests` / Android unit: builder view model produces the same
  `createPipelineRequest` JSON from a composed harness as the Phase-1 form did
  (behavior-preserving reshape). Drag-reorder reindexes steps 0..n-1.
- Everything visual is **needs on-device verification** (CI is compile-only).

### 3.5 RAM / token — Phase 2

None. App-only UX; no new live agents, no new prompt content.

---

## 4. Phase 3 — new primitives (broker + app)

Three independent sub-features. Each ships on its own flag; none blocks the
others.

### 4.1 Conditional branch — `If/Else` block

Expressed in the vertical stack as **one block with two indented sub-stacks**
(Shortcuts `If`), never a graph. Schema: a step declares a `branch` instead of an
agent invocation.

```json
{
  "index": 2,
  "kind": "branch",
  "branch": {
    "condition": {
      "source": "prev_output",         // the {{prev}} of the completed step
      "predicate": "contains",         // contains | not_contains | matches
      "value": "APPROVED"
    },
    "then": [ /* nested Step[] */ ],
    "else": [ /* nested Step[] */ ]
  }
}
```

State-machine delta (`orchestrator.go` Advance): on reaching a `branch` step, the
orchestrator evaluates `condition` against the previous step's harvested output
(no agent spawned — deterministic, cheap), selects `then`/`else`, and splices the
chosen sub-stack's steps into the run inline. **Bounded:** nesting depth capped at
2 (validated at create), no branch inside a branch's condition. The condition is
deterministic string matching only — **no LLM judge** (Non-goal §7); a human gate
remains the way to get judgment.

Discriminator: `kind: "branch"` (vs today's implicit agent step). A step with no
`kind` is an agent step — back-compatible.

### 4.2 Loop-until — bounded

```json
{
  "index": 3,
  "kind": "loop",
  "loop": {
    "body":            [ /* nested Step[] */ ],
    "until": { "source": "prev_output", "predicate": "contains", "value": "DONE" },
    "max_iterations":  3
  }
}
```

`max_iterations` is REQUIRED and hard-capped (validated ≤ 5 at create) — an
unbounded loop on a RAM-constrained box with paid agents is the primary footgun.
The state machine tracks `iteration` in live state; each pass re-spawns the body
sequentially (reaping between iterations via the existing
`terminateStepSession`), evaluates `until`, and stops on match OR at
`max_iterations`. Reaching the cap without a match is **success, not failure**
(the loop is best-effort); surface the iteration count in the run view.

### 4.3 Gemini model-override in ACP backend

Make `SpawnOverride.Model` honored for gemini so the Phase-1 gemini model picker
stops being a no-op. Today `session/new` sets the model via `currentModelId` and
the override is dropped (`backend_acpwire.go:607-625`). Delta: pass the override
model as the `currentModelId` (or the ACP `session/new` model param) when
non-empty and the model is in the advertised `AvailableModels`
(`backend_acpwire.go:240`); drop-if-unknown, same safety rule as argv. Then flip
the Phase-1 gemini model row from disabled to enabled (gated on a
`supports` bit or broker version). Effort stays hidden (gemini has modes, not
efforts — unchanged).

### 4.4 Concurrency cap (if not already shipped)

The residual RAM risk after #881 is CONCURRENT fanout width (1–6) plus any
future loop/branch parallelism on a ~3.9GB box where the memwatch kills agents
> 1500MB/120s. Add a **broker-enforced global cap on concurrent live agent
processes** (recommend 2–3), queueing excess fanout runs: `spawnFanout` spawns up
to the cap, and `pollFanout` starts a queued run as each completes and is reaped.
This bounds peak RSS regardless of declared width. Config via env
(`CONDUIT_MAX_CONCURRENT_AGENTS`, default 3). Pure broker; no schema, no app.

### 4.5 Files / flags — Phase 3

- Branch: `pipeline.go` (`kind`, `Branch` type, nested `Steps`), `orchestrator.go`
  (evaluate + splice), validation (depth ≤ 2); flag `pipeline_branch`.
- Loop: `pipeline.go` (`Loop` type), `orchestrator.go` (iteration state);
  validation (`max_iterations` ≤ 5); flag `pipeline_loop`.
- Gemini model: `backend_acpwire.go` only; no flag (version-gated) or a
  `supports.model_override` bit.
- Concurrency cap: `orchestrator.go` + a semaphore in the session manager seam;
  no schema.
- Apps: If/Else + Loop blocks in the vertical builder (indented sub-stacks); each
  gated on its flag. iOS + Android + tablets.

### 4.6 Test strategy — Phase 3

- Branch: condition evaluation table test (contains/not_contains/matches × then/
  else); depth-2 validation rejects depth-3; a branch with no matching agent
  output takes `else`.
- Loop: stops on `until` match; stops at `max_iterations` with SUCCESS; `> 5`
  rejected at create; body reaped between iterations (fake SessionManager asserts
  `CancelSession` per pass).
- Gemini: override model in advertised set is applied to `session/new`; unknown
  model dropped, session still starts.
- Concurrency: with cap=2 and a fanout of 4, at most 2 sessions are live at once;
  the 3rd starts only after one is reaped.

### 4.7 RAM / token — Phase 3

- Branch: condition eval spawns NO agent — free. Splicing runs the same one-at-a-
  time sequential path.
- Loop: bounded by `max_iterations` × body cost. The cap is the safety valve.
- Concurrency cap: strictly REDUCES peak RSS vs today's uncapped fanout.

---

## 5. Concurrency / RAM envelope (cross-cutting)

- Today: sequential = 1 live child; fanout = up to 6 concurrent, reaped on pick/
  advance (#881). Box ~3.9GB, memwatch kills > 1500MB/120s (per box-local
  service; not in repo).
- Phase 1/2 add NO concurrency. Phase 3's loop is sequential; branch spawns
  nothing to evaluate. The one place width can bite is fanout — capped in §4.4.
- Recommendation: land §4.4's global cap EARLY (it is broker-only, no schema) if
  fanout usage grows before Phase 3 — it is safe to pull forward.

---

## 6. Why If/Else fits a vertical stack (not a graph)

A graph editor (n8n/ComfyUI/AgentKit) is a desktop 2-D canvas pattern — wrong for
a phone. Shortcuts proves control flow works as a **linear list with indentation**:
`If` opens an indented `then` region and an `else` region, both closed by the next
top-level block. The user scrolls one axis. Conduit's `branch` step renders
exactly this: the block card shows the condition; its `then`/`else` sub-stacks are
indented block lists (same block card component, one level in). No edges, no
free-positioning, no zoom. Loop is the same shape with one body region and an
iteration cap chip. This keeps the mental model = Claude Code subagents
(name/description/model/instructions), a block, not a node in a DAG.

---

## 7. Non-goals

- **Free 2-D canvas / node graph.** Desktop pattern; the vertical stack is the
  decision (§6).
- **Auto-pick / LLM judge without a human.** Fanout pick and branch conditions
  are human-gated or deterministic string matching. No model-scores-model
  auto-advance in this plan.
- **Nested fanout** (a fanout run that is itself a fanout). Width explodes on a
  RAM-constrained box; not supported.
- **Branch/loop nesting beyond depth 2.** Validated out at create.
- **Multi-box / cross-box harnesses.** A harness runs on one box (its
  credentials, worktrees, and reaping are per-box). Distributing steps across
  boxes is out of scope.
- **System-prompt instructions in v1** (`--append-system-prompt`). Schema leaves
  room (§1.1) but v1 ships user-turn-prefix only.
- **Per-block CWD / different repos per step.** A harness shares the pipeline's
  one CWD/base.

---

## 8. Decisions (owner, 2026-07-05)

1. **Fanout per-run instructions — NO for v1.** Runs share the block's
   instructions ("share block for now"). Per-run agent+model stays; the
   parallel-array field can be added later without a wire break.
2. **Concurrency cap — default 3.** Purpose (owner asked): RAM protection.
   Each claude/codex process runs 1–1.5GB against a ~3.9GB box shared with the
   live broker, and memwatch kills any agent >1500MB/120s — an uncapped
   fanout-of-6 would demand ~6–9GB and surface as spurious step failures when
   the watchdog fires. Excess runs queue; nothing is dropped. 3 matches the
   repo's proven ~3-concurrent-agent operating envelope; make it a broker
   flag so it can be lowered to 2 if OOMs recur.
3. **Model pickers offer ONLY what the box actually reports** ("just enable
   models that the VPS has"): options come from the live
   `capabilities.agents[<agent>].models[]` catalog, never a hardcoded list.
   Consequence for gemini: since the ACP backend drops `SpawnOverride.Model`
   until Phase 3, gemini gets NO model row in Phase 1 (hidden, not
   disabled-with-caption) — a visible control must always be honored.
4. **Branch condition sources — proposed options** (owner asked for options;
   pick before Phase 3 starts, Phases 1–2 are unaffected):
   - **A. `prev_output`** (last assistant text; predicates
     `contains|not_contains|matches`) — already designed in §4.1. The
     harness author instructs the block to end with a marker line
     (e.g. `VERDICT: PASS`). **Recommended for v1.**
   - **B. `exit_status`** (previous step succeeded vs failed) — free,
     fully deterministic, no prompt discipline needed. **Recommended for
     v1** alongside A (it is ~20 lines given the phase is already tracked).
   - C. `git` facts (files_changed / insertions from `DiffSummary`, numeric
     predicates `gt|eq`) — enables "did it actually change anything?"
     branches. Defer unless a real harness needs it.
   - D. `prev_memory` (match against the HANDOFF-OUT section) — defer;
     overlaps A once markers are in the handoff.
5. **Loop `max_iterations` cap stays 5.** Purpose (owner asked): runaway
   protection — an until-condition that never matches would otherwise re-spawn
   paid agent turns forever and wedge the run. Hitting the cap is success-with-
   count (§4.2), so 5 is a ceiling on spend, not a correctness limit.
6. **Naming stays "pipeline"** ("pipeline is okay for now") — no API or
   product-copy rename; "harness builder" remains the design doc's working
   title only.
