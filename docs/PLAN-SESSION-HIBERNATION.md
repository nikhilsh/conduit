# PLAN — Session hibernation (broker-only)

Status: design. Auto-pause idle resumable agent sessions to reclaim RAM. The box
has 3.8 GB and OOMs; a memwatch watchdog currently KILLS runaways
(agent-memwatch, memory note). Hibernation prevents idle waste BEFORE it becomes
a runaway — a graceful pause that transparently resumes.

---

## 0. Key insight — hibernation IS a graceful, pre-emptive `Close()`

`Session.Close()` (`manager.go:1498`) already does exactly what hibernation
needs on the way down, and `recoverSessionLocked` (`recovery.go:30`) already
does exactly what it needs on the way back up. Concretely, Close():

- checkpoints (`s.Checkpoint("exit")`), so scrollback + memory HTML survive;
- **preserves the agent-home conversation/rollout files** — the comment at
  `manager.go:1565-1577` is explicit that `.claude/projects` + `.codex/sessions`
  are deliberately kept so `--resume` works after a restart;
- cancels the pending genuine-stop push timer (`cancelPendingTurnEndPush`,
  `manager.go:1507`) — so **no "session ended" push/LA fires** (the LA "end"
  event is emitted ONLY by `notifyLATurnEnd` from the genuine-stop timer,
  `push_notify.go:591`; Close never calls it);
- kills the agent process (the 1–2.5 GB consumer) and closes `s.closed`, so the
  `<-s.Done()` goroutine (`recovery.go:224`, and the create path) removes the
  session from `m.sessions` — reclaiming the process AND the Go session's
  goroutines.

A broker restart already relies on this: sessions survive as on-disk
`meta.json` + `scrollback.bin` + memory HTML, and `GetOrCreateWithOptions`
(`manager.go:2430`) lazily calls `recoverSessionLocked` on the next
`/ws/<id>` open, respawning the agent with the SAME resume flags
(`resumeChatSessionID` / `resumeCodexThreadID` / opencode store).

**Design: hibernation = a graceful `Close()` triggered by an idle sweep, plus a
persisted `hibernated` marker so the paused session surfaces distinctly instead
of looking dead.** Wake reuses the existing lazy-recovery path unchanged. This
is the minimum design that holds and reuses two battle-tested paths verbatim.

### Tradeoff surfaced (do not hide)

The task says "KEEP the session listed" and "surfaced in the session list". A
hibernated session leaves the in-memory `LiveSessions()` set and reappears in
the `recoverable` set of `GET /api/sessions` (`api.go:449`,
`recoverable_list.go`), tagged `phase:"hibernated"` + `hibernated:true`. It IS
still in the session list the app renders (the response carries both arrays),
just in the recoverable half. The alternative — keeping the `*Session` shell in
`m.sessions` with the process torn down — needs a bespoke partial-teardown, a
watchdog carve-out (`runWatchdogChecks` would flag `!processAlive` as dead,
`watchdog.go:36`), suppression of the `Done()`→map-delete goroutine, and a new
in-place respawn duplicating `newSession`'s backend spawn. That is more code and
more invariants for a marginal "stays in the live array" cosmetic. We choose the
recoverable-set path and make the app render it as "Paused".

---

## 1. Eligibility (ALL required)

Checked per live session on each sweep tick (`s.hibernationEligible(window,
now)`):

1. **Backend supports resume** — `s.chat != nil` AND
   `s.chat.Capabilities().Resume == true`. claude stream-json, codex
   app-server, codex-exec, opencode, ACP all set `Resume:true`
   (`backend_*.go`). The legacy TUI-scrape path (`s.scraper`, no `s.chat`) and
   `shell` do NOT → never hibernated.
2. **Idle** — `now.Sub(s.lastOutput) >= window` (default 30 min). `lastOutput`
   is the watchdog's activity clock (`watchdog.go:42`).
3. **No turn in flight** — `active, _ := s.structuredTurnActive(); !active`
   (`manager.go:1163`).
4. **Not blocked on input** — `s.pendingApproval == nil` AND `s.pendingAsk ==
   nil` (a hibernation must not drop a pending AskUserQuestion / approval).
5. **No attached WS client** — `s.SubscriberCount() == 0` (`manager.go:951`;
   the same presence signal the push gate uses, `push_notify.go:354`).
6. **Not pipeline/flow-managed** — `!s.pipelineManaged` (new flag, §3.1). A
   pipeline drives its step sessions programmatically; pausing one mid-run
   would stall the orchestrator.
7. **Process actually alive + live phase** — `s.processAlive()` &&
   `isLivePhase(s.phase)` (guards against racing an already-dying session).

---

## 2. State machine (manager.go terms)

New phase value: **`hibernated`** (NOT in `isLivePhase`'s allow-list
`watchdog.go:120`, so it reads as non-live → app opens read-only + shows the
Paused affordance; recovery normalizes it back to `running` at
`recovery.go:172`).

Transition **live → hibernated** (`Manager.hibernateSession(s)`):
1. Log `session %s: hibernating (idle %s, no viewers)`.
2. Set `s.pushState`/LA to a benign state is unnecessary — Close cancels the
   stop-push timer; assert no LA "end" is emitted.
3. `s.Close()` — graceful teardown (checkpoint, preserve conversation, kill
   agent). `Done()` goroutine removes `s` from `m.sessions`.
4. **Patch `meta.json`** (dedicated `m.markHibernatedOnDisk(id, now)`): read
   `sessions/<id>/meta.json`, set `Phase:"hibernated"`, `Hibernated:true`,
   `HibernatedAt:<RFC3339Nano>`, `ReasonCode:"hibernated"`, write atomically.
   (Do NOT route through `persistMetadata` — it rebuilds meta from the live
   session's in-memory `phase:"exited"`.)

Transition **hibernated → live** (wake) reuses existing paths — NO new spawn
code:
- **WS attach** (`/ws/<id>`) → `GetOrCreateWithOptions` → `sessionOnDisk` true
  → `recoverSessionLocked` respawns with resume flags. Phase normalized to
  `running` (`recovery.go:172`), and the next `persistMetadata` writes
  `Hibernated:false` (omitempty drops it). First user message rides the normal
  reconnect + **durable send** (client_msg_id dedup) AFTER the WS attaches, so
  it is never lost.
- **Inbound chat / peer send** — see §3.2 (peer path needs a one-line wake
  hook; the durable HTTP/WS send path already recovers).

Persisted-flag lifecycle invariant: `Hibernated:true` is written ONLY by
`markHibernatedOnDisk` and cleared implicitly on the first live-session
`persistMetadata` after recovery. `recoverabilityError` (`recoverable_list.go:96`)
already passes for a hibernated session (scrollback + memory present), so it
correctly appears in `RecoverableSessions()`.

---

## 3. Sweep + wake wiring

### 3.1 Sweep loop (mirror `startGCLoop`, `gc.go:115`)

```go
// manager.go NewManager, after m.startGCLoop(m.stopGC):
m.startHibernateLoop(m.stopGC)
```

```go
func (m *Manager) startHibernateLoop(stop <-chan struct{}) {
    if strings.TrimSpace(lookupEnvCompat("CONDUIT_HIBERNATE_DISABLED")) != "" {
        return // kill-switch
    }
    minutes := envIntDefault("CONDUIT_HIBERNATE_MINUTES", 30)
    if minutes <= 0 { return }
    window := time.Duration(minutes) * time.Minute
    every := time.Duration(envIntDefault("CONDUIT_HIBERNATE_SWEEP_SECONDS", 60)) * time.Second
    go func() {
        t := time.NewTicker(every); defer t.Stop()
        for {
            select {
            case <-t.C: m.sweepHibernation(window, time.Now())
            case <-stop: return
            }
        }
    }()
}
```

`sweepHibernation` snapshots `m.sessions` under `RLock` (never hold `m.mu`
across `Close()`), then for each `s.hibernationEligible(window, now)` calls
`m.hibernateSession(s)` OUTSIDE the lock.

Pipeline exclusion: add `PipelineManaged bool` to `session.CreateOptions`, set
`s.pipelineManaged` in `newSession`, and have `pipelineSessionManager.CreateSession`
(`ws/pipeline.go:38`) pass `PipelineManaged:true`.

### 3.2 Peer-send wake (`ws/api.go serveSessionMessage`, `api.go:1145`)

Today: `sess, ok := s.Sessions.Get(req.SessionID)` → 404 when not live.
Change: on miss, if the id is a hibernated-recoverable session, wake it:

```go
sess, ok := s.Sessions.Get(req.SessionID)
if !ok {
    if s.Sessions.IsHibernated(req.SessionID) {   // new: meta.Hibernated on disk
        sess, _, err = s.Sessions.GetOrCreateWithOptions(req.SessionID, "", session.CreateOptions{})
        // err → 404 as today
    }
}
```

`IsHibernated(id)` reads `sessions/<id>/meta.json` and reports `meta.Hibernated`.
(Peer messaging still must not wake a merely-recoverable/dead session — only an
intentionally-hibernated one.) The empty-assistant `GetOrCreateWithOptions` is
fine: recovery reads the assistant from meta, ignoring the arg.

---

## 4. Interactions to get right

- **Push / Live Activities** — assert NO "session ended". Close cancels the
  genuine-stop timer and never calls `notifyLATurnEnd`; add a test that
  hibernate emits zero LA "end" events. The push gate already suppresses when a
  turn isn't ending.
- **Peer-session messaging** — §3.2 wakes on peer send.
- **Transcript replay on reattach (#700)** — unchanged: recovery repopulates
  the live session and the existing reattach replay (conversation.jsonl tail)
  fires as normal, because wake goes through the standard recovery + attach.
- **meta.json usage display** — usage totals + context gauge are persisted in
  meta (`manager.go:2770`) and restored on recovery (`recovery.go:185`), so the
  Session Info usage card survives hibernation unchanged.
- **GC / delete** — `RunGC` prunes by age; a hibernated session's dir keeps its
  original `StartedAt`/`LastActivityAt`, so GC treats it identically to any
  cold session (correct: a session idle past the GC age SHOULD be collectable).
  `DeleteSession` (`delete.go:34`) archives the dir regardless of hibernation.
  No change needed.

---

## 5. Wire contract additions

Only the session-list shape gains fields (no new endpoints).

`LiveSessionInfo` (`manager.go:2226`) — new field, emitted on the `recoverable`
entries built in `recoverable_list.go:54`:

```go
Hibernated bool `json:"hibernated,omitempty"`
```

`sessionMetadata` (`manager.go:2727`) — new persisted fields:

```go
Hibernated   bool   `json:"hibernated,omitempty"`
HibernatedAt string `json:"hibernated_at,omitempty"`
```

`GET /api/sessions` recoverable entry for a hibernated session:

```json
{
  "id": "…", "assistant": "claude",
  "phase": "hibernated", "health": "healthy",
  "running": false, "recoverable": true, "hibernated": true,
  "title": "…", "cwd": "…",
  "started_at": "…", "last_activity_at": "…"
}
```

Capability flag: **`features.hibernation`** (bool, nested under `features`, same
placement rules as PLAN-REVIEW-SHIP §4 — nested-only, no root mirror). Lets the
app label the state confidently; absent flag → app falls back to generic
"recoverable/resume" rendering (still correct, just less specific). Broker:
`Features.Hibernation bool \`json:"hibernation"\`` set true in
`serveCapabilities`.

---

## 6. App (v1: status chip only — no settings UI)

- iOS/Android: recognize `hibernated:true` (or `phase == "hibernated"`) on a
  recoverable session row → render a "Paused · will resume" chip
  (`Chip`/glass, tinted from `LocalNeonTheme`/`Palette`, no literals) instead of
  the generic recoverable/"ended" look. Reconciliation MUST keep the row (do
  not drop it as dead): it is recoverable=true. Tapping it opens the session,
  which triggers the WS attach → transparent resume.
- Add `hibernation` to `BoxFeatures` on both platforms (same decoder sites as
  PLAN-REVIEW-SHIP §4) — used only to pick the chip label.
- Breadcrumb `session_resume_from_hibernated` on the attach path.

---

## 7. File-touch map (broker-hibernation)

- `broker/internal/session/manager.go` — `startHibernateLoop`,
  `sweepHibernation`, `hibernateSession`, `markHibernatedOnDisk`,
  `IsHibernated`; `LiveSessionInfo.Hibernated`; `sessionMetadata.Hibernated` +
  `HibernatedAt`; `CreateOptions.PipelineManaged` + `s.pipelineManaged`; call
  `startHibernateLoop` in `NewManager`.
- `broker/internal/session/hibernate.go` — NEW: `hibernationEligible` +
  eligibility helpers (keep the loop body out of manager.go).
- `broker/internal/session/recoverable_list.go` — set
  `Hibernated: meta.Hibernated` on the built `LiveSessionInfo`.
- `broker/internal/ws/pipeline.go` — pass `PipelineManaged:true` in
  `CreateSession`.
- `broker/internal/ws/api.go` — peer-send wake (§3.2);
  `Features.Hibernation = true`.
- Tests: `hibernate_test.go` (eligibility truth table: idle/turn/viewer/
  pending-ask/pipeline/backend-resume permutations), a round-trip test
  (hibernate → meta flagged → RecoverableSessions shows hibernated →
  GetOrCreate recovers → phase running, flag cleared), and an LA-silence
  assertion. `cd broker && gofmt -l . && go vet ./... && go test ./...`.

**iOS / Android:** session-list chip + `BoxFeatures.hibernation` decode +
resume breadcrumb (files per PLAN-REVIEW-SHIP §5 decoder sites).

---

## 8. Config

- `CONDUIT_HIBERNATE_DISABLED=1` — kill-switch (default: hibernation ON).
- `CONDUIT_HIBERNATE_MINUTES` — idle window, default 30.
- `CONDUIT_HIBERNATE_SWEEP_SECONDS` — sweep cadence, default 60.

Default ON at 30 min. Ships live via broker redeploy.

---

## 9. Rollout

- Broker-only change → **redeploy required** (tagging does not deploy the
  broker). Redeploy is a hard gate for this to take effect.
- Wake paths reuse existing recovery, so an app with no hibernation awareness
  still resumes correctly on open — it just shows the generic recoverable label
  instead of "Paused".

---

## 10. Non-goals (v1)

- No in-memory "keep the shell, drop the process" variant (see §0 tradeoff).
- No per-session opt-out UI, no user-configurable window in-app.
- No hibernation of legacy-scrape or `shell` sessions (no clean resume).
- No proactive wake / pre-warming; wake is strictly on attach / inbound / peer.
- No cross-broker migration or swap-to-disk of process memory.
