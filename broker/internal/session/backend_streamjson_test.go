package session

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// --- Change 3 tests: subscriber gate for quick-reply kickoff ---

// fakeCompletionGen is a minimal aiGenProvider that signals when Complete is
// entered, for use in kickoff gating tests.
type fakeCompletionGen struct {
	entered chan struct{}
	result  string
}

func (f *fakeCompletionGen) Complete(_ context.Context, _, _ string, _ int) (string, error) {
	select {
	case f.entered <- struct{}{}:
	default:
	}
	return f.result, nil
}

var _ aiGenProvider = (*fakeCompletionGen)(nil)

// TestQuickReplyKickoffSkipsWhenNoSubscribers verifies that kickoff does NOT
// fire generation when subscriberCount returns 0.
func TestQuickReplyKickoffSkipsWhenNoSubscribers(t *testing.T) {
	entered := make(chan struct{}, 1)
	gen := &quickReplyGenerator{
		sessionID:       "sess-zero",
		publish:         func([]byte) {},
		gen:             &fakeCompletionGen{entered: entered, result: "[]"},
		subscriberCount: func() int { return 0 },
	}

	gen.kickoff("some assistant text", "msg-1")
	// Give any stray goroutine time to run.
	time.Sleep(30 * time.Millisecond)

	select {
	case <-entered:
		t.Fatal("kickoff fired generation when subscriber count == 0; expected skip")
	default:
		// Correct: nothing fired.
	}
}

// TestQuickReplyKickoffFiresWhenSubscriberPresent verifies that kickoff DOES
// fire generation when subscriberCount returns 1.
func TestQuickReplyKickoffFiresWhenSubscriberPresent(t *testing.T) {
	entered := make(chan struct{}, 1)
	gen := &quickReplyGenerator{
		sessionID:       "sess-one",
		publish:         func([]byte) {},
		gen:             &fakeCompletionGen{entered: entered, result: `["Yes","No"]`},
		subscriberCount: func() int { return 1 },
	}

	gen.kickoff("What should we do next?", "msg-2")

	select {
	case <-entered:
		// Correct: generation was started.
	case <-time.After(2 * time.Second):
		t.Fatal("kickoff did not start generation goroutine when subscriber count == 1")
	}
}

// TestQuickReplyKickoffNilSubscriberCountAlwaysFires verifies that when
// subscriberCount is nil (legacy/unwired path), kickoff always fires.
func TestQuickReplyKickoffNilSubscriberCountAlwaysFires(t *testing.T) {
	entered := make(chan struct{}, 1)
	gen := &quickReplyGenerator{
		sessionID:       "sess-nil-count",
		publish:         func([]byte) {},
		gen:             &fakeCompletionGen{entered: entered, result: `["Go"]`},
		subscriberCount: nil, // unwired
	}

	gen.kickoff("Ready?", "msg-3")

	select {
	case <-entered:
		// Correct: nil gate always fires.
	case <-time.After(2 * time.Second):
		t.Fatal("kickoff did not fire when subscriberCount is nil")
	}
}

// --- Change 4 tests: phaseRateLimiter ---

// TestPhaseRateLimiterImmediate verifies that immediate() always broadcasts
// synchronously and cancels any pending timer.
func TestPhaseRateLimiterImmediate(t *testing.T) {
	var count atomic.Int32
	prl := newPhaseRateLimiter(func() { count.Add(1) })

	prl.immediate()
	if count.Load() != 1 {
		t.Fatalf("immediate: count = %d, want 1", count.Load())
	}

	prl.immediate()
	if count.Load() != 2 {
		t.Fatalf("immediate x2: count = %d, want 2", count.Load())
	}
}

// TestPhaseRateLimiterScheduleFirstCallImmediate verifies that the first
// schedule() call (no prior broadcast) fires immediately.
func TestPhaseRateLimiterScheduleFirstCallImmediate(t *testing.T) {
	var count atomic.Int32
	prl := newPhaseRateLimiter(func() { count.Add(1) })

	prl.schedule()
	if count.Load() != 1 {
		t.Fatalf("first schedule: count = %d, want 1 (immediate beyond window)", count.Load())
	}
}

// TestPhaseRateLimiterScheduleCoalescesRapidCalls verifies that multiple
// rapid schedule() calls within the 1-second window produce exactly one
// trailing-edge broadcast (the FINAL state always lands).
func TestPhaseRateLimiterScheduleCoalescesRapidCalls(t *testing.T) {
	var count atomic.Int32
	prl := newPhaseRateLimiter(func() { count.Add(1) })

	// First call fires immediately (outside window).
	prl.schedule()
	if count.Load() != 1 {
		t.Fatalf("first schedule: count = %d, want 1", count.Load())
	}

	// Rapid follow-up calls within the window: coalesced into one timer.
	prl.schedule()
	prl.schedule()
	prl.schedule()

	// Count still 1 right after the rapid calls (not yet broadcast).
	if count.Load() != 1 {
		t.Fatalf("rapid calls: count = %d, want 1 (timer pending)", count.Load())
	}

	// Wait for the trailing-edge timer (fires within 1s + small slack).
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if count.Load() >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if count.Load() < 2 {
		t.Fatalf("trailing-edge timer did not fire within 1.2s: count = %d", count.Load())
	}
	if count.Load() > 2 {
		t.Fatalf("over-broadcast: count = %d, want exactly 2", count.Load())
	}
}

// TestPhaseRateLimiterImmediateCancelsPending verifies that an immediate()
// call while a trailing-edge timer is pending cancels the timer, so the
// turn-end broadcast is not followed by a stale intermediate broadcast.
func TestPhaseRateLimiterImmediateCancelsPending(t *testing.T) {
	var count atomic.Int32
	prl := newPhaseRateLimiter(func() { count.Add(1) })

	// First schedule: immediate (outside window).
	prl.schedule()
	if count.Load() != 1 {
		t.Fatalf("setup: count = %d, want 1", count.Load())
	}

	// Second schedule: within window, arms a trailing-edge timer.
	prl.schedule()

	// immediate() fires synchronously AND cancels the pending timer.
	prl.immediate()
	if count.Load() != 2 {
		t.Fatalf("after immediate: count = %d, want 2", count.Load())
	}

	// Wait past the timer window: count must stay at 2 (timer was cancelled).
	time.Sleep(1200 * time.Millisecond)
	if count.Load() != 2 {
		t.Fatalf("stale timer fired after immediate() cancelled it: count = %d, want 2", count.Load())
	}
}
