package session

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

// A watchdog phase/health transition must be PUSHED to subscribed clients, not
// only persisted — otherwise the flip back to "running" (once a quiet or
// recovered agent resumes) never reaches the app until its next reconnect,
// leaving the session stuck read-only ("never goes back to running").
func TestSetHealthBroadcastsOnChange(t *testing.T) {
	s := &Session{
		ID:         "sess-test",
		metaPath:   filepath.Join(t.TempDir(), "meta.json"),
		health:     "healthy",
		phase:      "running",
		reasonCode: "ok",
		subs:       make(map[chan []byte]struct{}),
		textSubs:   make(map[chan []byte]struct{}),
	}
	sub := s.SubscribeText()

	s.setHealthWithReason("warning", "running", "no_output")
	select {
	case raw := <-sub:
		var f map[string]any
		if err := json.Unmarshal(raw, &f); err != nil {
			t.Fatalf("status frame not JSON: %v", err)
		}
		if f["type"] != "status" {
			t.Fatalf("want type=status, got %v", f["type"])
		}
		if f["phase"] != "running" {
			t.Fatalf("want phase=running (alive but quiet), got %v", f["phase"])
		}
		if f["reason_code"] != "no_output" {
			t.Fatalf("want reason_code=no_output, got %v", f["reason_code"])
		}
	case <-time.After(time.Second):
		t.Fatal("expected a status broadcast on health change, got none")
	}

	// An identical no-op set must NOT broadcast (no churn on every tick).
	s.setHealthWithReason("warning", "running", "no_output")
	select {
	case raw := <-sub:
		t.Fatalf("no-op setHealth should not broadcast, got %s", raw)
	case <-time.After(150 * time.Millisecond):
	}
}

// A quiet-but-alive agent must keep a LIVE phase (the app reads any non-live
// phase as read-only). Only empty/terminal/dead phases are non-live.
func TestIsLivePhaseClassification(t *testing.T) {
	for _, p := range []string{"running", "ready", "idle", "thinking", "working", "starting", "booting", "swapping"} {
		if !isLivePhase(p) {
			t.Fatalf("%q must be classified live", p)
		}
	}
	for _, p := range []string{"", "exited", "exited(0)", "failed", "dead", "stalled", "STALLED "} {
		if isLivePhase(p) {
			t.Fatalf("%q must be classified non-live", p)
		}
	}
}
