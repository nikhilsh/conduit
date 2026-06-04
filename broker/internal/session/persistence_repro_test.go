package session

import (
	"testing"
)

// TestSessionSurvivesLastViewerLeave reproduces the user-reported scenario:
// the iPhone app (the only viewer) terminates, dropping its WebSocket. The
// broker's serveWS handler runs its deferred Unsubscribe on that drop. The
// agent session is supposed to keep running server-side (the "litter" model),
// so a relaunch can reattach. This test asserts the session is NOT reaped and
// the agent process is still alive + processing input after the last viewer
// leaves.
func TestSessionSurvivesLastViewerLeave(t *testing.T) {
	root := testRoot(t)
	// An agent that echoes its stdin, so we can prove it's still alive AFTER
	// the viewer leaves.
	echo := "echo ready; while IFS= read -r line; do echo \"got:$line\"; done"
	reg := testRegistry(t, root, map[string]string{"claude": echo})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("survive-test", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "ready")

	// The only viewer attaches, then its connection drops (app terminated).
	sub := sess.Subscribe()
	if got := sess.SubscriberCount(); got != 1 {
		t.Fatalf("SubscriberCount after subscribe = %d, want 1", got)
	}
	sess.Unsubscribe(sub)
	if got := sess.SubscriberCount(); got != 0 {
		t.Fatalf("SubscriberCount after unsubscribe = %d, want 0", got)
	}

	// 1. The session must still be in the manager (not reaped on last leave).
	if _, ok := m.Get("survive-test"); !ok {
		t.Fatal("session was removed from the manager after the last viewer left")
	}

	// 2. The agent process must still be alive and processing input.
	if _, err := sess.Write([]byte("after-leave\n")); err != nil {
		t.Fatalf("writing to agent after last viewer left failed (process died?): %v", err)
	}
	waitForOutput(t, sess, "got:after-leave")
}
