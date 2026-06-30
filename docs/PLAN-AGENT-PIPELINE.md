# PLAN — Sequential Agent Pipeline

Status: design. NEW feature. New broker subsystem + new mobile screens.
Builds on shipped seams: `POST /api/session/start`, `switch_agent`, the frozen
HANDOFF-OUT memory contract (MEMORY-FORMAT.md §4), per-session worktrees, and
PLAN-AGENT-MEMORY-PERSISTENCE (already shipped).

---

## 1. User mental model

"I define a pipeline of steps. Each step is an agent + a prompt template. Steps
run in order. Each step can see what the previous step produced. I can put an
approval **gate** between steps so nothing advances until I tap Continue on my
phone."

---

## 2. Data model + storage

A pipeline is broker-owned state, NOT committed to the user's repo.

```
<conduitRoot>/pipelines/<pipeline-id>/pipeline.json   ← definition + live state
<conduitRoot>/pipelines/<pipeline-id>/steps/<n>/      ← per-step handoff artifacts
```

`pipeline.json` schema:
```json
{
  "id": "p_01H…",
  "title": "Add rate limiter",
  "task": "Add a token-bucket rate limiter to the WS broker.",
  "cwd": "/root/developer/projects/conduit",
  "base": "main",
  "state": "running",
  "current_step": 1,
  "created": "2026-06-30T12:00:00Z",
  "steps": [
    {
      "index": 0,
      "agent_type": "claude",
      "role": "researcher",
      "prompt_template": "Research approaches for: {{task}}. Write findings to memory.",
      "input_from_prev": "none",
      "gate_after": false,
      "session_id": "...",
      "phase": "exited(0)",
      "started": "...",
      "ended": "..."
    },
    {
      "index": 1,
      "agent_type": "claude",
      "role": "architect",
      "prompt_template": "Design the implementation. Prior research:\n{{prev}}",
      "input_from_prev": "memory+output",
      "gate_after": true,
      "session_id": null,
      "phase": null
    },
    {
      "index": 2,
      "agent_type": "codex",
      "role": "engineer",
      "prompt_template": "Implement the approved design:\n{{prev}}",
      "input_from_prev": "memory+output",
      "gate_after": false,
      "session_id": null,
      "phase": null
    }
  ]
}
```

`{{task}}` = pipeline-level task text. `{{prev}}` = handoff payload from step
N-1 (see §7). Templates use literal substitution only — no logic.

---

## 3. Step definition

`agent_type`: any installed agent (`claude`, `codex`, `opencode`, `gemini`).

`role`: display label + prompt-template preset (researcher / architect /
engineer / custom). Preset prefills `prompt_template`; user can edit.

`input_from_prev` ∈ `none | output | memory | memory+output`:
- `output` — previous step's final assistant text (last turn from transcript).
- `memory` — previous step's HANDOFF-OUT `<section data-section="handoff">`
  text (frozen contract, MEMORY-FORMAT.md §4).
- `memory+output` — both, output appended under a `## Previous step output`
  header.
- `none` — first step or intentional break in the chain.

`gate_after`: boolean. When true, pipeline enters `AWAITING_GATE` after this
step exits(0) and does not spawn the next step until `POST …/continue`.

---

## 4. State machine

One child session live at a time (sequential). Parent pipeline object owns
state; child sessions are regular sessions.

```
            create
PENDING ──────────► RUNNING(step k)
                       │  child phase → exited(0)
                       ▼
                   STEP_DONE(k)
              ┌────────┴─────────┐
       gate_after=true     gate_after=false
              │                  │
              ▼                  │
      AWAITING_GATE(k)           │
              │ POST /continue   │
              └────────┬─────────┘
                       ▼
             k+1 < N? ──yes──► RUNNING(step k+1)   [handoff §7]
                       │ no
                       ▼
                    COMPLETE

  child exited(N≠0) ──► FAILED(step k)   pipeline halts, prior artifacts kept
  DELETE             ──► CANCELLED        kills live child session
```

**Error handling**: a step exiting non-zero halts the pipeline at `FAILED(k)`.
Prior steps' worktrees and artifacts are preserved. The app surfaces the failing
step's session for inspection. No auto-retry in v1.

Each child runs in its own worktree on a `pipeline-<id>-step-<k>` branch
(requires Gap A from PLAN-FANOUT-COMPARE §5; absent it, worktrees use
`conduit-session-<id>` branches and steps chain via memory/output text only).

Because all steps share the same `cwd`, PLAN-AGENT-MEMORY-PERSISTENCE's
per-project store is shared across steps naturally — the architect can read the
researcher's project-scope memory directly.

---

## 5. Broker endpoints

```
POST   /api/pipeline               create + start (runs step 0 immediately)
GET    /api/pipeline/{id}          full pipeline.json (poll for live state)
POST   /api/pipeline/{id}/continue advance past AWAITING_GATE; 409 if not at gate
DELETE /api/pipeline/{id}          cancel; kills live child; state → CANCELLED
GET    /api/pipelines              list: [{id, title, state, current_step, step_count}]
```

`POST /api/pipeline` request:
```json
{
  "title": "Add rate limiter",
  "cwd": "/root/developer/projects/conduit",
  "base": "main",
  "task": "Add a token-bucket rate limiter to the WS broker.",
  "steps": [
    { "agent_type": "claude", "role": "researcher",
      "prompt_template": "Research approaches for: {{task}}. Write findings to memory.",
      "input_from_prev": "none", "gate_after": false },
    { "agent_type": "claude", "role": "architect",
      "prompt_template": "Design the implementation. Prior research:\n{{prev}}",
      "input_from_prev": "memory+output", "gate_after": true },
    { "agent_type": "codex", "role": "engineer",
      "prompt_template": "Implement the approved design:\n{{prev}}",
      "input_from_prev": "memory+output", "gate_after": false }
  ]
}
```

Response: `{ "id": "p_...", "state": "running", "current_step": 0 }`.

---

## 6. Human-in-the-loop gates (the mobile differentiator)

`gate_after: true` → after step k exits(0), pipeline state becomes
`AWAITING_GATE(k)`. Step k+1 does NOT spawn until `POST …/continue`.

The app shows:
- Step k's output + the computed `{{prev}}` for step k+1.
- A **Continue** button → `POST /api/pipeline/{id}/continue`.
- (v1.1) An **Edit handoff** field to amend `{{prev}}` before continuing.

Push notification is sent on entering `AWAITING_GATE` so the user is pinged
to come approve. Reuses the existing push subsystem.

---

## 7. Memory handoff mechanism (exact)

When step k's child exits(0):
1. Broker reads `.conduit/HANDOFF-OUT.html` from the child's worktree.
   Extracts `<section data-section="handoff">` text using the existing
   handoff-merge parser.
2. Broker reads the child's final assistant text from its persisted transcript
   (same path as `serveSessionConversation`).
3. Builds `{{prev}}` per step k+1's `input_from_prev`:
   - `memory` → handoff section text
   - `output` → final assistant text
   - `memory+output` → handoff text + `\n\n## Previous step output\n` + output
4. Writes `{{prev}}` to `pipelines/<id>/steps/<k+1>/input.md` (audit + replay).
5. Renders step k+1's `prompt_template` substituting `{{task}}` and `{{prev}}`.
6. Spawns step k+1 via the existing session-start path with that rendered
   string as the initial prompt.

---

## 8. Mobile UX — new screens

**New files:**
- iOS: `apps/ios/Sources/ConduitUI/Views/ConduitPipelineBuilderView.swift`,
  `ConduitPipelineMonitorView.swift`
- Android: `apps/android/app/src/main/kotlin/sh/nikhil/conduit/ui/PipelineBuilderScreen.kt`,
  `PipelineMonitorScreen.kt`

**Builder screen** (create):
- Pipeline title + shared task field (text area).
- Ordered step list. Per step: pick `agent_type` (populated from
  `/api/capabilities`), pick role preset (researcher / architect / engineer),
  edit `prompt_template`, toggle `input_from_prev`, toggle **Gate after**.
- Add / remove / reorder steps (drag handle).
- "Start pipeline" → `POST /api/pipeline` → navigate to Monitor.

**Monitor screen** (live):
- Vertical stepper: each step shows AgentAvatar, role label, and live state
  derived from polling `GET /api/pipeline/{id}`:
  - `queued` (dim) / `running` (cyan pulse) / `done` (green) /
    `failed` (red) / `awaiting-gate` (amber, pulsing).
- The active step is highlighted. Tap any step with a `session_id` to open
  that session's chat (existing navigation).
- `AWAITING_GATE` shows the previous step's output + **Continue** button.
- `FAILED` shows the error text + **Open session** to inspect.
- Header: overall pipeline state + step counter `k / N`. Cancel in toolbar →
  `DELETE /api/pipeline/{id}` with confirm.

**Entry points**: Pipeline tab in the main navigation (alongside Sessions and
History), or a "New pipeline" action in the command palette.

**Telemetry** (per CLAUDE.md standing order):
- Breadcrumbs: builder-open, pipeline-create start/finish/fail, each step
  state transition, gate-shown, gate-continue, monitor poll fail.
- `Telemetry.capture` ERROR on create failure and on `FAILED(step k)`.

---

## 9. Broker changes (file-touch list)

1. **`broker/internal/pipeline/`** (new package): `pipeline.go` (data model,
   state machine, persist/load), `orchestrator.go` (spawn/advance/cancel loop),
   `handoff.go` (build `{{prev}}` from HANDOFF-OUT + transcript).
2. **`broker/internal/ws/pipeline.go`** (new): HTTP handlers for all five
   endpoints; registered in `server.go`.
3. **`broker/internal/ws/server.go`**: route registration.
4. **`broker/internal/session/`**: no changes needed; pipeline uses existing
   `GetOrCreateWithOptions` to spawn child sessions.
5. **`/api/capabilities`**: add `pipeline: true`.

---

## 10. Concrete example

Task: "Add a rate limiter to the WS broker."

**Step 0 — researcher (claude, no input, no gate):**
Prompt: "Research approaches for: Add a rate limiter to the WS broker. Write
findings to memory."
Agent investigates, writes HANDOFF-OUT with handoff section: "token-bucket vs
leaky-bucket; recommend token-bucket per-conn; watch ping/pong timer."
Exits(0). Broker builds `{{prev}}` = handoff text + final output.

**Step 1 — architect (claude, memory+output, gate_after=true):**
Prompt: "Design the implementation. Prior research: <token-bucket
recommendation + rationale>."
Agent produces interface design + files to touch. Exits(0) → AWAITING_GATE.
Push notification fires. User reads design on phone, taps **Continue**.

**Step 2 — engineer (codex, memory+output, no gate):**
Prompt: "Implement the approved design: <design + prior research>."
Agent writes the code in its worktree. Exits(0) → COMPLETE.
User opens step 2's session, views the diff in DiffReview, taps
"Commit & PR" to land it (reuses PLAN-FANOUT-COMPARE §3 / existing DiffReview).

---

## 11. Invariants

- **Sequential single-live-child**: at most one PTY in flight per pipeline —
  no concurrent credential contention; memory store sharing is safe.
- **Gate is hard**: step k+1 NEVER spawns while `AWAITING_GATE(k)` — human
  approval is load-bearing, not advisory.
- **Handoff uses the frozen contract**: `{{prev}}` is built from the existing
  HANDOFF-OUT `<section data-section="handoff">` + transcript — no new format.
- **Broker-owned state**: pipelines live under `<conduitRoot>/pipelines/`,
  never in the user's repo.
- **Error is transparent**: `FAILED` state preserves all prior step artifacts
  and surfaces the failing session for inspection.

---

## 12. v2 notes (do not build now)

- A pipeline step with `agent_type: "fanout"` — parallel sub-runs as a single
  step, best-of result fed into `{{prev}}`. Composable with PLAN-FANOUT-COMPARE.
- Resume a failed pipeline from step k (re-spawn step k with amended prompt).
- Pipeline templates: save a step sequence as a reusable preset.
