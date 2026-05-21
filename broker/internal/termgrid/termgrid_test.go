package termgrid

import (
	"os/exec"
	"strings"
	"testing"
)

func TestSidecarRoundtrip(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not on PATH — skipping sidecar integration test")
	}
	m, err := NewManager()
	if err != nil {
		if err == ErrNoNode {
			t.Skip("node missing — skipping")
		}
		t.Fatalf("NewManager: %v", err)
	}
	t.Cleanup(func() { _ = m.Close() })

	if _, err := m.Ping(); err != nil {
		t.Fatalf("Ping: %v", err)
	}

	const sid = "test-session"
	if err := m.Create(sid, 24, 80); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := m.Write(sid, []byte("hello world\r\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	data, err := m.Serialize(sid)
	if err != nil {
		t.Fatalf("Serialize: %v", err)
	}
	if data == "" {
		t.Fatal("Serialize returned empty data after write")
	}
	if !strings.Contains(data, "hello world") {
		t.Fatalf("Serialize missing payload: %q", data)
	}

	// Resize to a different shape and verify it survives.
	if err := m.Resize(sid, 40, 120); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	data2, err := m.Serialize(sid)
	if err != nil {
		t.Fatalf("Serialize after resize: %v", err)
	}
	if !strings.Contains(data2, "hello world") {
		t.Fatalf("Serialize after resize lost payload: %q", data2)
	}

	if err := m.Delete(sid); err != nil {
		t.Fatalf("Delete: %v", err)
	}
}
