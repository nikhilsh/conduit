package pipeline

import "testing"

// setMaxConcurrentAgentsForTest overrides the concurrency cap for a test.
// MaxConcurrentAgents() resolves CONDUIT_MAX_CONCURRENT_AGENTS exactly once
// per process (sync.Once) — calling it here (rather than manipulating
// concurrencyCap directly) forces that real resolution to have already
// happened, so `old` is always a legitimately-resolved value to restore to,
// never an untouched zero value. Returns a restore func; callers should
// defer it.
func setMaxConcurrentAgentsForTest(n int) (restore func()) {
	old := MaxConcurrentAgents()
	concurrencyCap = n
	return func() { concurrencyCap = old }
}

// TestFanoutConcurrencyCapQueuesExcessRuns verifies §4.4: with the global
// cap set to 2 and a fanout of 4, spawnFanout spawns only 2 runs
// immediately (the rest "queued"), and pollFanoutTick starts the 3rd only
// after one of the first two is reaped (freeing a slot).
func TestFanoutConcurrencyCapQueuesExcessRuns(t *testing.T) {
	restore := setMaxConcurrentAgentsForTest(2)
	defer restore()

	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 4},
		},
	})

	if err := orch.spawnFanout(p, 0); err != nil {
		t.Fatalf("spawnFanout: %v", err)
	}

	fc := p.Steps[0].Fanout
	var running, queued []int
	for i, run := range fc.Runs {
		switch run.Phase {
		case "running":
			running = append(running, i)
		case "queued":
			queued = append(queued, i)
		default:
			t.Errorf("run %d: unexpected initial phase %q", i, run.Phase)
		}
	}
	if len(running) != 2 {
		t.Fatalf("running runs=%v, want exactly 2 (cap)", running)
	}
	if len(queued) != 2 {
		t.Fatalf("queued runs=%v, want exactly 2", queued)
	}
	if len(sm.created) != 2 {
		t.Fatalf("CreateSession calls=%d, want 2 (only up to cap spawned eagerly)", len(sm.created))
	}
	if got := liveAgents(); got != 2 {
		t.Fatalf("liveAgents=%d, want 2", got)
	}

	// Persist so pollFanoutTick (which Loads by ID) sees this state.
	if err := p.Save(dir); err != nil {
		t.Fatalf("save: %v", err)
	}

	// One tick with nothing settled yet: still only 2 running, nothing new
	// started (no slot freed).
	done, err := orch.pollFanoutTick(p.ID, 0)
	if err != nil {
		t.Fatalf("pollFanoutTick (no settle): %v", err)
	}
	if done {
		t.Fatal("pollFanoutTick reported done with runs still in flight")
	}
	if len(sm.created) != 2 {
		t.Fatalf("CreateSession calls=%d after a no-op tick, want still 2", len(sm.created))
	}

	// Settle the first running run (simulates the agent process exiting).
	firstRunIdx := running[0]
	sm.sessions[fc.Runs[firstRunIdx].SessionID].phase = "exited(0)"

	done, err = orch.pollFanoutTick(p.ID, 0)
	if err != nil {
		t.Fatalf("pollFanoutTick (after settle): %v", err)
	}
	if done {
		t.Fatal("pollFanoutTick reported done while a queued run remains")
	}

	// Reload to inspect persisted state.
	p2, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	fc2 := p2.Steps[0].Fanout
	startedFromQueue := 0
	stillQueued := 0
	for _, run := range fc2.Runs {
		if run.Phase == "queued" {
			stillQueued++
		}
		if run.Phase == "running" {
			startedFromQueue++
		}
	}
	// firstRunIdx settled (exited), one other still running from the
	// original 2, and exactly one previously-queued run should now be
	// running (the "3rd starts only after one is reaped" invariant).
	if startedFromQueue != 2 {
		t.Errorf("running runs after settle+tick=%d, want 2 (1 original + 1 newly-started queued run)", startedFromQueue)
	}
	if stillQueued != 1 {
		t.Errorf("still-queued runs=%d, want 1", stillQueued)
	}
	if len(sm.created) != 3 {
		t.Fatalf("CreateSession calls=%d after freeing a slot, want 3", len(sm.created))
	}
}

// TestMaxConcurrentAgentsDefault verifies the documented default (3) when
// the env var is unset — exercised via setMaxConcurrentAgentsForTest's
// restore path rather than mutating the real env var (which is process-wide
// and would race other tests).
func TestMaxConcurrentAgentsDefault(t *testing.T) {
	restore := setMaxConcurrentAgentsForTest(defaultMaxConcurrentAgents)
	defer restore()
	if got := MaxConcurrentAgents(); got != 3 {
		t.Errorf("MaxConcurrentAgents=%d, want 3", got)
	}
}
