package session

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testPeerChatSession(t *testing.T) (*Session, *stubChatBackend) {
	t.Helper()
	backend := &stubChatBackend{}
	s := &Session{
		ID:      "peer-recipient",
		convLog: newConvLogger(filepath.Join(t.TempDir(), "conversation.jsonl")),
		chat:    backend,
	}
	return s, backend
}

// TestSendPeerChatDeliversFramedMessage: the recipient's agent receives the
// framed block (labeled, attributed, with the reply hint), never the bare
// body — and the transcript records the same framed block as a user entry.
func TestSendPeerChatDeliversFramedMessage(t *testing.T) {
	s, backend := testPeerChatSession(t)
	if err := s.SendPeerChat("sender-1", "Fix Login Bug", "how far along is the auth refactor?"); err != nil {
		t.Fatalf("SendPeerChat: %v", err)
	}
	if len(backend.sent) != 1 {
		t.Fatalf("expected 1 delivered message, got %d", len(backend.sent))
	}
	got := backend.sent[0]
	for _, want := range []string{
		peerMessageBegin,
		peerMessageEnd,
		"From session: sender-1 (\"Fix Login Bug\")",
		"chat send sender-1",
		"how far along is the auth refactor?",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("delivered message missing %q:\n%s", want, got)
		}
	}

	entries, err := readConvLog(s.convLog.path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 transcript entry, got %d", len(entries))
	}
	if entries[0].Role != "user" {
		t.Errorf("transcript role = %q, want user", entries[0].Role)
	}
	if !strings.Contains(entries[0].Content, peerMessageBegin) {
		t.Errorf("transcript entry not framed: %s", entries[0].Content)
	}
}

// TestSendPeerChatNoBackend: a TUI-scrape session (no structured chat
// channel) rejects peer messages instead of silently dropping them.
func TestSendPeerChatNoBackend(t *testing.T) {
	s := &Session{
		ID:      "peer-tui",
		convLog: newConvLogger(filepath.Join(t.TempDir(), "conversation.jsonl")),
	}
	if err := s.SendPeerChat("sender-1", "", "hi"); err != ErrPeerChatUnsupported {
		t.Fatalf("expected ErrPeerChatUnsupported, got %v", err)
	}
}

// TestSendPeerChatRateLimit: the sliding-window cap rejects the message after
// peerChatRateMax within the window — the agent ping-pong loop guard.
func TestSendPeerChatRateLimit(t *testing.T) {
	s, backend := testPeerChatSession(t)
	for i := 0; i < peerChatRateMax; i++ {
		if err := s.SendPeerChat("sender-1", "", "msg"); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	if err := s.SendPeerChat("sender-1", "", "one too many"); err != ErrPeerChatRateLimited {
		t.Fatalf("expected ErrPeerChatRateLimited, got %v", err)
	}
	if len(backend.sent) != peerChatRateMax {
		t.Fatalf("rate-limited message must not reach the agent: got %d sends", len(backend.sent))
	}
}

// TestPeerRateCheckWindowExpires: sends older than the window free up slots.
func TestPeerRateCheckWindowExpires(t *testing.T) {
	s, _ := testPeerChatSession(t)
	base := time.Now()
	for i := 0; i < peerChatRateMax; i++ {
		if err := s.peerRateCheck(base); err != nil {
			t.Fatalf("fill %d: %v", i, err)
		}
	}
	if err := s.peerRateCheck(base); err != ErrPeerChatRateLimited {
		t.Fatalf("expected limit at capacity, got %v", err)
	}
	if err := s.peerRateCheck(base.Add(peerChatRateWindow + time.Second)); err != nil {
		t.Fatalf("expected slot after window expiry, got %v", err)
	}
}

// TestFramePeerMessageVariants: attribution renders for id+title, id-only,
// and anonymous callers; the reply hint appears only with a sender id.
func TestFramePeerMessageVariants(t *testing.T) {
	withTitle := framePeerMessage("abc", "My Task", "hello")
	if !strings.Contains(withTitle, `From session: abc ("My Task")`) {
		t.Errorf("id+title attribution missing:\n%s", withTitle)
	}
	idOnly := framePeerMessage("abc", "", "hello")
	if !strings.Contains(idOnly, "From session: abc\n") {
		t.Errorf("id-only attribution missing:\n%s", idOnly)
	}
	anon := framePeerMessage("", "", "hello")
	if !strings.Contains(anon, "unidentified caller") {
		t.Errorf("anonymous attribution missing:\n%s", anon)
	}
	if strings.Contains(anon, "chat send") {
		t.Errorf("anonymous frame must not carry a reply hint:\n%s", anon)
	}
}

// TestFramePeerMessageTruncates: an oversized body is bounded.
func TestFramePeerMessageTruncates(t *testing.T) {
	big := strings.Repeat("x", peerChatMaxBytes*2)
	framed := framePeerMessage("abc", "", big)
	if len(framed) > peerChatMaxBytes+1024 {
		t.Fatalf("framed message not bounded: %d bytes", len(framed))
	}
	if !strings.Contains(framed, "[truncated]") {
		t.Error("expected truncation marker")
	}
	if !strings.Contains(framed, peerMessageEnd) {
		t.Error("end label must survive truncation")
	}
}

// TestConduitAwarenessPromptMentionsPeerSessions: the awareness addendum
// teaches agents the peer-messaging affordance and the incoming label.
func TestConduitAwarenessPromptMentionsPeerSessions(t *testing.T) {
	prompt := conduitAwarenessPrompt()
	for _, want := range []string{"chat --list", "chat send <session-id>", "CONDUIT PEER MESSAGE", "$SESSION_UUID"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("awareness prompt missing %q", want)
		}
	}
}
