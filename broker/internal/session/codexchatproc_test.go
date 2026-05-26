package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodexTurnArgv(t *testing.T) {
	first := strings.Join(codexTurnArgv("codex", "/work", "", nil, "hi there"), " ")
	if first != "codex exec --json --skip-git-repo-check -C /work hi there" {
		t.Fatalf("first turn argv = %q", first)
	}
	resume := strings.Join(codexTurnArgv("codex", "/work", "t-9", nil, "more"), " ")
	if resume != "codex exec resume t-9 --json --skip-git-repo-check more" {
		t.Fatalf("resume argv = %q", resume)
	}
	// With a reasoning-effort override the flags land between the
	// subcommand and the message on both the first and resume turns.
	override := SpawnOverride{ReasoningEffort: "high"}.extraArgsFor("codex")
	withEffort := strings.Join(codexTurnArgv("codex", "/work", "", override, "go"), " ")
	if withEffort != `codex exec --json --skip-git-repo-check -C /work -c model_reasoning_effort=high go` {
		t.Fatalf("first turn argv with effort = %q", withEffort)
	}
	resumeEffort := strings.Join(codexTurnArgv("codex", "/work", "t-9", override, "go"), " ")
	if resumeEffort != `codex exec resume t-9 --json --skip-git-repo-check -c model_reasoning_effort=high go` {
		t.Fatalf("resume argv with effort = %q", resumeEffort)
	}
}

// TestCodexChatProcessRoundTrip uses a fake "codex" binary emitting canned
// JSONL to prove the per-turn subprocess → parseCodexStreamLine → publish
// path delivers a clean chat event and captures the resume thread id.
func TestCodexChatProcessRoundTrip(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	script := "#!/usr/bin/env bash\n" +
		`printf '%s\n' ` +
		`'{"type":"thread.started","thread_id":"t-1"}' ` +
		`'{"type":"item.completed","item":{"type":"agent_message","text":"hi back"}}' ` +
		`'{"type":"turn.completed"}'` + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake codex: %v", err)
	}

	events := make(chan []byte, 8)
	cp := newCodexChatProcess(fake, dir, nil, nil, func(p []byte) { events <- p })
	defer cp.Close()

	if err := cp.Send("hi"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	select {
	case p := <-events:
		var ev struct {
			View  string `json:"view"`
			Event struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"event"`
		}
		if err := json.Unmarshal(p, &ev); err != nil {
			t.Fatalf("payload not json: %v", err)
		}
		if ev.View != "chat" || ev.Event.Role != "assistant" || ev.Event.Content != "hi back" {
			t.Fatalf("unexpected chat event: %s", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for codex chat event")
	}

	// thread_id should be captured for the next turn's resume.
	deadline := time.Now().Add(2 * time.Second)
	for {
		cp.mu.Lock()
		tid := cp.threadID
		cp.mu.Unlock()
		if tid == "t-1" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("thread_id not captured, got %q", tid)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestCodexChatProcessSendAfterClose(t *testing.T) {
	cp := newCodexChatProcess("true", t.TempDir(), nil, nil, func([]byte) {})
	if err := cp.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := cp.Send("x"); err != errChatProcessClosed {
		t.Fatalf("Send after Close: got %v, want errChatProcessClosed", err)
	}
}
