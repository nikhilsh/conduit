package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// stubChatBackend is a chatBackend whose Send fails until "replaced".
type stubChatBackend struct {
	mu     sync.Mutex
	err    error
	sent   []string
	closed bool
}

func (c *stubChatBackend) Send(text string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return c.err
	}
	c.sent = append(c.sent, text)
	return nil
}

func (c *stubChatBackend) Interrupt() error { return nil }

func (c *stubChatBackend) TurnActive() bool { return false }

func (c *stubChatBackend) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	return nil
}

func testChatSession(t *testing.T) *Session {
	t.Helper()
	return &Session{
		ID:      "chat-heal",
		convLog: newConvLogger(filepath.Join(t.TempDir(), "conversation.jsonl")),
	}
}

// TestSendChatRespawnsDeadBackend: a send error on the long-lived chat
// process triggers one respawn + retry, so the message is delivered
// instead of silently dropped (the "connected but never replies" bug).
func TestSendChatRespawnsDeadBackend(t *testing.T) {
	s := testChatSession(t)
	dead := &stubChatBackend{err: errors.New("write |1: broken pipe")}
	fresh := &stubChatBackend{}
	s.chat = dead
	s.chatRespawn = func() (chatBackend, error) { return fresh, nil }

	if !s.SendChat("hello again") {
		t.Fatal("SendChat should report handled on the structured path")
	}
	if len(fresh.sent) != 1 || fresh.sent[0] != "hello again" {
		t.Fatalf("message not delivered to respawned backend: %v", fresh.sent)
	}
	if !dead.closed {
		t.Fatal("dead backend not closed after respawn")
	}
	if s.chat != chatBackend(fresh) {
		t.Fatal("session not switched to the respawned backend")
	}
}

// TestSendChatSurfacesDeliveryFailure: when respawn can't save the send,
// the failure must surface as a system chat event (persisted to the
// conversation log), not stderr-only silence.
func TestSendChatSurfacesDeliveryFailure(t *testing.T) {
	s := testChatSession(t)
	s.chat = &stubChatBackend{err: errChatProcessClosed}
	s.chatRespawn = func() (chatBackend, error) { return nil, errors.New("spawn: no such binary") }

	if !s.SendChat("anyone home?") {
		t.Fatal("SendChat should report handled on the structured path")
	}
	data, err := os.ReadFile(s.convLog.path)
	if err != nil {
		t.Fatalf("read conversation log: %v", err)
	}
	if !strings.Contains(string(data), "Couldn't deliver your message") {
		t.Fatalf("delivery failure not surfaced in conversation log:\n%s", data)
	}
}

// TestSendChatNoRespawnDuringClose: an intentional teardown must not
// resurrect the chat agent.
func TestSendChatNoRespawnDuringClose(t *testing.T) {
	s := testChatSession(t)
	s.chat = &stubChatBackend{err: errChatProcessClosed}
	s.closing = true
	respawned := false
	s.chatRespawn = func() (chatBackend, error) {
		respawned = true
		return &stubChatBackend{}, nil
	}

	s.SendChat("too late")
	if respawned {
		t.Fatal("chat agent respawned during session teardown")
	}
}
