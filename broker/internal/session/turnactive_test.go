package session

import "testing"

// turnBackend is a chatBackend stub with a controllable TurnActive, used to
// pin that Session.TurnActive() reflects the backend (and is false when
// there is no structured backend at all — the legacy TUI-scrape path).
type turnBackend struct{ active bool }

func (b *turnBackend) Send(string) error { return nil }
func (b *turnBackend) Interrupt() error  { return nil }
func (b *turnBackend) Close() error      { return nil }
func (b *turnBackend) TurnActive() bool  { return b.active }

func TestSessionTurnActive(t *testing.T) {
	s := &Session{}
	if s.TurnActive() {
		t.Fatal("nil chat backend (TUI-scrape path) must report turn not active")
	}
	s.chat = &turnBackend{active: true}
	if !s.TurnActive() {
		t.Fatal("TurnActive must reflect a backend reporting an in-flight turn")
	}
	s.chat = &turnBackend{active: false}
	if s.TurnActive() {
		t.Fatal("TurnActive must reflect a backend reporting an idle turn")
	}
}

// TestClaudeChatProcessTurnLatch pins the claude latch transitions:
// Send marks the turn active, the stream-pump callback / Close clear it.
func TestClaudeChatProcessTurnLatch(t *testing.T) {
	c := &chatProcess{}
	if c.TurnActive() {
		t.Fatal("fresh chat process must not be mid-turn")
	}
	c.markTurnActive(true)
	if !c.TurnActive() {
		t.Fatal("markTurnActive(true) must latch the turn")
	}
	// The stream pump clears it on the turn-end `result` envelope.
	c.markTurnActive(false)
	if c.TurnActive() {
		t.Fatal("markTurnActive(false) must clear the turn latch")
	}
}
