package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestConvLoggerRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conversation.jsonl")
	l := newConvLogger(path)

	l.appendUser("hello agent")
	// An assistant frame as it arrives from PublishText: the already-
	// encoded `event` payload, persisted verbatim.
	asst, _ := json.Marshal(ConvEntry{Role: "assistant", Content: "hi there", Ts: "2026-05-25T10:00:00Z"})
	l.appendRaw(asst)
	l.appendUser("do the thing")

	got, err := readConvLog(path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 entries, got %d (%+v)", len(got), got)
	}
	if got[0].Role != "user" || got[0].Content != "hello agent" {
		t.Errorf("entry0 = %+v", got[0])
	}
	if got[1].Role != "assistant" || got[1].Content != "hi there" {
		t.Errorf("entry1 = %+v", got[1])
	}
	if got[2].Role != "user" || got[2].Content != "do the thing" {
		t.Errorf("entry2 = %+v", got[2])
	}
}

func TestConvLoggerSkipsMalformedLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conversation.jsonl")
	// Valid, then a truncated line (simulating a crash mid-append), then
	// valid again — the reader must skip the bad line, not bail.
	content := `{"role":"user","content":"a","ts":"t"}` + "\n" +
		`{"role":"assistant","content":"b"` + "\n" +
		`{"role":"assistant","content":"c","ts":"t"}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readConvLog(path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 (skip malformed), got %d (%+v)", len(got), got)
	}
	if got[0].Content != "a" || got[1].Content != "c" {
		t.Errorf("got %+v", got)
	}
}

func TestConvLoggerNoopGuards(t *testing.T) {
	// nil logger + empty path + empty content must not panic and must
	// not create a file.
	var nilLogger *convLogger
	nilLogger.appendUser("x")
	nilLogger.appendRaw([]byte(`{}`))

	path := filepath.Join(t.TempDir(), "conversation.jsonl")
	l := newConvLogger(path)
	l.appendUser("")      // empty content → skipped
	l.appendRaw([]byte{}) // empty payload → skipped
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected no file created, stat err = %v", err)
	}
}

func TestReadConvLogMissingFile(t *testing.T) {
	if _, err := readConvLog(filepath.Join(t.TempDir(), "nope.jsonl")); err == nil {
		t.Fatal("want error for missing file")
	}
}

// TestConvLoggerSkipsPendingInputCards verifies that needs-input/approval
// cards (content prefixed with pendingInputSentinel) are NOT written to the
// durable transcript — they are transient live state that must not replay on
// session reopen. Normal chat events and resolution events must still persist.
func TestConvLoggerSkipsPendingInputCards(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conversation.jsonl")
	l := newConvLogger(path)

	// A normal assistant message — should persist.
	normal, _ := json.Marshal(ConvEntry{Role: "assistant", Content: "all good", Ts: "2026-06-12T00:00:00Z"})
	l.appendRaw(normal)

	// A needs-input card — should be skipped.
	card, _ := json.Marshal(ConvEntry{
		Role:    "assistant",
		Content: pendingInputSentinel + "\nShip it?\n1. Yes\n2. No",
		Ts:      "2026-06-12T00:01:00Z",
	})
	l.appendRaw(card)

	// A resolution/system message after the answer — should persist.
	resolution, _ := json.Marshal(ConvEntry{Role: "system", Content: "User answered: Yes", Ts: "2026-06-12T00:02:00Z"})
	l.appendRaw(resolution)

	got, err := readConvLog(path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 entries (card skipped), got %d: %+v", len(got), got)
	}
	if got[0].Content != "all good" {
		t.Errorf("entry0: want normal message, got content=%q", got[0].Content)
	}
	if got[1].Content != "User answered: Yes" {
		t.Errorf("entry1: want resolution message, got content=%q", got[1].Content)
	}
}
