package session

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/push"
)

// recordingNotifier captures every Notify call.
type recordingNotifier struct {
	mu   sync.Mutex
	got  []push.Payload
	errs []error // per-call error to return (nil = no error)
}

func (r *recordingNotifier) Notify(_ context.Context, _ string, p push.Payload) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.got = append(r.got, p)
	if len(r.errs) > 0 {
		err := r.errs[0]
		r.errs = r.errs[1:]
		return err
	}
	return nil
}

func (r *recordingNotifier) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.got)
}

func (r *recordingNotifier) last() push.Payload {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.got) == 0 {
		return push.Payload{}
	}
	return r.got[len(r.got)-1]
}

// bareSession returns a minimal Session suitable for push-notify tests:
// no PTY, no adapter, no process — just the fields the push path needs.
func bareSession(id string) *Session {
	s := &Session{
		ID:        id,
		Assistant: "claude",
		subs:      make(map[chan []byte]struct{}),
		textSubs:  make(map[chan []byte]struct{}),
		closed:    make(chan struct{}),
	}
	return s
}

// attachViewer adds a binary PTY subscriber (simulates a connected WS client).
func attachViewer(s *Session) chan []byte {
	ch := make(chan []byte, 64)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

// detachViewer removes the subscriber (simulates a WS disconnect).
func detachViewer(s *Session, ch chan []byte) {
	s.mu.Lock()
	delete(s.subs, ch)
	s.mu.Unlock()
}

// TestPushNotifyTurnEnd_NoClient verifies that a turn-end fires a push when
// no client is attached.
func TestPushNotifyTurnEnd_NoClient(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-1")
	s.SetPushNotifier(n, "broker")

	// No subscriber → should notify.
	s.maybeNotifyTurnEnd()

	if n.count() != 1 {
		t.Fatalf("expected 1 notification, got %d", n.count())
	}
	p := n.last()
	if p.SessionID != "sess-1" {
		t.Errorf("session id = %q, want %q", p.SessionID, "sess-1")
	}
	if p.Body != "Turn finished" {
		t.Errorf("body = %q, want \"Turn finished\"", p.Body)
	}
	if p.Title != "claude" {
		t.Errorf("title = %q, want \"claude\" (assistant name)", p.Title)
	}
}

// TestPushNotifyTurnEnd_WithClient verifies that no push fires when a client
// is watching.
func TestPushNotifyTurnEnd_WithClient(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-2")
	s.SetPushNotifier(n, "broker")

	ch := attachViewer(s)
	defer detachViewer(s, ch)

	s.maybeNotifyTurnEnd()

	if n.count() != 0 {
		t.Fatalf("expected 0 notifications (client attached), got %d", n.count())
	}
}

// TestPushNotifyPendingInput_NoClient verifies that a pending-input card fires
// a push when no client is attached.
func TestPushNotifyPendingInput_NoClient(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-3")
	s.SetPushNotifier(n, "broker")

	s.maybeNotifyPendingInput()

	if n.count() != 1 {
		t.Fatalf("expected 1 notification, got %d", n.count())
	}
	p := n.last()
	if p.Body != "Needs your input" {
		t.Errorf("body = %q, want \"Needs your input\"", p.Body)
	}
	if p.SessionID != "sess-3" {
		t.Errorf("session id = %q, want %q", p.SessionID, "sess-3")
	}
}

// TestPushNotifyPendingInput_WithClient verifies that no push fires when a
// client is watching.
func TestPushNotifyPendingInput_WithClient(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-4")
	s.SetPushNotifier(n, "broker")

	ch := attachViewer(s)
	defer detachViewer(s, ch)

	s.maybeNotifyPendingInput()

	if n.count() != 0 {
		t.Fatalf("expected 0 notifications (client attached), got %d", n.count())
	}
}

// TestPushNotifyDebounce verifies that two rapid turn-end transitions coalesce
// into a single push (the debounce window).
func TestPushNotifyDebounce(t *testing.T) {
	// Pin the clock so rapid consecutive calls hit the debounce window.
	fixed := time.Date(2026, 6, 10, 0, 0, 0, 0, time.UTC)
	orig := pushNow
	pushNow = func() time.Time { return fixed }
	defer func() { pushNow = orig }()

	n := &recordingNotifier{}
	s := bareSession("sess-5")
	s.SetPushNotifier(n, "broker")

	// Two rapid turn-end calls at the same "now" — second should be coalesced.
	s.maybeNotifyTurnEnd()
	s.maybeNotifyTurnEnd()

	if n.count() != 1 {
		t.Fatalf("expected 1 notification (debounce), got %d", n.count())
	}

	// After advancing time past the window, a new call should fire.
	pushNow = func() time.Time { return fixed.Add(idlePushWindow + time.Millisecond) }
	s.maybeNotifyTurnEnd()

	if n.count() != 2 {
		t.Fatalf("expected 2 notifications after debounce window, got %d", n.count())
	}
}

// TestPushNotifyNoNotifier verifies that nil notifier / empty identity are
// safe no-ops.
func TestPushNotifyNoNotifier(t *testing.T) {
	s := bareSession("sess-6")
	// SetPushNotifier not called → pushState.notifier is nil.
	// These must not panic.
	s.maybeNotifyTurnEnd()
	s.maybeNotifyPendingInput()
}

// TestPushNotifyDisplayName verifies that a renamed session uses displayName
// as the notification title.
func TestPushNotifyDisplayName(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-7")
	s.SetPushNotifier(n, "broker")

	s.mu.Lock()
	s.displayName = "My Project"
	s.mu.Unlock()

	s.maybeNotifyTurnEnd()

	if n.count() != 1 {
		t.Fatalf("expected 1 notification, got %d", n.count())
	}
	if n.last().Title != "My Project" {
		t.Errorf("title = %q, want \"My Project\"", n.last().Title)
	}
}
