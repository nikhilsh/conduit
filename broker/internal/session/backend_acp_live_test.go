package session

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestACPLive drives the REAL `gemini --acp` binary end to end:
// initialize → session/new → a trivial prompt turn → assert one assistant
// bubble carrying the model's reply. It is skipped unless CONDUIT_ACP_LIVE=1
// (CI has no gemini binary or Google auth), so it only runs on a box where
// `gemini` is installed and signed in (~/.gemini/gemini-credentials.json).
// This is the integration proof behind the wire unit tests.
//
//	CONDUIT_ACP_LIVE=1 go test ./internal/session/ -run TestACPLive -v
func TestACPLive(t *testing.T) {
	if os.Getenv("CONDUIT_ACP_LIVE") != "1" {
		t.Skip("set CONDUIT_ACP_LIVE=1 to run against the real gemini --acp binary")
	}
	dir := t.TempDir()

	events := make(chan []byte, 64)
	publish := func(p []byte) {
		select {
		case events <- p:
		default:
		}
	}

	var latched string
	proc, err := newACPProcess(
		"gemini",
		dir,
		os.Environ(),
		SpawnOverride{},
		publish,
		func(usageDelta) {},
		"",
		func(id string) { latched = id },
	)
	if err != nil {
		t.Fatalf("newACPProcess: %v", err)
	}
	defer proc.Close()

	if latched == "" {
		t.Fatal("session id was never latched (onSession not fired)")
	}
	t.Logf("acp live: session %s, models=%d", latched, len(proc.modes))

	if err := proc.Send("Reply with exactly: The sky is blue."); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// Wait for the assistant bubble (the turn resolves on the prompt response).
	// A cold gemini first-turn in a fresh temp dir can take >60s to first token
	// (observed ~62s on the box), so the deadline is generous — still under the
	// backend's 2-minute silence watchdog. A system event (e.g. a quota /
	// provider error surfaced by failTurn) fails fast with the cause rather than
	// waiting out the deadline.
	deadline := time.After(170 * time.Second)
	var got string
	for got == "" {
		select {
		case p := <-events:
			role, content := chatEventRoleContent(p)
			switch role {
			case "assistant":
				if strings.TrimSpace(content) != "" {
					got = content
				}
			case "system":
				t.Fatalf("turn ended with a system notice (no assistant reply): %s", content)
			}
		case <-deadline:
			t.Fatal("no assistant reply within 170s")
		}
	}
	t.Logf("acp live: assistant reply = %q", got)
	if !strings.Contains(strings.ToLower(got), "sky is blue") {
		t.Fatalf("unexpected reply: %q", got)
	}
	if proc.TurnActive() {
		t.Fatal("turn still active after the reply")
	}
}

// TestACPCatalogProbeLive drives the real `gemini --acp` catalog probe and
// asserts it returns a non-empty model list. Skipped unless CONDUIT_ACP_LIVE=1.
//
//	CONDUIT_ACP_LIVE=1 go test ./internal/session/ -run TestACPCatalogProbeLive -v
func TestACPCatalogProbeLive(t *testing.T) {
	if os.Getenv("CONDUIT_ACP_LIVE") != "1" {
		t.Skip("set CONDUIT_ACP_LIVE=1 to run against the real gemini --acp binary")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	models, err := probeACPCatalog(ctx, "gemini", nil)
	if err != nil {
		t.Fatalf("probeACPCatalog: %v", err)
	}
	if len(models) == 0 {
		t.Fatal("catalog probe returned no models")
	}
	t.Logf("acp catalog: %d models (first=%s)", len(models), models[0].ID)
}
