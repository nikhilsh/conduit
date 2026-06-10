package session

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/push"
)

// pushNotifyState is the per-session push-notification state:
// the notifier, the identity to notify under, and a debounce latch
// so rapid idle-transitions don't flood the device.
type pushNotifyState struct {
	mu       sync.Mutex
	notifier push.Notifier
	identity string
	// lastIdle records when the session last transitioned to idle. Used to
	// ensure at most one push per idle-transition: a turn that completes and
	// immediately starts another turn should not deliver two pushes.
	lastIdle time.Time
	// lastInput records when we last fired a pending-input push, for the
	// same coalescing reason.
	lastInput time.Time
}

// idlePushWindow is the minimum time between two consecutive turn-end pushes
// for the same session. A second turn that completes within this window after
// the first is coalesced into silence (the user either saw the first push or
// opened the session and is watching). 2 s covers rapid tool-loop completions
// without missing genuine idle states separated by real user think-time.
const idlePushWindow = 2 * time.Second

// SetPushNotifier wires the push notifier and the single-operator identity
// bucket into the session's notification state. Called by the Manager
// immediately after session creation. nil notifier is accepted and silently
// no-ops all notification attempts.
func (s *Session) SetPushNotifier(n push.Notifier, identity string) {
	s.pushState.mu.Lock()
	s.pushState.notifier = n
	s.pushState.identity = identity
	s.pushState.mu.Unlock()
}

// maybeNotifyTurnEnd fires a push notification when a turn just completed
// AND no client is currently attached to this session (subscriber count == 0).
// It debounces: at most one push per idlePushWindow per session. Safe for
// concurrent callers (the accumulateUsage / onTurnEnd sites may race with
// a re-attaching client).
func (s *Session) maybeNotifyTurnEnd() {
	if s.SubscriberCount() > 0 {
		return // someone is watching — don't notify
	}
	s.pushState.mu.Lock()
	n := s.pushState.notifier
	id := s.pushState.identity
	if n == nil || id == "" {
		s.pushState.mu.Unlock()
		return
	}
	now := pushNow()
	if now.Sub(s.pushState.lastIdle) < idlePushWindow {
		// Within the debounce window — coalesce.
		s.pushState.mu.Unlock()
		return
	}
	s.pushState.lastIdle = now
	s.pushState.mu.Unlock()

	name := s.displayOrAssistant()
	payload := push.Payload{
		Title:     name,
		Body:      "Turn finished",
		SessionID: s.ID,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := n.Notify(ctx, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: turn-end notify session=%s: %v\n", s.ID, err)
	}
}

// maybeNotifyPendingInput fires a push notification when the agent is now
// blocked on an AskUserQuestion and no client is currently attached.
// Uses a separate debounce latch from turn-end so a pending-input doesn't
// suppress a subsequent turn-end push or vice-versa.
func (s *Session) maybeNotifyPendingInput() {
	if s.SubscriberCount() > 0 {
		return
	}
	s.pushState.mu.Lock()
	n := s.pushState.notifier
	id := s.pushState.identity
	if n == nil || id == "" {
		s.pushState.mu.Unlock()
		return
	}
	now := pushNow()
	if now.Sub(s.pushState.lastInput) < idlePushWindow {
		s.pushState.mu.Unlock()
		return
	}
	s.pushState.lastInput = now
	s.pushState.mu.Unlock()

	name := s.displayOrAssistant()
	payload := push.Payload{
		Title:     name,
		Body:      "Needs your input",
		SessionID: s.ID,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := n.Notify(ctx, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: pending-input notify session=%s: %v\n", s.ID, err)
	}
}

// displayOrAssistant returns the best human-readable label for the session
// (manual display name if set, otherwise the assistant name).
func (s *Session) displayOrAssistant() string {
	s.mu.Lock()
	name := s.displayName
	s.mu.Unlock()
	if name != "" {
		return name
	}
	return s.Assistant
}

// pushNow is the clock for push notification timestamps; overridable in tests.
var pushNow = time.Now
