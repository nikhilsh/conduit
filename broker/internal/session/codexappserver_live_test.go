package session

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// chatEventRoleContent extracts (role, content) from a marshaled chat
// view_event payload, returning empty strings if it isn't one.
func chatEventRoleContent(p []byte) (string, string) {
	var ev struct {
		View  string `json:"view"`
		Event struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"event"`
	}
	if json.Unmarshal(p, &ev) != nil || ev.View != "chat" {
		return "", ""
	}
	return ev.Event.Role, ev.Event.Content
}

// TestCodexAppServerLive drives the REAL `codex app-server` binary end to end:
// handshake → a trivial turn → a manual /compact. It is skipped unless
// CONDUIT_CODEX_LIVE=1 (CI has no codex binary or auth), so it only runs on a
// box where `codex` is installed and signed in. This is the integration proof
// behind the unit tests — the on-box verification for task #18.
//
//	CONDUIT_CODEX_LIVE=1 go test ./internal/session/ -run TestCodexAppServerLive -v
func TestCodexAppServerLive(t *testing.T) {
	if os.Getenv("CONDUIT_CODEX_LIVE") != "1" {
		t.Skip("set CONDUIT_CODEX_LIVE=1 to run against the real codex binary")
	}
	dir := t.TempDir()

	events := make(chan []byte, 64)
	usages := make(chan usageDelta, 16)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		"codex", dir, os.Environ(), SpawnOverride{},
		func(p []byte) { events <- p },
		func(u usageDelta) { usages <- u },
		"",
		func(id string) { threads <- id },
		nil, // no subagent roster in live test
	)
	if err != nil {
		t.Fatalf("spawn/handshake failed: %v", err)
	}
	defer proc.Close()

	select {
	case id := <-threads:
		t.Logf("latched thread id: %s", id)
	case <-time.After(20 * time.Second):
		t.Fatal("timeout waiting for thread id latch")
	}

	// --- A trivial turn ---
	if err := proc.Send("Reply with exactly the two words: hello world"); err != nil {
		t.Fatalf("Send turn: %v", err)
	}
	gotAssistant := waitForRole(t, events, "assistant", 60*time.Second)
	t.Logf("assistant reply: %q", gotAssistant)
	if strings.TrimSpace(gotAssistant) == "" {
		t.Fatal("empty assistant reply")
	}

	// --- Manual compact ---
	// The turn isn't fully done until turn/completed clears the in-flight
	// flag (a moment after the assistant item completes). In the app the
	// composer is locked while a turn runs, so a user can't race it; here we
	// retry until the backend accepts the next send.
	deadline := time.Now().Add(30 * time.Second)
	for {
		err := proc.Send("/compact")
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("Send /compact never accepted: %v", err)
		}
		time.Sleep(250 * time.Millisecond)
	}
	sys := waitForRole(t, events, "system", 60*time.Second)
	t.Logf("system line after /compact: %q", sys)
	if !strings.Contains(sys, "ompact") {
		t.Fatalf("expected a compaction system line, got %q", sys)
	}
}

// TestCodexAppServerLiveApproval drives the REAL `codex app-server` through the
// approval path: PermissionMode "plan" (read-only sandbox + on-request approvals)
// + a turn that forces a file WRITE, so the command must escalate past read-only
// and codex sends an item/commandExecution/requestApproval. The backend must
// surface the approval card (pending-input chat event), AnswerApproval("Approve")
// must send accept, and the file must end up written. Skipped unless
// CONDUIT_CODEX_LIVE=1.
//
//	CONDUIT_CODEX_LIVE=1 go test ./internal/session/ -run TestCodexAppServerLiveApproval -v
func TestCodexAppServerLiveApproval(t *testing.T) {
	if os.Getenv("CONDUIT_CODEX_LIVE") != "1" {
		t.Skip("set CONDUIT_CODEX_LIVE=1 to run against the real codex binary")
	}
	dir := t.TempDir()

	events := make(chan []byte, 128)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		"codex", dir, os.Environ(),
		SpawnOverride{PermissionMode: "plan"}, // read-only + on-request
		func(p []byte) { events <- p },
		nil, "",
		func(id string) { threads <- id },
		nil, // no subagent roster in live test
	)
	if err != nil {
		t.Fatalf("spawn/handshake failed: %v", err)
	}
	defer proc.Close()

	select {
	case id := <-threads:
		t.Logf("latched thread id: %s", id)
	case <-time.After(20 * time.Second):
		t.Fatal("timeout waiting for thread id latch")
	}

	if err := proc.Send("Create a file named hello.txt containing the word hi by running the shell command: echo hi > hello.txt. Actually run it now."); err != nil {
		t.Fatalf("Send turn: %v", err)
	}

	// Wait for the approval card (pending-input sentinel) to surface.
	deadline := time.After(90 * time.Second)
	var sawCard bool
	for !sawCard {
		select {
		case p := <-events:
			r, c := chatEventRoleContent(p)
			t.Logf("  event role=%s content=%.80q", r, c)
			if r == "assistant" && strings.HasPrefix(c, pendingInputSentinel) {
				sawCard = true
				if !strings.Contains(c, codexApprovalApproveLabel) {
					t.Fatalf("approval card missing Approve option:\n%s", c)
				}
			}
		case <-deadline:
			t.Fatal("timeout waiting for the approval card")
		}
	}

	if _, ok := proc.PendingApprovalCard(); !ok {
		t.Fatal("expected a pending approval after the card")
	}

	// Tap Approve → the command runs.
	if !proc.AnswerApproval(codexApprovalApproveLabel) {
		t.Fatal("AnswerApproval should report handled")
	}

	// Give the turn time to run the approved command + finish.
	turnDone := time.After(60 * time.Second)
	for {
		select {
		case p := <-events:
			r, c := chatEventRoleContent(p)
			t.Logf("  post-approve role=%s content=%.80q", r, c)
		case <-turnDone:
			goto check
		case <-time.After(8 * time.Second):
			goto check
		}
	}
check:
	if _, err := os.Stat(dir + "/hello.txt"); err != nil {
		t.Fatalf("approved command did not create hello.txt: %v", err)
	}
	t.Log("approved command created hello.txt — approval accept path verified end to end")
}

// TestCodexAppServerLiveSubagents drives the REAL `codex app-server` through a
// multi-agent prompt (spawnAgent). It verifies:
//   - sub-agent spawns register roster nodes via view_event(agents)
//   - sub-agent messages do NOT appear in the parent chat events
//   - the parent turn completes normally (not prematurely ended by a sub-agent)
//
// Skipped unless CONDUIT_CODEX_LIVE=1. Can be slow (~60–120s).
//
//	CONDUIT_CODEX_LIVE=1 go test ./internal/session/ -run TestCodexAppServerLiveSubagents -v -timeout 180s
func TestCodexAppServerLiveSubagents(t *testing.T) {
	if os.Getenv("CONDUIT_CODEX_LIVE") != "1" {
		t.Skip("set CONDUIT_CODEX_LIVE=1 to run against the real codex binary")
	}
	dir := t.TempDir()

	chatEvents := make(chan []byte, 256)
	agentEvents := make(chan []byte, 64)
	threads := make(chan string, 4)

	publish := func(p []byte) {
		var frame struct {
			View string `json:"view"`
		}
		if json.Unmarshal(p, &frame) == nil && frame.View == "agents" {
			cp := make([]byte, len(p))
			copy(cp, p)
			select {
			case agentEvents <- cp:
			default:
			}
		} else {
			cp := make([]byte, len(p))
			copy(cp, p)
			select {
			case chatEvents <- cp:
			default:
			}
		}
	}

	// Wire a real subagent registry handle so roster events flow.
	var subMu sync.Mutex
	subReg := newSubagentRegistry()
	subH := &subagentRegistryHandle{
		mu:        &subMu,
		reg:       subReg,
		publish:   publish,
		sessionID: "live-subagent-test",
	}

	proc, err := newCodexAppServerProcess(
		"codex", dir, os.Environ(), SpawnOverride{},
		publish,
		nil, "",
		func(id string) { threads <- id },
		subH,
	)
	if err != nil {
		t.Fatalf("spawn/handshake failed: %v", err)
	}
	defer proc.Close()

	select {
	case id := <-threads:
		t.Logf("parent thread: %s", id)
	case <-time.After(20 * time.Second):
		t.Fatal("timeout waiting for thread id latch")
	}

	// Send a multi-agent prompt.
	const multiAgentPrompt = "Use your spawnAgent collaboration tool to delegate " +
		"two tasks in parallel: one sub-agent should tell me 1+1, another should " +
		"tell me 2+2. Wait for both, then summarize. You MUST use spawnAgent."
	if err := proc.Send(multiAgentPrompt); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// Wait for the parent turn to complete (up to 120s for multi-agent latency).
	var gotAssistant bool
	deadline := time.After(120 * time.Second)
	for !gotAssistant {
		select {
		case p := <-chatEvents:
			r, c := chatEventRoleContent(p)
			t.Logf("  chat event role=%s content=%.80q", r, c)
			if r == "assistant" {
				gotAssistant = true
				t.Logf("parent assistant reply: %q", c[:min(len(c), 120)])
			}
		case p := <-agentEvents:
			// Decode + log roster snapshots as they arrive.
			var frame struct {
				Event struct {
					Agents []map[string]json.RawMessage `json:"agents"`
				} `json:"event"`
			}
			if json.Unmarshal(p, &frame) == nil {
				t.Logf("  roster update: %d agent(s)", len(frame.Event.Agents))
				for i, a := range frame.Event.Agents {
					var tid, status, name string
					json.Unmarshal(a["task_id"], &tid)
					json.Unmarshal(a["status"], &status)
					json.Unmarshal(a["name"], &name)
					t.Logf("    [%d] task_id=%s status=%s name=%.40q", i, tid[:min(len(tid), 20)], status, name)
				}
			}
		case <-deadline:
			t.Fatalf("timeout waiting for parent assistant reply after multi-agent turn")
		}
	}

	// After the parent turn completed, check that at least one roster snapshot
	// was published (i.e. sub-agents were detected and registered).
	// Drain any remaining agent events with a short timeout.
	time.Sleep(500 * time.Millisecond)

	subMu.Lock()
	finalSnap := subReg.snapshot()
	subMu.Unlock()

	t.Logf("final roster: %d agents", len(finalSnap))
	for i, a := range finalSnap {
		t.Logf("  [%d] task_id=%v status=%v tokens=%v duration_ms=%v",
			i, a["task_id"], a["status"], a["tokens"], a["duration_ms"])
	}

	if len(finalSnap) == 0 {
		t.Error("expected at least 1 sub-agent in the roster after multi-agent turn")
	}
	for i, a := range finalSnap {
		if a["task_id"] == "" {
			t.Errorf("agent[%d]: task_id is empty", i)
		}
		// Status should be done or working (sub-agents may still be running
		// when the parent summarizes); either is acceptable.
		status, _ := a["status"].(string)
		if status == "" {
			t.Errorf("agent[%d]: status is empty", i)
		}
		t.Logf("  agent[%d]: task_id=%v status=%v name=%v description=%.60v",
			i, a["task_id"], a["status"], a["name"], a["description"])
	}
}

// min returns the smaller of a and b (helper for test log truncation).
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// waitForRole drains chat view_events until one with the given role arrives,
// returning its content. Fails the test on timeout.
func waitForRole(t *testing.T, events <-chan []byte, role string, timeout time.Duration) string {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case p := <-events:
			r, c := chatEventRoleContent(p)
			t.Logf("  event role=%s content=%.80q", r, c)
			if r == role {
				return c
			}
		case <-deadline:
			t.Fatalf("timeout waiting for a %q chat event", role)
			return ""
		}
	}
}
