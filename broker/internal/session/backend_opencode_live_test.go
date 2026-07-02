package session

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// resolveOpencodeBinary finds the opencode launcher for the live tests: $PATH
// first, then the documented user-space install prefix
// (~/.opencode-install/bin/opencode). Returns "" when absent.
func resolveOpencodeBinary() string {
	if p, err := exec.LookPath("opencode"); err == nil {
		return p
	}
	if home, err := os.UserHomeDir(); err == nil {
		p := filepath.Join(home, ".opencode-install", "bin", "opencode")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// TestOpencodeLiveTEMP drives the REAL `opencode serve` binary end to end via
// the built-in no-auth "OpenCode Zen" free provider: spawn → create session →
// one real turn → catalog probe → interrupt-safe Close. Committed (per WS-4.2)
// but skipped when the binary is absent or under -short, so CI (no binary)
// stays green and the dev box can prove the integration:
//
//	go test ./internal/session/ -run TestOpencodeLiveTEMP -v
func TestOpencodeLiveTEMP(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping live opencode test under -short")
	}
	bin := resolveOpencodeBinary()
	if bin == "" {
		t.Skip("opencode binary not found (install per docs/OPENCODE-PROTOCOL.md); skipping live test")
	}

	// Per-test ephemeral HOME so the global opencode DB/config lands in a temp
	// dir (the same isolation the broker gives each session via agentHomeDir).
	home := t.TempDir()
	env := append(os.Environ(), "HOME="+home, "XDG_DATA_HOME="+filepath.Join(home, ".local", "share"), "XDG_CONFIG_HOME="+filepath.Join(home, ".config"))

	events := make(chan []byte, 128)
	sessions := make(chan string, 4)
	proc, err := newOpencodeServerProcess(
		bin,
		[]string{"serve", "--hostname", "127.0.0.1"},
		home,
		env,
		func(p []byte) { events <- p },
		"",
		func(id string) { sessions <- id },
	)
	if err != nil {
		t.Fatalf("spawn opencode serve: %v", err)
	}
	defer proc.Close()

	select {
	case id := <-sessions:
		t.Logf("latched session id: %s", id)
	case <-time.After(35 * time.Second):
		t.Fatal("timeout waiting for session id latch")
	}

	// One real turn against the free zen provider's default model.
	if err := proc.Send("reply with exactly: PONG"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	deadline := time.After(90 * time.Second)
	var answer string
	for answer == "" {
		select {
		case p := <-events:
			if role, content := chatEventRoleContent(p); role == "assistant" {
				answer = content
			}
		case <-deadline:
			t.Fatal("timeout waiting for a real assistant turn")
		}
	}
	t.Logf("assistant answer: %q", answer)
	if answer == "" {
		t.Fatal("empty assistant answer")
	}

	// Catalog probe against the real binary.
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	models, err := probeOpencodeCatalog(ctx, bin, nil)
	if err != nil {
		t.Fatalf("catalog probe: %v", err)
	}
	if len(models) == 0 {
		t.Fatal("catalog probe returned no models")
	}
	t.Logf("catalog: %d models, first=%s", len(models), models[0].ID)
}
