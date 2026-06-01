package session

import (
	"strconv"
	"strings"
	"testing"
)

// TestCommandEnv_SetsPreviewPort verifies an allocated preview port is exported
// to the spawned agent as $PORT and $AGENT_CHAT_PORT (=PORT+1000), per
// AGENT-ADAPTERS.md §2.3.
func TestCommandEnv_SetsPreviewPort(t *testing.T) {
	s := &Session{ID: "sess-preview", Assistant: "claude", previewPort: 3005}
	gotPort, gotChat := false, false
	for _, kv := range s.commandEnv(nil) {
		switch kv {
		case "PORT=3005":
			gotPort = true
		case "AGENT_CHAT_PORT=4005":
			gotChat = true
		}
	}
	if !gotPort {
		t.Error("PORT=3005 not exported to the agent env")
	}
	if !gotChat {
		t.Error("AGENT_CHAT_PORT=4005 not exported to the agent env")
	}
}

// TestCommandEnv_NoPreviewPortWhenUnallocated confirms we don't fabricate a
// non-empty AGENT_CHAT_PORT when the pool was exhausted (previewPort == 0).
func TestCommandEnv_NoPreviewPortWhenUnallocated(t *testing.T) {
	s := &Session{ID: "sess-noport", Assistant: "claude"}
	for _, kv := range s.commandEnv(nil) {
		if strings.HasPrefix(kv, "AGENT_CHAT_PORT=") && kv != "AGENT_CHAT_PORT=" {
			t.Errorf("unexpected %q exported when no preview port allocated", kv)
		}
	}
}

// TestStatusPayload_IncludesPreview asserts the status frame carries the
// preview {port,url} bundle (WEBSOCKET-PROTOCOL.md §3.2) when a port is set.
func TestStatusPayload_IncludesPreview(t *testing.T) {
	s := &Session{ID: "abc123", previewPort: 3007}
	prev, ok := s.StatusPayload()["preview"].(map[string]any)
	if !ok {
		t.Fatalf("preview missing/!map in status payload")
	}
	if prev["port"] != 3007 {
		t.Errorf("preview.port = %v, want 3007", prev["port"])
	}
	if prev["url"] != "/preview/abc123/" {
		t.Errorf("preview.url = %v, want /preview/abc123/", prev["url"])
	}
}

// TestStatusPayload_NoPreviewWhenUnallocated: absent key when no port.
func TestStatusPayload_NoPreviewWhenUnallocated(t *testing.T) {
	s := &Session{ID: "noprev"}
	if _, ok := s.StatusPayload()["preview"]; ok {
		t.Error("preview should be absent when no port is allocated")
	}
}

// TestAllocatePreviewPort covers distinctness, range, exhaustion, and reuse of
// freed ports.
func TestAllocatePreviewPort(t *testing.T) {
	m := &Manager{sessions: map[string]*Session{}}
	seen := map[int]bool{}
	for i := 0; i < previewPortCount; i++ {
		p := m.allocatePreviewPortLocked()
		if p < previewPortBase || p >= previewPortBase+previewPortCount {
			t.Fatalf("allocated port %d out of [%d,%d)", p, previewPortBase, previewPortBase+previewPortCount)
		}
		if seen[p] {
			t.Fatalf("port %d allocated twice", p)
		}
		seen[p] = true
		m.sessions["s"+strconv.Itoa(i)] = &Session{previewPort: p}
	}
	if p := m.allocatePreviewPortLocked(); p != 0 {
		t.Fatalf("expected 0 when pool exhausted, got %d", p)
	}
	delete(m.sessions, "s3")
	if p := m.allocatePreviewPortLocked(); p == 0 {
		t.Fatal("expected a freed port to be reusable")
	}
}
