package session

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/push"
)

// recordingSender captures Sender.Send calls for LA push tests.
type recordingSender struct {
	mu      sync.Mutex
	calls   []laSendCall
	errFunc func(i int) error // returns error for call index i; nil means no error
}

type laSendCall struct {
	token   push.DeviceToken
	payload push.Payload
}

func (r *recordingSender) Send(_ context.Context, tok push.DeviceToken, p push.Payload) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	idx := len(r.calls)
	r.calls = append(r.calls, laSendCall{token: tok, payload: p})
	if r.errFunc != nil {
		return r.errFunc(idx)
	}
	return nil
}

func (r *recordingSender) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func (r *recordingSender) lastPayload() push.Payload {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.calls) == 0 {
		return push.Payload{}
	}
	return r.calls[len(r.calls)-1].payload
}

func (r *recordingSender) lastToken() push.DeviceToken {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.calls) == 0 {
		return push.DeviceToken{}
	}
	return r.calls[len(r.calls)-1].token
}

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
	if p.Category != "input" {
		t.Errorf("category = %q, want \"input\" for generic pending input", p.Category)
	}
}

// fakeApprovalBackend is a minimal chatBackend + approvalAnswerer +
// approvalSummarizer for testing the approval push path.
type fakeApprovalBackend struct {
	summary  string
	answered string // set when AnswerApproval is called
}

func (f *fakeApprovalBackend) Send(_ string) error { return nil }
func (f *fakeApprovalBackend) Interrupt() error    { return nil }
func (f *fakeApprovalBackend) Close() error        { return nil }
func (f *fakeApprovalBackend) TurnActive() bool    { return true }
func (f *fakeApprovalBackend) PendingApprovalSummary() (string, bool) {
	if f.summary == "" {
		return "", false
	}
	return f.summary, true
}
func (f *fakeApprovalBackend) AnswerApproval(msg string) bool {
	if f.summary == "" {
		return false
	}
	f.answered = msg
	f.summary = "" // consume
	return true
}

// TestPushNotifyPendingInput_ApprovalCategory verifies that when a codex
// approval is pending, the push carries Category="approval" and the summary
// as the body (not the generic "Needs your input").
func TestPushNotifyPendingInput_ApprovalCategory(t *testing.T) {
	n := &recordingNotifier{}
	s := bareSession("sess-approval-cat")
	s.SetPushNotifier(n, "broker")

	// Wire a fake backend that reports an approval summary.
	backend := &fakeApprovalBackend{summary: "git commit -am 'wip'"}
	s.mu.Lock()
	s.chat = backend
	s.mu.Unlock()

	s.maybeNotifyPendingInput()

	if n.count() != 1 {
		t.Fatalf("expected 1 notification, got %d", n.count())
	}
	p := n.last()
	if p.Category != "approval" {
		t.Errorf("category = %q, want \"approval\"", p.Category)
	}
	if p.Body != "git commit -am 'wip'" {
		t.Errorf("body = %q, want the approval summary", p.Body)
	}
	if p.SessionID != "sess-approval-cat" {
		t.Errorf("session id = %q, want sess-approval-cat", p.SessionID)
	}
}

// TestTruncatePushBody verifies the rune-safe truncation helper.
func TestTruncatePushBody(t *testing.T) {
	cases := []struct {
		in   string
		max  int
		want string
	}{
		{"hello", 10, "hello"},
		{"hello world", 5, "hello…"},
		{"αβγδε", 3, "αβγ…"},
		{"", 10, ""},
		{"exact", 5, "exact"},
	}
	for _, tc := range cases {
		got := truncatePushBody(tc.in, tc.max)
		if got != tc.want {
			t.Errorf("truncatePushBody(%q, %d) = %q, want %q", tc.in, tc.max, got, tc.want)
		}
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

// ---- Live Activity emission tests ----

// newBareSessionWithLA builds a bare session wired with an LA registry and sender.
func newBareSessionWithLA(id string) (*Session, *push.LARegistry, *recordingSender) {
	s := bareSession(id)
	s.Assistant = "claude"
	reg := push.NewLARegistry()
	sender := &recordingSender{}
	s.SetLAState(reg, sender, "broker")
	return s, reg, sender
}

// TestLAEmit_TurnEnd verifies that notifyLATurnEnd sends an "end" event when
// an LA token is registered, then drops the token (so no further updates fire).
func TestLAEmit_TurnEnd(t *testing.T) {
	s, reg, sender := newBareSessionWithLA("sess-la-1")
	reg.SetLA("broker", "sess-la-1", "la-tok-abc")

	s.notifyLATurnEnd()

	if sender.count() != 1 {
		t.Fatalf("expected 1 LA send, got %d", sender.count())
	}
	p := sender.lastPayload()
	if p.Category != "liveactivity" {
		t.Errorf("category = %q, want liveactivity", p.Category)
	}
	if p.Event != "end" {
		t.Errorf("event = %q, want end", p.Event)
	}
	if p.SessionID != "sess-la-1" {
		t.Errorf("session_id = %q, want sess-la-1", p.SessionID)
	}
	cs := p.ContentState
	if cs == nil {
		t.Fatal("content_state is nil")
	}
	if cs["status"] != "exited" {
		t.Errorf("content_state.status = %v, want exited", cs["status"])
	}
	// Timestamps must be integers (epoch-millis).
	if _, ok := cs["syncedAtMs"].(int64); !ok {
		t.Errorf("syncedAtMs type = %T, want int64", cs["syncedAtMs"])
	}
	if _, ok := cs["startedAtMs"].(int64); !ok {
		t.Errorf("startedAtMs type = %T, want int64", cs["startedAtMs"])
	}
	// Token was sent to the correct device token.
	if sender.lastToken().Token != "la-tok-abc" {
		t.Errorf("sent to token %q, want la-tok-abc", sender.lastToken().Token)
	}
	// After end, the token must be dropped from the registry.
	if tok := reg.GetLA("broker", "sess-la-1"); tok != "" {
		t.Errorf("LA token not dropped after end: %q", tok)
	}
}

// TestLAEmit_NoToken verifies that no send occurs when no LA token is registered.
func TestLAEmit_NoToken(t *testing.T) {
	s, _, sender := newBareSessionWithLA("sess-la-2")
	// No token registered.
	s.notifyLATurnEnd()
	if sender.count() != 0 {
		t.Fatalf("expected 0 sends (no token), got %d", sender.count())
	}
}

// TestLAEmit_TurnEnd_AlertNotAffected verifies that alert notifications still
// fire for subscribers=0 even when LA is wired.
func TestLAEmit_TurnEnd_AlertNotAffected(t *testing.T) {
	alertN := &recordingNotifier{}
	s, reg, _ := newBareSessionWithLA("sess-la-3")
	s.SetPushNotifier(alertN, "broker")
	reg.SetLA("broker", "sess-la-3", "la-tok")

	// Pin clock so debounce doesn't coalesce.
	fixed := time.Date(2026, 6, 10, 0, 0, 0, 0, time.UTC)
	orig := pushNow
	pushNow = func() time.Time { return fixed }
	defer func() { pushNow = orig }()

	s.maybeNotifyTurnEnd()

	// Alert notification must fire (no subscribers).
	if alertN.count() != 1 {
		t.Fatalf("alert notification count = %d, want 1", alertN.count())
	}
}

// TestLAEmit_ContentStateKeys verifies content_state has all required fields
// after SetLACurrentTool + notifyLATurnEnd.
func TestLAEmit_ContentStateKeys(t *testing.T) {
	s, reg, sender := newBareSessionWithLA("sess-la-4")
	reg.SetLA("broker", "sess-la-4", "la-tok-xyz")

	// Simulate a tool use.
	// Pin time so turnStartedAt is deterministic.
	t0 := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	pushNow = func() time.Time { return t0 }
	defer func() { pushNow = time.Now }()

	// Tool change: debounce window prevents an immediate emit — reset lastLA.
	s.laState.mu.Lock()
	s.laState.lastLA = time.Time{} // clear so maybeEmitLAUpdate fires
	s.laState.mu.Unlock()
	s.SetLACurrentTool("Bash")

	if sender.count() < 1 {
		t.Fatal("expected at least one LA send after SetLACurrentTool")
	}
	p := sender.lastPayload()
	cs := p.ContentState
	if cs == nil {
		t.Fatal("content_state is nil")
	}
	if cs["currentTool"] != "Bash" {
		t.Errorf("currentTool = %v, want Bash", cs["currentTool"])
	}
	if cs["status"] != "running" {
		t.Errorf("status = %v, want running", cs["status"])
	}
	if v, ok := cs["startedAtMs"].(int64); !ok || v == 0 {
		t.Errorf("startedAtMs = %v (type %T), want non-zero int64", cs["startedAtMs"], cs["startedAtMs"])
	}
	if v, ok := cs["syncedAtMs"].(int64); !ok || v == 0 {
		t.Errorf("syncedAtMs = %v (type %T), want non-zero int64", cs["syncedAtMs"], cs["syncedAtMs"])
	}
}
