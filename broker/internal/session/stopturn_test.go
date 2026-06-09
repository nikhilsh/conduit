package session

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// TestCodexInterruptedTurnEndsQuietly: once a turn is Stopped (Interrupt sent),
// whichever terminus ends it — including a racing thread `idle` status that
// routes through endTurn — must be SILENT (no "no reply"/error notice). The
// "Stopped." line is published separately by InterruptTurn.
func TestCodexInterruptedTurnEndsQuietly(t *testing.T) {
	var published [][]byte
	c := &codexAppServerProcess{
		stdin:     bufWriteCloser{&bytes.Buffer{}},
		publish:   func(b []byte) { published = append(published, b) },
		threadID:  "t-1",
		stderrBuf: bytes.NewBufferString("2026-06-09T01:21:54Z ERROR codex_app_server: project not trusted\n"),
	}
	c.turnActive = true
	c.turnID = "turn-1"
	if err := c.Interrupt(); err != nil {
		t.Fatalf("interrupt: %v", err)
	}
	// Racing `idle` thread-status terminus (endTurn, not endTurnQuiet).
	c.endTurn()
	if len(published) != 0 {
		t.Fatalf("a Stopped turn must end silently, but published: %s", published)
	}
}

// TestCodexEndTurnExcludesStartupStderr: a turn that ends with no reply must NOT
// surface stale startup stderr (codex's benign "project not trusted" launch
// line) — only stderr written during the turn counts. Pins the device report of
// recurring identical-timestamp "codex error" lines.
func TestCodexEndTurnExcludesStartupStderr(t *testing.T) {
	startup := "2026-06-09T01:21:54.828789Z ERROR codex_app_server: Project-local config disabled until trusted\n"
	buf := bytes.NewBufferString(startup)
	var published [][]byte
	c := &codexAppServerProcess{
		publish:   func(b []byte) { published = append(published, b) },
		stderrBuf: buf,
	}

	// Case A: turn starts after the startup line, produces no new stderr → a
	// generic no-reply notice, never the stale startup line.
	c.turnActive = true
	c.published = false
	c.turnStderrOffset = buf.Len()
	c.endTurn()
	if len(published) != 1 {
		t.Fatalf("expected one notice, got %d", len(published))
	}
	if s := string(published[0]); strings.Contains(s, "trusted") || !strings.Contains(s, "no reply") {
		t.Fatalf("must surface the generic no-reply notice, not stale startup stderr: %s", s)
	}

	// Case B: a real error DURING the turn (after the offset) IS surfaced.
	offset := buf.Len()
	buf.WriteString("2026-06-09T02:00:00Z ERROR codex_core: model request failed\n")
	c.turnActive = true
	c.published = false
	c.turnStderrOffset = offset
	c.endTurn()
	if s := string(published[len(published)-1]); !strings.Contains(s, "model request failed") {
		t.Fatalf("a turn-time error must be surfaced: %s", s)
	}
}

// TestInterruptTurnPublishesStoppedNote: InterruptTurn must publish a role-
// "system" chat view_event so the client's typing indicator (and the composer
// Stop button) clear — stopping mid-think otherwise leaves the user's prompt as
// the last item, which the apps read as "agent still working" forever.
func TestInterruptTurnPublishesStoppedNote(t *testing.T) {
	s := &Session{
		ID:       "stop-note",
		convLog:  newConvLogger(filepath.Join(t.TempDir(), "conversation.jsonl")),
		textSubs: map[chan []byte]struct{}{},
	}
	s.chat = &fakeChatBackend{}
	sub := s.SubscribeText()
	defer s.UnsubscribeText(sub)

	if !s.InterruptTurn() {
		t.Fatal("InterruptTurn returned false with a backend present")
	}

	select {
	case frame := <-sub:
		var env struct {
			Type  string `json:"type"`
			View  string `json:"view"`
			Event struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"event"`
		}
		if err := json.Unmarshal(frame, &env); err != nil {
			t.Fatalf("unmarshal published frame: %v", err)
		}
		if env.Type != "view_event" || env.View != "chat" || env.Event.Role != "system" {
			t.Fatalf("expected a system chat view_event, got: %s", frame)
		}
		if env.Event.Content == "" {
			t.Fatalf("stopped note must carry content: %s", frame)
		}
	default:
		t.Fatal("InterruptTurn published no frame")
	}
}

// TestEncodeControlInterrupt pins the claude Stop-button wire format: a
// stream-json control_request with subtype "interrupt" and a unique request_id,
// newline-terminated. Captured live against claude-code 2.1.168.
func TestEncodeControlInterrupt(t *testing.T) {
	line := encodeControlInterrupt()
	if len(line) == 0 || line[len(line)-1] != '\n' {
		t.Fatalf("interrupt line must be non-empty + newline-terminated: %q", line)
	}
	var env struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
		Request   struct {
			Subtype string `json:"subtype"`
		} `json:"request"`
	}
	if err := json.Unmarshal(line, &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Type != "control_request" || env.Request.Subtype != "interrupt" {
		t.Fatalf("bad interrupt envelope: %s", line)
	}
	if env.RequestID == "" {
		t.Fatal("interrupt must carry a request_id")
	}
	// request_id must be unique per call (the CLI echoes it in the response).
	var env2 struct {
		RequestID string `json:"request_id"`
	}
	_ = json.Unmarshal(encodeControlInterrupt(), &env2)
	if env2.RequestID == env.RequestID {
		t.Fatalf("request_id must be unique across calls: %s", env.RequestID)
	}
}

// TestCodexStartedTurnID pins extraction of the turn id from a turn/started
// notification (needed to target turn/interrupt).
func TestCodexStartedTurnID(t *testing.T) {
	if got := codexStartedTurnID(json.RawMessage(`{"threadId":"t-1","turn":{"id":"turn-9","status":"running"}}`)); got != "turn-9" {
		t.Fatalf("turn id = %q", got)
	}
	for _, bad := range []string{`{}`, `{"turn":{}}`, `not json`} {
		if got := codexStartedTurnID(json.RawMessage(bad)); got != "" {
			t.Fatalf("expected empty for %q, got %q", bad, got)
		}
	}
}

type bufWriteCloser struct{ b *bytes.Buffer }

func (w bufWriteCloser) Write(p []byte) (int, error) { return w.b.Write(p) }
func (w bufWriteCloser) Close() error                { return nil }

// TestCodexInterruptSendsTurnInterrupt: with a latched turn, Interrupt writes
// turn/interrupt{threadId,turnId}; with no turn in flight it writes nothing.
func TestCodexInterruptSendsTurnInterrupt(t *testing.T) {
	buf := &bytes.Buffer{}
	c := &codexAppServerProcess{stdin: bufWriteCloser{buf}, inited: true, threadID: "t-1"}

	// No turn in flight → no-op, no bytes written.
	if err := c.Interrupt(); err != nil {
		t.Fatalf("no-op interrupt: %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("interrupt with no turn must write nothing, got: %s", buf.String())
	}

	// Latch a turn id via the notification path, then interrupt.
	c.turnActive = true
	c.handleNotification("turn/started", json.RawMessage(`{"threadId":"t-1","turn":{"id":"turn-7"}}`))
	if err := c.Interrupt(); err != nil {
		t.Fatalf("interrupt: %v", err)
	}
	out := buf.String()
	if !strings.Contains(out, `"method":"turn/interrupt"`) ||
		!strings.Contains(out, `"turnId":"turn-7"`) ||
		!strings.Contains(out, `"threadId":"t-1"`) {
		t.Fatalf("turn/interrupt payload wrong: %s", out)
	}

	// After the turn ends, the turn id is cleared so a stale interrupt no-ops.
	c.endTurnQuiet()
	buf.Reset()
	if err := c.Interrupt(); err != nil {
		t.Fatalf("post-end interrupt: %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("interrupt after turn end must write nothing, got: %s", buf.String())
	}
}
