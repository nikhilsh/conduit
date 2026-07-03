# PLAN — Fanout-as-a-Step

Status: design. NEW step type for the Sequential Agent Pipeline. Realizes
PLAN-AGENT-PIPELINE §12's deferred `agent_type: "fanout"` note: a single
pipeline step that runs N parallel sub-runs, then a human picks the winner
whose HANDOFF-OUT + output becomes `{{prev}}` for the next step.

Builds on shipped seams: the pipeline subsystem (`broker/internal/pipeline/`),
the fanout compare subsystem (`broker/internal/ws/fanout.go` + `session.DiffSummary`),
per-step worktree branches (`pipeline-<id>-step-<k>` via `CreateOptions.Branch`),
the persisted `GatePreview`, and the frozen HANDOFF-OUT contract.

---

## 0. What exists today (and what we reuse verbatim)

- **Sequential pipeline**: one live child per pipeline. State machine drives
  `PENDING → RUNNING(k) → STEP_DONE(k) → (AWAITING_GATE(k)?) → RUNNING(k+1) →
  COMPLETE`, with `FAILED(k)` / `CANCELLED` terminals (PLAN-AGENT-PIPELINE §4).
- **Gate pattern (the differentiator we mirror)**: `gate_after: true` → broker
  computes a persisted `GatePreview` at gate entry (`Advance`), fires a push,
  and blocks until `POST /api/pipeline/{id}/continue`. Continue may amend
  `Gate.Prev`; `spawnStep` reuses `Gate.Prev` when `Gate.Step == k-1`
  (`orchestrator.go:228`). We copy this shape exactly for the pick.
- **Fanout compare**: `POST /api/fanout/compare` takes a list of session IDs and
  returns per-run `{phase, files_changed, insertions, deletions, diff_stat,
  agent_summary, error}` (`fanout.go`). Built on `session.DiffSummary(workdir,
  base)` + `lastAssistantSummary`. **This is the payload the pick screen shows.**
- **Parallel sessions are already safe**: today's fanout launches N independent
  sessions via repeated `POST /api/session/start` on the same box — the
  credential store is per-box shared and the existing subsystem runs them in
  parallel with no serialization. The fanout step spawns the same way, so it
  inherits the same safety envelope (§3).
- **Per-step branches**: `spawnStep` names each branch `pipeline-<id>-step-<k>`
  and passes it via `CreateOptions.Branch`.

Nothing in the sequential path changes behavior. A fanout step is a new
`kind` a step may declare; non-fanout steps are untouched.

---

## 1. Step schema — declaring fanout

A step becomes a fanout step by setting a `fanout` object. Its presence is the
discriminator (no separate `agent_type: "fanout"` sentinel — that would collide
with the agent-type registry and force a fake adapter). `agent_type`/`role` on
the step become the **defaults** for runs that don't override.

```json
{
  "index": 1,
  "role": "engineer",
  "agent_type": "claude",
  "prompt_template": "Implement the approved design:\n{{prev}}",
  "input_from_prev": "memory+output",
  "gate_after": false,
  "fanout": {
    "count": 3,
    "agent_types": ["claude", "codex", "opencode"]
  }
}
```

`fanout` config:
- `count` (int, 1–6): number of parallel runs. Required. Bounded (§3).
- `agent_types` ([]string, optional): per-run agent type, index-aligned. When
  present its length MUST equal `count`; each entry must be an installed agent.
  When **absent or empty**, all runs use the step's own `agent_type` (N runs of
  the same agent — a temperature/seed race, still meaningful because agents are
  non-deterministic). When present, `count` may be omitted and inferred as
  `len(agent_types)`; if both are given they must agree (400 otherwise).

**Prompt is identical across runs.** Every run gets the same rendered
`prompt_template` (same `{{task}}`/`{{prev}}` substitution). Templates stay
literal-substitution only — no per-run branching in the template. The only
per-run variation is the agent CLI.

Persisted per-run state lives in a `runs` array on the step, populated as the
runs spawn (mirrors how `session_id`/`phase` are populated on a normal step):

```json
"fanout": {
  "count": 3,
  "agent_types": ["claude", "codex", "opencode"],
  "runs": [
    { "index": 0, "agent_type": "claude",   "session_id": "s_…", "branch": "pipeline-p_ab-step-1-run-0", "phase": "exited(0)", "started": "…", "ended": "…" },
    { "index": 1, "agent_type": "codex",     "session_id": "s_…", "branch": "pipeline-p_ab-step-1-run-1", "phase": "exited(1)", "started": "…", "ended": "…" },
    { "index": 2, "agent_type": "opencode",  "session_id": "s_…", "branch": "pipeline-p_ab-step-1-run-2", "phase": "running",   "started": "…", "ended": "" }
  ],
  "winner": null
}
```

`winner` (int or null) is the picked run index. Null until the human picks.
The step's top-level `session_id` is set to the **winner's** session id at pick
time so all existing "tap a step to open its session" navigation and handoff
code (`GetWorktreeDir(step.SessionID)`, `GetLastAssistantText(step.SessionID)`)
work unchanged for downstream steps.

Go types (added to `pipeline.go`):

```go
type FanoutRun struct {
    Index     int    `json:"index"`
    AgentType string `json:"agent_type"`
    SessionID string `json:"session_id,omitempty"`
    Branch    string `json:"branch,omitempty"`
    Phase     string `json:"phase,omitempty"`
    Started   string `json:"started,omitempty"`
    Ended     string `json:"ended,omitempty"`
}

type FanoutConfig struct {
    Count      int          `json:"count"`
    AgentTypes []string     `json:"agent_types,omitempty"`
    Runs       []FanoutRun  `json:"runs,omitempty"`
    Winner     *int         `json:"winner,omitempty"`
}

// Added to Step:
Fanout *FanoutConfig `json:"fanout,omitempty"`
```

`Step.IsFanout()` helper = `s.Fanout != nil && s.Fanout.Count > 0`.

---

## 2. State machine delta

A new pipeline state `AWAITING_PICK` mirrors `AWAITING_GATE`. The fanout step's
lifecycle inserts a fan-out spawn + join + pick between RUNNING and STEP_DONE.

```
                RUNNING(step k)                        [k is a fanout step]
                     │  spawn N runs in parallel (§5 branches)
                     ▼
              FANNING_OUT(k)      ← state="running", all runs live
                     │  ALL runs reach exited(*)
        ┌────────────┴─────────────┐
   ≥1 run exited(0)           ALL runs exited(≠0)
        │                          │
        ▼                          ▼
   AWAITING_PICK(k)            FAILED(k)   (step fails only if ALL runs fail)
        │ POST …/pick {"run": i}
        │  (i must be a succeeded run; 409 otherwise)
        ▼
   winner set → step.session_id = runs[i].session_id
        │
        ├─ gate_after=true ─► compute GatePreview from WINNER ─► AWAITING_GATE(k)
        │                        │ POST …/continue
        └─ gate_after=false ─────┴────────► RUNNING(step k+1) or COMPLETE
```

Notes:
- `FANNING_OUT` is represented in `pipeline.json` as `state: "running"` with a
  fanout step at `current_step` whose runs are live — the app derives the
  fan-out sub-state from `fanout.runs`, so no new *persisted* value beyond
  `AWAITING_PICK` is strictly required. We still add the explicit
  `PipelineAwaitingPick` constant for the pick-blocked state.
- **Auto-pick is NOT in v1.** Human pick only. This is the product's
  differentiator — a phone-driven best-of decision. An `auto_pick` policy
  (most-files-changed, first-to-exit-0, etc.) is a v2 note (§11). Shipping
  auto-pick now would let the pipeline advance on a fabricated ranking, which
  PLAN-FANOUT-COMPARE §6 explicitly forbids ("no fabricated ranking").
- Cancel while `FANNING_OUT` or `AWAITING_PICK`: kill **all** live run sessions
  (loop `fanout.runs`), then `CANCELLED`.

New state constant:
```go
PipelineAwaitingPick PipelineState = "awaiting_pick"
```

---

## 3. Invariants (§11 delta)

The sequential pipeline's **single-live-child** invariant is *deliberately
relaxed for a fanout step*: N children are live at once, within that step only.
Everything else in §11 holds unchanged. The relaxation is bounded by:

- **Credential contention** — the existing fanout subsystem already runs N
  sessions concurrently against the per-box shared credential store with no
  extra locking, and that is the shipped, proven-safe path. The fanout step
  spawns runs through the **same** `SessionManager.CreateSession` used by
  sequential steps, one call per run, so it inherits that exact safety envelope.
  No new credential coordination is invented (mirroring the fanout subsystem is
  the whole point). We do NOT add a fanout step inside another fanout step
  (nesting) — that would multiply the live-child count unpredictably; a fanout
  step's runs are always plain single-agent sessions.
- **Concurrency bound** — `count ∈ [1, 6]`, validated at create. 6 is the same
  practical ceiling the FanOut UI offers and keeps box RAM sane (CLAUDE.md caps
  agent concurrency ~3, but those are heavyweight orchestrator agents; fanout
  runs are ordinary sessions the box already handles in the compare flow).
  At most one fanout step is live per pipeline (the pipeline is still
  sequential *between* steps), so the box never exceeds `count` concurrent
  pipeline children.
- **Failure semantics** — a fanout step FAILS only if **ALL** runs exit
  non-zero. If ≥1 run exits(0), the step proceeds to `AWAITING_PICK`. Failed
  runs are NOT removed; they appear **greyed** in the pick UI (their
  `error`/non-zero phase surfaced), and the pick endpoint **rejects** selecting
  a failed run (409). This matches PLAN-FANOUT-COMPARE §4 ("Failed/empty runs
  render greyed … no actions except Open").
- **Handoff still uses the frozen contract** — `{{prev}}` for step k+1 is built
  from the *winner's* worktree HANDOFF-OUT + transcript via the existing
  `BuildPrev` — no new format.
- **A phone never auto-merges** — losers are never merged; picking a winner
  only sets which run feeds `{{prev}}`. Promotion to a PR remains the explicit
  DiffReview/commit path if the user wants it, exactly as PLAN-FANOUT-COMPARE §3.

---

## 4. Handoff + gate interaction

Once the human picks run `i`:

1. `fanout.winner = i`; `step.session_id = runs[i].session_id`;
   `step.phase = runs[i].phase` (the winner's `exited(0)`).
2. Losers' worktrees are **kept** (not cleaned) in v1. Justification: the pick
   is a phone decision the user may want to revisit — they can open a loser's
   session from the pick screen to inspect its diff, and PLAN-FANOUT-COMPARE's
   "Discard losers" is already an explicit, confirm-gated action, never
   automatic. Auto-deleting on pick would silently destroy work and violate the
   "error is transparent / artifacts preserved" invariant. Cleanup is a
   deferred, explicit affordance (§11 v2: a `DELETE …/runs/{i}` or reuse of
   `DELETE /api/session/{loserID}`).
3. Handoff then follows the **normal** path keyed on `step.session_id`:
   - **`gate_after: false`** → `spawnNext` builds `{{prev}}` from the winner's
     `GetWorktreeDir`/`GetLastAssistantText` via `BuildPrev` and spawns step
     k+1 (or COMPLETE). Unchanged code.
   - **`gate_after: true`** → after the pick, the orchestrator computes and
     persists the `GatePreview` from the **winner** exactly as `Advance` does
     today, sets `AWAITING_GATE(k)`, fires the gate push, and blocks for
     `POST …/continue`. The Continue path then reuses `Gate.Prev` (amendable)
     verbatim.

**Ordering of pick vs gate**: pick ALWAYS precedes gate. A fanout step with
`gate_after: true` requires two taps — pick the winner, then approve the
handoff. This is intentional: the winner is undefined until picked, so the gate
preview cannot be computed before the pick. The pick endpoint drives the
transition into `AWAITING_GATE`; there is no combined "pick+continue" in v1
(keeps each seam single-purpose; the app can chain the two calls if it wants a
one-tap UX, but the broker states stay distinct).

**GatePreview interaction**: `GatePreview.Step` continues to mean "the completed
step index k". Because `step.session_id` is the winner by the time the gate
preview is computed, the persisted `Gate` object and the `spawnStep`
`Gate.Step == k-1` reuse path need **zero** changes — they already read from
`step.session_id`.

---

## 5. Branches

Per-run branch extends the existing `pipeline-<id>-step-<k>` scheme with a run
suffix:

```
pipeline-<id>-step-<k>-run-<i>        e.g. pipeline-p_ab12-step-1-run-2
```

Passed via `CreateOptions.Branch` on each run's `CreateSession`, identical to
how a normal step passes its branch. The winner keeps its own
`-run-<i>` branch (we do NOT rename it to the bare step branch — renaming a
live git branch across a worktree is fragile and the downstream `{{prev}}`
build reads the winner's worktree by session id, not by branch name, so the
name is cosmetic). Downstream step k+1 gets its own `-step-<k+1>` branch as
usual.

---

## 6. Endpoints

### 6.1 Create (extended — no new route)

`POST /api/pipeline` gains an optional `fanout` object per step:

```json
{
  "title": "Implement rate limiter (fan-out engineer)",
  "cwd": "/root/developer/projects/conduit",
  "base": "main",
  "task": "Add a token-bucket rate limiter to the WS broker.",
  "steps": [
    { "agent_type": "claude", "role": "architect",
      "prompt_template": "Design it:\n{{task}}",
      "input_from_prev": "none", "gate_after": true },
    { "agent_type": "claude", "role": "engineer",
      "prompt_template": "Implement the approved design:\n{{prev}}",
      "input_from_prev": "memory+output", "gate_after": false,
      "fanout": { "count": 3, "agent_types": ["claude", "codex", "opencode"] } }
  ]
}
```

Validation (400 `invalid_request` on any):
- `count` present and `1 ≤ count ≤ 6`.
- If `agent_types` present: every entry non-empty + installed; `len == count`
  (or `count` omitted → inferred).
- Each `agent_type` (step-level default too) is an installed agent.
- A fanout step MUST NOT itself set `agent_type: "fanout"` (no such agent).

Response unchanged: `{ "id", "state", "current_step" }`.

### 6.2 Pick (new route)

```
POST /api/pipeline/{id}/pick
```

Request:
```json
{ "run": 2 }
```

Behavior:
- 409 `not_at_pick` if `state != awaiting_pick`.
- 400 `invalid_request` if `run` out of range.
- 409 `run_failed` if the selected run's phase is not `exited(0)`.
- On success: set `fanout.winner`, `step.session_id`, drive the state machine
  (→ AWAITING_GATE or RUNNING(k+1)/COMPLETE per §4), persist.

Response:
```json
{ "id": "p_ab12", "state": "awaiting_gate", "current_step": 1, "winner": 2 }
```
(`state` is `awaiting_gate` when the step had `gate_after: true`, else
`running` or `complete`.)

### 6.3 Pick preview data — reuse `POST /api/fanout/compare`

The pick screen does NOT get a bespoke diff endpoint. When the pipeline is
`AWAITING_PICK`, the app reads `fanout.runs` from `GET /api/pipeline/{id}`
(session ids, per-run agent types, phases), then calls the **existing**
`POST /api/fanout/compare` with those session ids and the pipeline `base` to
fetch `files_changed/insertions/deletions/diff_stat/agent_summary/error` per
run. Same response shape the FanOut compare view already renders. This keeps a
single diff-stat implementation and lets the pick screen compose the shipped
compare view (§9).

`GET /api/pipeline/{id}` already serves the whole `pipeline.json` (so `fanout`
+ `runs` + `winner` ride along for free — no handler change beyond the schema).

### 6.4 Continue / Delete — unchanged

`POST …/continue` and `DELETE …/{id}` are unchanged. Cancel must additionally
loop `fanout.runs` to kill all live run sessions (§7 orchestrator change).

---

## 7. Broker file-touch list

1. **`broker/internal/pipeline/pipeline.go`**: add `FanoutRun`,
   `FanoutConfig`, `Step.Fanout`, `Step.IsFanout()`, `PipelineAwaitingPick`.
2. **`broker/internal/pipeline/orchestrator.go`**:
   - `spawnStep`: if `step.IsFanout()`, call new `spawnFanout` (spawn N runs,
     name branches `-run-<i>`, populate `fanout.runs`, start a `pollFanout`
     goroutine) instead of the single-session path.
   - New `spawnFanout` + `pollFanout` (polls until ALL runs exit; then
     `advanceFanout`).
   - New `advanceFanout`: if all failed → `FAILED`; else → `AWAITING_PICK`,
     fire pick push.
   - New `Pick(p, runIdx)`: validate, set winner + `step.session_id`, then reuse
     the existing post-success logic — if `gate_after` compute `GatePreview`
     from winner and go `AWAITING_GATE`, else `spawnNext`. Factor the
     "step succeeded → gate-or-next" tail of `Advance` into a shared helper
     `afterStepSuccess(p, k)` so both `Advance` (sequential) and `Pick` call it.
   - `Cancel`: loop `fanout.runs` to cancel all live run sessions.
   - New errors `ErrNotAtPick`, `ErrRunFailed`.
3. **`broker/internal/pipeline/handoff.go`**: no change — `BuildPrev` already
   works off the winner's workdir/transcript.
4. **`broker/internal/ws/pipeline.go`**:
   - `createPipelineStepRequest`: add `Fanout *fanoutStepReq` with `Count` +
     `AgentTypes`; validate + copy into `pipeline.Step.Fanout`.
   - New `serveePickPipeline` handler + route in `servePipelineRouter`
     (`strings.HasSuffix(path, "/pick")`). Parse `{run}`, load, `orch.Pick`,
     map `ErrNotAtPick`→409 `not_at_pick`, `ErrRunFailed`→409 `run_failed`.
   - The `pipelineSessionManager` already provides everything
     `spawnFanout` needs (CreateSession/GetPhase/GetWorktreeDir/
     GetLastAssistantText/CancelSession) — no adapter change.
5. **`broker/internal/ws/server.go`**: the existing `/api/pipeline/` prefix
   route already dispatches `/pick` through `servePipelineRouter`; add the
   `/pick` case. No new `mux.HandleFunc`.
6. **`broker/internal/ws/api.go`** (`/api/capabilities`): add
   `resp.Features.PipelineFanout = true` and the struct field
   `PipelineFanout bool json:"pipeline_fanout"`. **Capability flag name:
   `pipeline_fanout`.** Apps gate the fanout-step builder control AND the pick
   screen on this specific flag (not the sibling `pipeline` flag — the
   registry-parity footgun: gate each capability on its own flag).

No protocol/UniFFI/`chat_mode` change. Fanout is HTTP-only, like compare.

---

## 8. App contract

### Builder (define a fanout step)
- Gate the "Fan out this step" control on `capabilities.features.pipeline_fanout`.
- Per step, a toggle "Fan out". When on:
  - run count stepper (1–6),
  - optional per-run agent pickers (populated from `/api/capabilities` agents);
    default = "same agent × N" when left unset.
- Serialize into the step's `fanout` object in the `POST /api/pipeline` body.
- A fanout step and `gate_after` are independent toggles (both may be on).

### Monitor + Pick screen
- Monitor stepper: a fanout step renders its sub-runs (from `fanout.runs`) as a
  small cluster under the step row — per-run agent avatar + live phase chip
  (queued/running/done/failed), reusing the FanOut run-tint styling.
- When `state == awaiting_pick` at this step:
  - Fetch diff stats via `POST /api/fanout/compare` (session ids from
    `fanout.runs`, `base` from the pipeline) and **present the existing
    FanOut compare view** (`ConduitFanOutCompareView` / `FanOutCompareScreen`)
    — do not build a new diff UI.
  - The compare rows' primary action becomes **"Pick this run"** →
    `POST /api/pipeline/{id}/pick {"run": i}`. The compare view already exposes
    per-row actions (Open / Commit&PR); add a "Pick" action wired to the pick
    endpoint, shown only in the pipeline-pick context.
  - Failed runs render greyed (compare view already does this via `error`);
    their "Pick" action is disabled.
  - Push notification on `AWAITING_PICK` deep-links to this screen.
- After a successful pick: if the step had `gate_after`, the monitor transitions
  to the existing gate UI (winner's output + Continue); else the stepper simply
  advances.

New app work is small: reuse the compare view + add one "Pick" action and one
builder toggle. No new full screen.

**Telemetry** (per CLAUDE.md standing order): breadcrumbs for
fanout-step-defined, runs-spawned, each run phase transition, pick-shown,
pick-tap, pick network start/finish/fail; `Telemetry.capture` ERROR on
all-runs-failed and on pick failure.

---

## 9. Test list

Broker (`broker/internal/pipeline/*_test.go`, `broker/internal/ws/pipeline_test.go`):
- `TestFanoutSpawnsNRuns` — a fanout step spawns `count` sessions with
  `-run-<i>` branches; step-level session_id empty until pick.
- `TestFanoutAllFailedIsFailed` — every run exits(≠0) → `FAILED(k)`.
- `TestFanoutPartialFailureAwaitsPick` — ≥1 run exits(0) → `AWAITING_PICK`.
- `TestPickSetsWinnerAndAdvances` — pick a succeeded run → `step.session_id` =
  winner, spawns k+1 (no gate).
- `TestPickRejectsFailedRun` — picking a non-`exited(0)` run → 409 `run_failed`.
- `TestPickRejectsOutOfRange` — 400.
- `TestPickNotAtPick` — pick when not `awaiting_pick` → 409 `not_at_pick`.
- `TestFanoutGateAfterEntersGateWithWinnerPreview` — pick then gate; GatePreview
  computed from winner's worktree/transcript; Continue reuses `Gate.Prev`.
- `TestCancelKillsAllFanoutRuns` — cancel during FANNING_OUT kills every live
  run session.
- `TestCreateValidatesFanoutConfig` — count bounds, agent_types length mismatch,
  unknown agent → 400.
- `TestCapabilitiesPipelineFanout` — `features.pipeline_fanout == true`.
- Reuse existing `fanout.go`/`DiffSummary` tests unchanged for the pick preview.

App: unit tests decoding a `pipeline.json` with a `fanout` step (runs + winner);
builder serialization round-trip. (iOS/Android are CI-compile-only — flag the
pick/monitor UI **needs on-device verification**.)

---

## 10. Concrete example

Task: "Add a rate limiter to the WS broker."

**Step 0 — architect (claude, gate_after=true):** designs it, gate, user
approves on phone. (Unchanged sequential behavior.)

**Step 1 — engineer, FANOUT count=3 [claude, codex, opencode],
memory+output, gate_after=false:**
Broker builds `{{prev}}` once (from the approved design) and spawns 3 sessions
with the identical prompt on branches `…-step-1-run-0/1/2`. All three implement
in parallel. Run 1 (codex) exits(2). Runs 0 and 2 exit(0).
→ `AWAITING_PICK(1)`. Push fires. On the phone the user opens the pick screen:
the app calls `/api/fanout/compare` and shows the shipped compare view —
`claude: 6 files ·+140 −22`, `codex: (greyed, error)`, `opencode: 4 files
·+90 −10` with summaries. User taps **Pick** on the claude run →
`POST /api/pipeline/p_ab12/pick {"run":0}`.
→ `step.session_id` = run 0; no gate → step 2 (or COMPLETE) spawns from run 0's
HANDOFF-OUT + output.

---

## 11. Non-goals (v2 / do not build now)

- **Auto-pick / auto-ranking** — no policy picks a winner without a human. The
  differentiator is the phone pick; a fabricated ranking is explicitly barred.
- **Loser cleanup on pick** — losers' worktrees are kept; an explicit,
  confirm-gated discard (`DELETE /api/session/{loserID}` reuse) is deferred.
- **Nested fanout** — a fanout step's runs are always plain single-agent
  sessions; no fanout-inside-fanout.
- **Multi-box fan-out** — all runs are local dirs on this broker (same
  constraint as PLAN-FANOUT-COMPARE "same-box only").
- **Per-run distinct prompts** — the prompt is identical across runs; the only
  variation is the agent. Per-run template variants are not a v1 feature.
- **Combined pick+continue** — pick and gate stay distinct broker states.
