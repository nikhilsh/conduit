package pipeline

import (
	"os"
	"strconv"
	"sync"
)

// defaultMaxConcurrentAgents is used when CONDUIT_MAX_CONCURRENT_AGENTS is
// unset or invalid (docs/PLAN-HARNESS-BUILDER.md §4.4/§8.2, owner decision:
// RAM protection — each claude/codex process runs 1-1.5GB against a
// ~3.9GB box shared with the live broker; the memwatch kills any agent
// >1500MB/120s. 3 matches the repo's proven ~3-concurrent-agent envelope).
const defaultMaxConcurrentAgents = 3

var (
	concurrencyCapOnce sync.Once
	concurrencyCap     int
)

// MaxConcurrentAgents returns the global cap on concurrent live agent
// processes spawned by pipelines (env CONDUIT_MAX_CONCURRENT_AGENTS,
// default 3). Read once and cached — the env is fixed for the process
// lifetime. Always >= 1 (a cap of 0 would let nothing ever spawn — a
// self-inflicted deadlock — so an invalid/non-positive value falls back to
// the default).
func MaxConcurrentAgents() int {
	concurrencyCapOnce.Do(func() {
		concurrencyCap = defaultMaxConcurrentAgents
		if v := os.Getenv("CONDUIT_MAX_CONCURRENT_AGENTS"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				concurrencyCap = n
			}
		}
	})
	return concurrencyCap
}

// liveAgents is a PROCESS-GLOBAL set of session IDs believed to have a live
// agent process, spawned by ANY pipeline's Orchestrator. It must live above
// any single Orchestrator instance because ws/pipeline.go's
// pipelineOrchestrator() constructs a FRESH *Orchestrator per HTTP request —
// an instance-scoped set would reset every request and never actually cap
// anything.
//
// Keyed by session ID (not a bare counter) so removal is idempotent:
// a session can be marked "no longer live" from TWO independent places —
// (1) a poll loop (pollStep/pollFanoutTick/pollLoopStep) observing the
// underlying process actually exited on its own, and (2) an explicit
// CancelSession reap elsewhere (terminateStepSession, Pick's loser-cancel,
// advanceFanout's all-failed cancel, etc) — and removing an already-removed
// key is a no-op, so calling both in either order/both at all never
// double-decrements. This distinction matters: "turn_complete" (a
// structured-chat turn ending) does NOT mean the process exited — the
// comments throughout orchestrator.go are explicit that the session stays
// alive until an explicit Close/CancelSession — so only an actual
// "exited(*)" phase transition removes a session here from a poll loop.
//
// Only fanout spawns (spawnFanout/pollFanoutTick) CONSULT this set's size
// before spawning — they skip ("queue") a run when the count is already at
// cap, and pollFanoutTick starts a queued run once a reap (or a natural
// exit) frees a slot. Sequential steps and loop-body steps still add/remove
// from the SAME set (for accurate global accounting across concurrently-
// running pipelines/fanouts) but never block or skip on it: by construction
// each of those paths only ever holds one slot at a time (the previous
// step's session is reaped once its handoff has been harvested for the next
// step's prompt) — gating them on the cap too would risk a pipeline
// deadlocking itself (a low CONDUIT_MAX_CONCURRENT_AGENTS could stall a
// purely-sequential pipeline for good, waiting on a slot nothing will ever
// free because the thing that would free it is itself waiting on a slot).
// Only the actual concurrency-risk path — fanout width, 1-6 way — is
// throttled.
var (
	liveAgentsMu  sync.Mutex
	liveAgentsSet = map[string]struct{}{}
)

// incLiveAgents records a newly-spawned pipeline session as live.
func incLiveAgents(sessionID string) {
	if sessionID == "" {
		return
	}
	liveAgentsMu.Lock()
	liveAgentsSet[sessionID] = struct{}{}
	liveAgentsMu.Unlock()
}

// decLiveAgents records a session as no longer live (reaped, or observed to
// have exited on its own). Removing an absent key is a safe no-op — see the
// liveAgentsSet doc comment for why this idempotency matters.
func decLiveAgents(sessionID string) {
	if sessionID == "" {
		return
	}
	liveAgentsMu.Lock()
	delete(liveAgentsSet, sessionID)
	liveAgentsMu.Unlock()
}

// liveAgents returns the current count of live pipeline-spawned sessions.
func liveAgents() int64 {
	liveAgentsMu.Lock()
	defer liveAgentsMu.Unlock()
	return int64(len(liveAgentsSet))
}

// resetLiveAgentsForTest clears the global live-agent set. Package tests
// share this process-global state (Go runs tests within a package
// sequentially by default — none of these tests call t.Parallel) — call
// this at the start of any test that asserts on liveAgents()/the
// concurrency cap so a prior test's leftover state can't leak in.
func resetLiveAgentsForTest() {
	liveAgentsMu.Lock()
	liveAgentsSet = map[string]struct{}{}
	liveAgentsMu.Unlock()
}
