package session

// Tests for the codex multi-agent / sub-agent panel integration.
//
// Coverage:
//   (a) CollabAgentToolCall spawnAgent item/completed registers a sub-agent
//       roster node and emits view_event(agents).
//   (b) Sub-agent thread notifications (thread/tokenUsage/updated,
//       turn/completed) update the roster without touching the parent turn.
//   (c) Sub-agent agentMessage items do NOT produce main-chat view_events.
//   (d) A sub-agent turn/completed does NOT prematurely end the parent turn.
//   (e) Single-agent (no sub-agents) behavior is unchanged.
//
// Tests drive handleNotification directly (no real codex binary) using the
// wire frames captured in /root/.claude/jobs/31684efa/tmp/ (inline as test
// literals here so the tests are hermetic).

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

// newTestSubagentHandle builds a subagentRegistryHandle backed by a fresh
// registry + the provided publish sink, using its own mutex (not Session.mu).
func newTestSubagentHandle(publish func([]byte)) *subagentRegistryHandle {
	mu := &sync.Mutex{}
	return &subagentRegistryHandle{
		mu:        mu,
		reg:       newSubagentRegistry(),
		publish:   publish,
		sessionID: "test",
	}
}

// makeTestProcess builds a minimal codexAppServerProcess with a live
// subagentHandle but without a real codex subprocess. Used for pure
// notification-dispatch tests. The threadID must be set so the filter logic
// knows the parent thread.
func makeTestProcess(parentThreadID string, publish func([]byte), subH *subagentRegistryHandle) *codexAppServerProcess {
	return &codexAppServerProcess{
		threadID:       parentThreadID,
		publish:        publish,
		subagentH:      subH,
		subThreads:     make(map[string]bool),
		spawnPending:   make(map[string]string),
		subagentTokens: make(map[string]uint64),
		silenceTimeout: codexTurnSilenceTimeout,
	}
}

// mustJSON marshals v, panicking on error (test helper).
func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// -- wire frame literals from the live capture --

const (
	parentThread = "019eb533-e35d-7550-a025-897bcc597ce5"
	subThreadA   = "019eb533-f56a-7f33-84a9-f39a8868582f"
	subThreadB   = "019eb533-fed4-7870-91d9-31b90fda1334"
	spawnCallA   = "call_X4JLzWLSoUzayqsjlqMZc9yV"
	spawnCallB   = "call_dyE8Wt8bLGFMYM9aw3To3gSO"
	promptAlpha  = "You are sub-agent ALPHA. Research task: describe what the Rust borrow checker does. Keep it concise but technically accurate. Return only your answer; do not mention collaboration mechanics."
	promptBeta   = "You are sub-agent BETA. Research task: describe what a Kalman filter is. Keep it concise but technically accurate. Return only your answer; do not mention collaboration mechanics."
)

// collabStartedParams builds an item/started params for a spawnAgent call
// (receiverThreadIds is empty on started, as in the live capture).
func collabStartedParams(callID, prompt string) json.RawMessage {
	return mustJSON(map[string]any{
		"item": map[string]any{
			"type":              "collabAgentToolCall",
			"id":                callID,
			"tool":              "spawnAgent",
			"status":            "inProgress",
			"senderThreadId":    parentThread,
			"receiverThreadIds": []string{},
			"prompt":            prompt,
			"model":             "",
			"reasoningEffort":   "low",
			"agentsStates":      map[string]any{},
		},
		"threadId": parentThread,
		"turnId":   "turn-1",
	})
}

// collabCompletedParams builds an item/completed params for a spawnAgent call
// (receiverThreadIds is populated on completed, as in the live capture).
func collabCompletedParams(callID, subThreadID, prompt string) json.RawMessage {
	return mustJSON(map[string]any{
		"item": map[string]any{
			"type":              "collabAgentToolCall",
			"id":                callID,
			"tool":              "spawnAgent",
			"status":            "completed",
			"senderThreadId":    parentThread,
			"receiverThreadIds": []string{subThreadID},
			"prompt":            prompt,
			"model":             "gpt-5.5",
			"reasoningEffort":   "low",
			"agentsStates": map[string]any{
				subThreadID: map[string]any{"status": "pendingInit", "message": nil},
			},
		},
		"threadId": parentThread,
		"turnId":   "turn-1",
	})
}

// subAgentTokenUsageParams builds a thread/tokenUsage/updated params for a
// sub-agent thread (matches the live capture shape).
func subAgentTokenUsageParams(subThreadID string, totalTokens uint64) json.RawMessage {
	return mustJSON(map[string]any{
		"threadId": subThreadID,
		"turnId":   "sub-turn-1",
		"tokenUsage": map[string]any{
			"total": map[string]any{
				"totalTokens": totalTokens,
			},
			"last": map[string]any{
				"totalTokens": totalTokens,
			},
			"modelContextWindow": 258400,
		},
	})
}

// subAgentTurnCompletedParams builds a turn/completed params for a sub-agent
// thread (matches the live capture shape).
func subAgentTurnCompletedParams(subThreadID string, durationMs uint64) json.RawMessage {
	return mustJSON(map[string]any{
		"threadId": subThreadID,
		"turn": map[string]any{
			"id":          "sub-turn-1",
			"status":      "completed",
			"durationMs":  durationMs,
			"startedAt":   1781156541,
			"completedAt": 1781156550,
		},
	})
}

// subAgentAgentMessageParams builds an item/completed params for an
// agentMessage on a sub-agent thread — this MUST NOT leak to the parent chat.
func subAgentAgentMessageParams(subThreadID, text string) json.RawMessage {
	return mustJSON(map[string]any{
		"item": map[string]any{
			"type": "agentMessage",
			"id":   "msg-sub-1",
			"text": text,
		},
		"threadId": subThreadID,
		"turnId":   "sub-turn-1",
	})
}

// parentTurnCompletedParams builds a turn/completed for the PARENT thread.
func parentTurnCompletedParams(status string) json.RawMessage {
	return mustJSON(map[string]any{
		"threadId": parentThread,
		"turn": map[string]any{
			"id":     "turn-1",
			"status": status,
		},
	})
}

// TestCodexSubagentRosterRegistration verifies that:
//   - item/started for spawnAgent stashes the prompt in spawnPending
//   - item/completed for spawnAgent registers the sub-agent thread and emits
//     a view_event(agents) with the correct roster node.
func TestCodexSubagentRosterRegistration(t *testing.T) {
	var published [][]byte
	h := newTestSubagentHandle(func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		published = append(published, cp)
	})
	proc := makeTestProcess(parentThread, func([]byte) {}, h)
	proc.turnActive = true

	// item/started for spawnAgent on parent thread.
	proc.handleNotification("item/started", collabStartedParams(spawnCallA, promptAlpha))

	proc.mu.Lock()
	pendingPrompt, hasPending := proc.spawnPending[spawnCallA]
	proc.mu.Unlock()
	if !hasPending {
		t.Fatal("spawnPending should contain the call id after item/started")
	}
	if pendingPrompt != promptAlpha {
		t.Errorf("spawnPending prompt mismatch: got %q want %q", pendingPrompt, promptAlpha)
	}
	if len(published) != 0 {
		t.Errorf("no view_event should be published on item/started alone; got %d", len(published))
	}

	// item/completed for spawnAgent on parent thread — triggers registration.
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallA, subThreadA, promptAlpha))

	// spawnPending entry should be consumed.
	proc.mu.Lock()
	_, stillPending := proc.spawnPending[spawnCallA]
	isRegistered := proc.subThreads[subThreadA]
	proc.mu.Unlock()
	if stillPending {
		t.Error("spawnPending entry should be consumed after item/completed")
	}
	if !isRegistered {
		t.Error("subThreads should contain the new sub-agent's threadId")
	}

	// Exactly one view_event should have been published.
	if len(published) != 1 {
		t.Fatalf("expected 1 view_event after spawn completed, got %d", len(published))
	}

	// Decode and validate the roster snapshot.
	var frame struct {
		Type  string `json:"type"`
		View  string `json:"view"`
		Event struct {
			Agents []map[string]json.RawMessage `json:"agents"`
		} `json:"event"`
	}
	if err := json.Unmarshal(published[0], &frame); err != nil {
		t.Fatalf("unmarshal frame: %v", err)
	}
	if frame.Type != "view_event" {
		t.Errorf("type=%q want view_event", frame.Type)
	}
	if frame.View != "agents" {
		t.Errorf("view=%q want agents", frame.View)
	}
	if len(frame.Event.Agents) != 1 {
		t.Fatalf("expected 1 agent in roster, got %d", len(frame.Event.Agents))
	}
	a := frame.Event.Agents[0]

	// task_id must equal the sub-agent threadId.
	var taskID string
	if err := json.Unmarshal(a["task_id"], &taskID); err != nil || taskID != subThreadA {
		t.Errorf("task_id=%q want %q", taskID, subThreadA)
	}

	// status must be "working" (just spawned).
	var status string
	if err := json.Unmarshal(a["status"], &status); err != nil || status != "working" {
		t.Errorf("status=%q want working", status)
	}

	// name should be derived from the prompt (first line, capped at 40 chars).
	var name string
	if err := json.Unmarshal(a["name"], &name); err != nil {
		t.Errorf("name: %v", err)
	}
	if name == "" {
		t.Error("name should not be empty")
	}
	// The first line of promptAlpha is the whole thing; verify capped name.
	if len(name) > 40 {
		t.Errorf("name too long (%d chars > 40): %q", len(name), name)
	}

	// description should be the full prompt.
	var desc string
	if err := json.Unmarshal(a["description"], &desc); err != nil {
		t.Errorf("description: %v", err)
	}
	if desc != promptAlpha {
		t.Errorf("description mismatch: got %q want %q", desc, promptAlpha)
	}
}

// TestCodexSubagentTokensUpdate verifies that a thread/tokenUsage/updated
// notification on a known sub-agent thread updates the roster (not the parent
// turn's usage).
func TestCodexSubagentTokensUpdate(t *testing.T) {
	var published [][]byte
	h := newTestSubagentHandle(func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		published = append(published, cp)
	})
	proc := makeTestProcess(parentThread, func([]byte) {}, h)
	proc.turnActive = true

	// Register the sub-agent thread first.
	proc.handleNotification("item/started", collabStartedParams(spawnCallA, promptAlpha))
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallA, subThreadA, promptAlpha))
	published = published[:0] // drain the spawn event

	// Send a token-usage update on the sub-agent thread.
	proc.handleNotification("thread/tokenUsage/updated", subAgentTokenUsageParams(subThreadA, 15585))

	if len(published) != 1 {
		t.Fatalf("expected 1 view_event after token update, got %d", len(published))
	}
	var frame struct {
		Event struct {
			Agents []map[string]json.RawMessage `json:"agents"`
		} `json:"event"`
	}
	if err := json.Unmarshal(published[0], &frame); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(frame.Event.Agents) != 1 {
		t.Fatalf("expected 1 agent, got %d", len(frame.Event.Agents))
	}
	var toks uint64
	if err := json.Unmarshal(frame.Event.Agents[0]["tokens"], &toks); err != nil || toks == 0 {
		t.Errorf("tokens should be non-zero after token update, got %v", toks)
	}
}

// TestCodexSubagentTurnCompleted verifies that a turn/completed on a sub-agent
// thread updates the roster to "done" with the duration_ms, but does NOT end
// the parent turn (turnActive remains true).
func TestCodexSubagentTurnCompleted(t *testing.T) {
	var published [][]byte
	h := newTestSubagentHandle(func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		published = append(published, cp)
	})
	proc := makeTestProcess(parentThread, func([]byte) {}, h)
	proc.turnActive = true

	// Register sub-agent + send token update.
	proc.handleNotification("item/started", collabStartedParams(spawnCallA, promptAlpha))
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallA, subThreadA, promptAlpha))
	proc.handleNotification("thread/tokenUsage/updated", subAgentTokenUsageParams(subThreadA, 15585))
	published = published[:0] // drain

	// Sub-agent turn/completed.
	proc.handleNotification("turn/completed", subAgentTurnCompletedParams(subThreadA, 8375))

	// Parent turn must still be active — sub-agent turn/completed must NOT
	// trigger endTurn on the parent.
	proc.mu.Lock()
	stillActive := proc.turnActive
	proc.mu.Unlock()
	if !stillActive {
		t.Error("parent turnActive must remain true after sub-agent turn/completed")
	}

	// One roster update should be published.
	if len(published) != 1 {
		t.Fatalf("expected 1 view_event after sub-agent turn/completed, got %d", len(published))
	}
	var frame struct {
		Event struct {
			Agents []map[string]json.RawMessage `json:"agents"`
		} `json:"event"`
	}
	if err := json.Unmarshal(published[0], &frame); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(frame.Event.Agents) != 1 {
		t.Fatalf("expected 1 agent, got %d", len(frame.Event.Agents))
	}
	a := frame.Event.Agents[0]

	var status string
	if err := json.Unmarshal(a["status"], &status); err != nil || status != "done" {
		t.Errorf("status=%q want done after sub-agent turn/completed", status)
	}

	var durMS uint64
	if err := json.Unmarshal(a["duration_ms"], &durMS); err != nil || durMS != 8375 {
		t.Errorf("duration_ms=%d want 8375", durMS)
	}

	var endedAt string
	if err := json.Unmarshal(a["ended_at"], &endedAt); err != nil || endedAt == "" {
		t.Errorf("ended_at should be set, got %q", endedAt)
	}
}

// TestCodexSubagentAgentMessageNotLeakedToChat verifies that an agentMessage
// item/completed on a sub-agent thread does NOT produce a main-chat view_event.
func TestCodexSubagentAgentMessageNotLeakedToChat(t *testing.T) {
	var chatEvents [][]byte
	// The publish function is the parent-chat publisher; we track what it receives.
	proc := makeTestProcess(parentThread, func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		chatEvents = append(chatEvents, cp)
	}, nil) // nil subagentH: no roster to verify here

	// Manually register the sub-agent thread (bypass the normal spawn path).
	proc.mu.Lock()
	proc.subThreads[subThreadA] = true
	proc.mu.Unlock()

	// A sub-agent agentMessage — must be silently ignored.
	proc.handleNotification("item/completed", subAgentAgentMessageParams(subThreadA, "The Rust borrow checker enforces..."))
	proc.handleNotification("item/agentMessage/delta", mustJSON(map[string]any{
		"threadId": subThreadA,
		"turnId":   "sub-turn-1",
		"delta":    "The Rust borrow checker",
	}))

	if len(chatEvents) != 0 {
		t.Errorf("sub-agent messages must not produce parent chat events; got %d events", len(chatEvents))
		for i, ev := range chatEvents {
			t.Logf("  event[%d]: %s", i, string(ev))
		}
	}
}

// TestCodexSubagentParentTurnCompletedStillWorks verifies that the parent
// thread's own turn/completed is still handled correctly (endTurn fires)
// after sub-agent spawning.
func TestCodexSubagentParentTurnCompletedStillWorks(t *testing.T) {
	turnEnded := make(chan struct{}, 1)
	chatEvents := make(chan []byte, 16)

	h := newTestSubagentHandle(func([]byte) {})
	proc := makeTestProcess(parentThread, func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		chatEvents <- cp
	}, h)

	// Wire a turn-idle hook to detect endTurn.
	proc.onTurnIdle = func() { turnEnded <- struct{}{} }
	proc.turnActive = true

	// Spawn a sub-agent.
	proc.handleNotification("item/started", collabStartedParams(spawnCallA, promptAlpha))
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallA, subThreadA, promptAlpha))

	// Parent turn/completed (status=completed).
	proc.handleNotification("turn/completed", parentTurnCompletedParams("completed"))

	select {
	case <-turnEnded:
		// expected
	case <-time.After(500 * time.Millisecond):
		t.Fatal("parent turn/completed did not fire onTurnIdle")
	}

	proc.mu.Lock()
	stillActive := proc.turnActive
	proc.mu.Unlock()
	if stillActive {
		t.Error("parent turnActive should be false after parent turn/completed")
	}
}

// TestCodexSubagentSingleAgentBehaviorUnchanged verifies that single-agent
// turns (no sub-agents) work exactly as before: parent agentMessage → chat
// event, parent turn/completed → endTurn.
func TestCodexSubagentSingleAgentBehaviorUnchanged(t *testing.T) {
	var chatEvents [][]byte
	turnEnded := make(chan struct{}, 1)

	proc := makeTestProcess(parentThread, func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		chatEvents = append(chatEvents, cp)
	}, nil)
	proc.onTurnIdle = func() { turnEnded <- struct{}{} }
	proc.turnActive = true

	// A normal agentMessage on the parent thread.
	parentMsg := mustJSON(map[string]any{
		"item": map[string]any{
			"type": "agentMessage",
			"id":   "msg-1",
			"text": "Hello from the agent.",
		},
		"threadId": parentThread,
		"turnId":   "turn-1",
	})
	proc.handleNotification("item/completed", parentMsg)

	if len(chatEvents) != 1 {
		t.Fatalf("expected 1 chat event for parent agentMessage, got %d", len(chatEvents))
	}
	var frame struct {
		Type  string `json:"type"`
		View  string `json:"view"`
		Event struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"event"`
	}
	if err := json.Unmarshal(chatEvents[0], &frame); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if frame.View != "chat" {
		t.Errorf("view=%q want chat", frame.View)
	}
	if frame.Event.Role != "assistant" {
		t.Errorf("role=%q want assistant", frame.Event.Role)
	}
	if !strings.Contains(frame.Event.Content, "Hello from the agent") {
		t.Errorf("content should contain the agent message, got %q", frame.Event.Content)
	}

	// Parent turn/completed → endTurn fires.
	proc.handleNotification("turn/completed", parentTurnCompletedParams("completed"))
	select {
	case <-turnEnded:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("parent turn/completed did not fire onTurnIdle")
	}
}

// TestCodexSubagentTwoAgentsFullLifecycle drives the full 2-subagent scenario
// from the live capture frames: two parallel spawnAgents, token updates for
// both, then both turn/completeds — verifies the final roster has 2 "done"
// entries.
func TestCodexSubagentTwoAgentsFullLifecycle(t *testing.T) {
	var published [][]byte
	h := newTestSubagentHandle(func(p []byte) {
		cp := make([]byte, len(p))
		copy(cp, p)
		published = append(published, cp)
	})
	proc := makeTestProcess(parentThread, func([]byte) {}, h)
	proc.turnActive = true

	// Spawn sub-agent ALPHA.
	proc.handleNotification("item/started", collabStartedParams(spawnCallA, promptAlpha))
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallA, subThreadA, promptAlpha))

	// Spawn sub-agent BETA.
	proc.handleNotification("item/started", collabStartedParams(spawnCallB, promptBeta))
	proc.handleNotification("item/completed", collabCompletedParams(spawnCallB, subThreadB, promptBeta))

	// Token updates for both.
	proc.handleNotification("thread/tokenUsage/updated", subAgentTokenUsageParams(subThreadA, 15585))
	proc.handleNotification("thread/tokenUsage/updated", subAgentTokenUsageParams(subThreadB, 15538))

	// Both sub-agents complete.
	proc.handleNotification("turn/completed", subAgentTurnCompletedParams(subThreadA, 8375))
	proc.handleNotification("turn/completed", subAgentTurnCompletedParams(subThreadB, 7120))

	// Parent turn still active.
	proc.mu.Lock()
	stillActive := proc.turnActive
	proc.mu.Unlock()
	if !stillActive {
		t.Error("parent turn must still be active after sub-agent completions")
	}

	// The last snapshot should have 2 agents both "done".
	if len(published) == 0 {
		t.Fatal("no view_events published")
	}
	lastPublished := published[len(published)-1]
	var frame struct {
		Event struct {
			Agents []map[string]json.RawMessage `json:"agents"`
		} `json:"event"`
	}
	if err := json.Unmarshal(lastPublished, &frame); err != nil {
		t.Fatalf("unmarshal last frame: %v", err)
	}
	if len(frame.Event.Agents) != 2 {
		t.Fatalf("expected 2 agents in final roster, got %d", len(frame.Event.Agents))
	}
	for i, a := range frame.Event.Agents {
		var status string
		if err := json.Unmarshal(a["status"], &status); err != nil || status != "done" {
			t.Errorf("agent[%d]: status=%q want done", i, status)
		}
		var endedAt string
		if err := json.Unmarshal(a["ended_at"], &endedAt); err != nil || endedAt == "" {
			t.Errorf("agent[%d]: ended_at should be set", i)
		}
	}
}

// TestCodexCollabWireHelpers tests the pure wire helper functions that parse
// collabAgentToolCall frames.
func TestCodexCollabWireHelpers(t *testing.T) {
	t.Run("codexParseCollabItem_started", func(t *testing.T) {
		p := collabStartedParams(spawnCallA, promptAlpha)
		ev, ok := codexParseCollabItem(p)
		if !ok {
			t.Fatal("expected ok=true for collabAgentToolCall")
		}
		if ev.Tool != "spawnAgent" {
			t.Errorf("tool=%q want spawnAgent", ev.Tool)
		}
		if ev.CallID != spawnCallA {
			t.Errorf("callID=%q want %q", ev.CallID, spawnCallA)
		}
		if ev.Prompt != promptAlpha {
			t.Errorf("prompt mismatch")
		}
		if len(ev.ReceiverThreadIDs) != 0 {
			t.Errorf("receiverThreadIds should be empty on started, got %v", ev.ReceiverThreadIDs)
		}
		if ev.Status != "inProgress" {
			t.Errorf("status=%q want inProgress", ev.Status)
		}
	})

	t.Run("codexParseCollabItem_completed", func(t *testing.T) {
		p := collabCompletedParams(spawnCallA, subThreadA, promptAlpha)
		ev, ok := codexParseCollabItem(p)
		if !ok {
			t.Fatal("expected ok=true")
		}
		if len(ev.ReceiverThreadIDs) != 1 || ev.ReceiverThreadIDs[0] != subThreadA {
			t.Errorf("receiverThreadIds=%v want [%s]", ev.ReceiverThreadIDs, subThreadA)
		}
		if ev.Status != "completed" {
			t.Errorf("status=%q want completed", ev.Status)
		}
	})

	t.Run("codexParseCollabItem_non_collab_ignored", func(t *testing.T) {
		p := mustJSON(map[string]any{
			"item":     map[string]any{"type": "agentMessage", "id": "x", "text": "hi"},
			"threadId": parentThread,
		})
		_, ok := codexParseCollabItem(p)
		if ok {
			t.Error("agentMessage item should not parse as collabAgentToolCall")
		}
	})

	t.Run("codexNotificationThreadID", func(t *testing.T) {
		p := mustJSON(map[string]any{"threadId": parentThread, "turn": map[string]any{}})
		tid := codexNotificationThreadID(p)
		if tid != parentThread {
			t.Errorf("got %q want %q", tid, parentThread)
		}
	})

	t.Run("codexNotificationThreadID_missing", func(t *testing.T) {
		p := mustJSON(map[string]any{"thread": map[string]any{"id": "x"}})
		tid := codexNotificationThreadID(p)
		if tid != "" {
			t.Errorf("expected empty, got %q", tid)
		}
	})

	t.Run("codexSubagentLastTokens", func(t *testing.T) {
		p := subAgentTokenUsageParams(subThreadA, 15585)
		toks := codexSubagentLastTokens(p)
		if toks != 15585 {
			t.Errorf("tokens=%d want 15585", toks)
		}
	})

	t.Run("codexSubagentTurnDurationMS", func(t *testing.T) {
		p := subAgentTurnCompletedParams(subThreadA, 8375)
		dur := codexSubagentTurnDurationMS(p)
		if dur != 8375 {
			t.Errorf("durationMs=%d want 8375", dur)
		}
	})

	t.Run("codexSubagentNameFromPrompt_long", func(t *testing.T) {
		name := codexSubagentNameFromPrompt(promptAlpha, subThreadA)
		if len(name) > 40 {
			t.Errorf("name too long: %d > 40, %q", len(name), name)
		}
		if name == "" {
			t.Error("name should not be empty")
		}
	})

	t.Run("codexSubagentNameFromPrompt_empty_fallback", func(t *testing.T) {
		name := codexSubagentNameFromPrompt("", subThreadA)
		if !strings.HasPrefix(name, "agent ") {
			t.Errorf("fallback name should start with 'agent ', got %q", name)
		}
	})

	t.Run("codexCollabStatusToRoster", func(t *testing.T) {
		cases := []struct{ in, want string }{
			{"pendingInit", "working"},
			{"running", "working"},
			{"completed", "done"},
			{"shutdown", "done"},
			{"errored", "failed"},
			{"interrupted", "failed"},
			{"notFound", "failed"},
		}
		for _, tc := range cases {
			got := codexCollabStatusToRoster(tc.in)
			if got != tc.want {
				t.Errorf("codexCollabStatusToRoster(%q)=%q want %q", tc.in, got, tc.want)
			}
		}
	})
}
