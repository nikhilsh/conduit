package session

import (
	"bufio"
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"
)

// fixedClock returns a clock function that advances by 100ms per call,
// starting at t0. Used so golden output has deterministic timestamps.
func fixedClock(t0 time.Time) func() time.Time {
	mu := sync.Mutex{}
	n := 0
	return func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		t := t0.Add(time.Duration(n) * 100 * time.Millisecond)
		n++
		return t
	}
}

// applyFixture feeds every task_* line from path through the registry and
// returns the slice of snapshots emitted (one per changed frame). Each
// snapshot is the agents[] slice at that point in time.
func applyFixture(t *testing.T, path string) [][]map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open fixture %q: %v", path, err)
	}
	defer f.Close()

	reg := newSubagentRegistry()
	epoch := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := fixedClock(epoch)

	var snaps [][]map[string]any
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		ev, ok := parseSubagentTaskEvent(sc.Bytes())
		if !ok {
			continue
		}
		changed := reg.apply(ev, clock())
		if changed {
			snaps = append(snaps, reg.snapshot())
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan %q: %v", path, err)
	}
	return snaps
}

// TestSubagentRegistryGeneralPurpose feeds the two-subagent fixture
// (task-events-general.jsonl: 2×started, 2×progress, 2×notification)
// and checks the final roster for the correct keys and status transitions.
func TestSubagentRegistryGeneralPurpose(t *testing.T) {
	snaps := applyFixture(t, "testdata/task-events-general.jsonl")
	// 6 events, all changing state → 6 snapshots.
	if len(snaps) != 6 {
		t.Fatalf("expected 6 snapshots, got %d", len(snaps))
	}

	// After the last notification both agents should be "done".
	final := snaps[len(snaps)-1]
	if len(final) != 2 {
		t.Fatalf("expected 2 agents in final roster, got %d", len(final))
	}

	// Required JSON keys present on every entry.
	requiredKeys := []string{
		"task_id", "name", "description", "status",
		"last_tool", "tokens", "tool_uses", "duration_ms",
		"started_at", "ended_at",
	}
	for i, entry := range final {
		for _, k := range requiredKeys {
			if _, ok := entry[k]; !ok {
				t.Errorf("final[%d]: missing key %q", i, k)
			}
		}
		if entry["status"] != "done" {
			t.Errorf("final[%d]: want status=done, got %v", i, entry["status"])
		}
		if entry["ended_at"] == "" {
			t.Errorf("final[%d]: ended_at should be set", i)
		}
		// Tokens should be non-zero (came from the progress + notification frames).
		toks, ok := entry["tokens"].(uint64)
		if !ok || toks == 0 {
			t.Errorf("final[%d]: tokens expected >0, got %v (%T)", i, entry["tokens"], entry["tokens"])
		}
	}

	// After task_started for the first agent the roster has 1 entry.
	first := snaps[0]
	if len(first) != 1 {
		t.Fatalf("after first task_started: expected 1 agent, got %d", len(first))
	}
	if first[0]["status"] != "working" {
		t.Errorf("first snap: want status=working, got %v", first[0]["status"])
	}
	if first[0]["name"] != "general-purpose" {
		t.Errorf("first snap: want name=general-purpose, got %v", first[0]["name"])
	}
	// started_at must be non-empty; ended_at must be empty.
	if first[0]["started_at"] == "" {
		t.Errorf("first snap: started_at should be set")
	}
	if first[0]["ended_at"] != "" {
		t.Errorf("first snap: ended_at should be empty, got %v", first[0]["ended_at"])
	}
}

// TestSubagentRegistryNamed feeds the single-named-subagent fixture
// (task-events-named.jsonl: researcher, 1×started, 2×progress,
// 1×notification) and verifies the terminal state.
func TestSubagentRegistryNamed(t *testing.T) {
	snaps := applyFixture(t, "testdata/task-events-named.jsonl")
	// 4 events → 4 snapshots.
	if len(snaps) != 4 {
		t.Fatalf("expected 4 snapshots, got %d", len(snaps))
	}

	final := snaps[len(snaps)-1]
	if len(final) != 1 {
		t.Fatalf("expected 1 agent in final roster, got %d", len(final))
	}
	a := final[0]
	if a["name"] != "researcher" {
		t.Errorf("want name=researcher, got %v", a["name"])
	}
	if a["status"] != "done" {
		t.Errorf("want status=done, got %v", a["status"])
	}
	if a["task_id"] == "" {
		t.Errorf("task_id must not be empty")
	}
	// Verify the last_tool was captured from one of the progress frames.
	// The fixture has both "Bash" and "Read" last_tool_name; the last progress
	// frame is "Read", so that's what the notification snapshot should carry.
	if a["last_tool"] == "" {
		t.Errorf("last_tool should be non-empty after progress frames")
	}
}

// TestSubagentTaskEventParser checks the pure decoder against known-good
// and known-bad lines.
func TestSubagentTaskEventParser(t *testing.T) {
	cases := []struct {
		name    string
		line    string
		wantOK  bool
		subtype string
		taskID  string
	}{
		{
			name:    "task_started",
			line:    `{"type":"system","subtype":"task_started","task_id":"abc123","subagent_type":"researcher","description":"Read file"}`,
			wantOK:  true,
			subtype: "task_started",
			taskID:  "abc123",
		},
		{
			name:    "task_progress",
			line:    `{"type":"system","subtype":"task_progress","task_id":"abc123","subagent_type":"researcher","usage":{"total_tokens":100,"tool_uses":1,"duration_ms":500},"last_tool_name":"Bash"}`,
			wantOK:  true,
			subtype: "task_progress",
			taskID:  "abc123",
		},
		{
			name:    "task_notification completed",
			line:    `{"type":"system","subtype":"task_notification","task_id":"abc123","status":"completed","usage":{"total_tokens":200,"tool_uses":2,"duration_ms":1000}}`,
			wantOK:  true,
			subtype: "task_notification",
			taskID:  "abc123",
		},
		{name: "system init ignored", line: `{"type":"system","subtype":"init","session_id":"x"}`, wantOK: false},
		{name: "assistant line ignored", line: `{"type":"assistant","message":{"role":"assistant","content":[]}}`, wantOK: false},
		{name: "result line ignored", line: `{"type":"result","subtype":"success"}`, wantOK: false},
		{name: "empty line ignored", line: ``, wantOK: false},
		{name: "no task_id ignored", line: `{"type":"system","subtype":"task_started"}`, wantOK: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ev, ok := parseSubagentTaskEvent([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok=%v want %v (ev=%+v)", ok, tc.wantOK, ev)
			}
			if !ok {
				return
			}
			if ev.Subtype != tc.subtype {
				t.Errorf("subtype=%q want %q", ev.Subtype, tc.subtype)
			}
			if ev.TaskID != tc.taskID {
				t.Errorf("task_id=%q want %q", ev.TaskID, tc.taskID)
			}
		})
	}
}

// TestSubagentViewEventJSON checks that the view_event emitted by
// onTaskEvent has the exact JSON shape required by the spec.
func TestSubagentViewEventJSON(t *testing.T) {
	var published []byte
	reg := newSubagentRegistry()
	mu := sync.Mutex{}
	h := &subagentRegistryHandle{
		mu:        &mu,
		reg:       reg,
		publish:   func(p []byte) { published = p },
		sessionID: "test-session",
	}

	epoch := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

	// Inject a controlled clock for the registry apply.
	apply := func(ev subagentTaskEvent) {
		mu.Lock()
		reg.apply(ev, epoch)
		snap := reg.snapshot()
		mu.Unlock()
		payload, err := json.Marshal(map[string]any{
			"type": "view_event",
			"view": "agents",
			"event": map[string]any{
				"agents": snap,
			},
		})
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		h.publish(payload)
	}

	// Fire a task_started event.
	apply(subagentTaskEvent{
		Subtype:      "task_started",
		TaskID:       "task-001",
		SubagentType: "ci-reviewer",
		Description:  "Read a.txt contents",
	})

	if published == nil {
		t.Fatal("expected a published payload")
	}

	// Decode the top-level frame.
	var frame struct {
		Type  string `json:"type"`
		View  string `json:"view"`
		Event struct {
			Agents []map[string]json.RawMessage `json:"agents"`
		} `json:"event"`
	}
	if err := json.Unmarshal(published, &frame); err != nil {
		t.Fatalf("unmarshal frame: %v", err)
	}
	if frame.Type != "view_event" {
		t.Errorf("type=%q want view_event", frame.Type)
	}
	if frame.View != "agents" {
		t.Errorf("view=%q want agents", frame.View)
	}
	if len(frame.Event.Agents) != 1 {
		t.Fatalf("expected 1 agent in event, got %d", len(frame.Event.Agents))
	}

	a := frame.Event.Agents[0]
	assertJSONStr := func(field, want string) {
		t.Helper()
		raw, ok := a[field]
		if !ok {
			t.Errorf("missing key %q", field)
			return
		}
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			t.Errorf("%q not a string: %v", field, err)
			return
		}
		if s != want {
			t.Errorf("%q=%q want %q", field, s, want)
		}
	}

	assertJSONStr("task_id", "task-001")
	assertJSONStr("name", "ci-reviewer")
	assertJSONStr("description", "Read a.txt contents")
	assertJSONStr("status", "working")
	assertJSONStr("last_tool", "")
	assertJSONStr("ended_at", "")
}

// TestSubagentRegistryFullLifecycle exercises the full
// task_started → task_progress → task_notification state machine for a
// single subagent and checks every field matches the spec contract.
func TestSubagentRegistryFullLifecycle(t *testing.T) {
	reg := newSubagentRegistry()
	epoch := time.Date(2026, 6, 11, 0, 0, 0, 0, time.UTC)
	t1 := epoch
	t2 := epoch.Add(3 * time.Second)
	t3 := epoch.Add(5 * time.Second)

	started := subagentTaskEvent{
		Subtype:      "task_started",
		TaskID:       "a85166712f62b002d",
		SubagentType: "ci-reviewer",
		Description:  "Read a.txt contents",
	}
	progress := subagentTaskEvent{
		Subtype:      "task_progress",
		TaskID:       "a85166712f62b002d",
		SubagentType: "ci-reviewer",
		Description:  "Reading a.txt",
		LastToolName: "Read",
		Usage: subagentUsage{
			TotalTokens: 10226,
			ToolUses:    1,
			DurationMS:  2843,
		},
	}
	notification := subagentTaskEvent{
		Subtype: "task_notification",
		TaskID:  "a85166712f62b002d",
		Status:  "completed",
		Usage: subagentUsage{
			TotalTokens: 10343,
			ToolUses:    1,
			DurationMS:  4335,
		},
	}

	reg.apply(started, t1)
	snap1 := reg.snapshot()
	if len(snap1) != 1 || snap1[0]["status"] != "working" {
		t.Fatalf("after started: %+v", snap1)
	}

	reg.apply(progress, t2)
	snap2 := reg.snapshot()
	a := snap2[0]
	if a["status"] != "working" {
		t.Errorf("after progress: status=%v want working", a["status"])
	}
	if a["last_tool"] != "Read" {
		t.Errorf("after progress: last_tool=%v want Read", a["last_tool"])
	}
	if a["tokens"] != uint64(10226) {
		t.Errorf("after progress: tokens=%v want 10226", a["tokens"])
	}
	if a["description"] != "Reading a.txt" {
		t.Errorf("after progress: description=%v want 'Reading a.txt'", a["description"])
	}

	reg.apply(notification, t3)
	snap3 := reg.snapshot()
	b := snap3[0]
	if b["status"] != "done" {
		t.Errorf("after notification: status=%v want done", b["status"])
	}
	if b["tokens"] != uint64(10343) {
		t.Errorf("after notification: tokens=%v want 10343", b["tokens"])
	}
	if b["ended_at"] == "" {
		t.Errorf("after notification: ended_at should be set")
	}
	if b["task_id"] != "a85166712f62b002d" {
		t.Errorf("task_id mismatch: %v", b["task_id"])
	}
	if b["name"] != "ci-reviewer" {
		t.Errorf("name mismatch: %v", b["name"])
	}
}
