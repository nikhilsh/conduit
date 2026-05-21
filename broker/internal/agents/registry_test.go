package agents

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadDirAndLookup(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
image = "swekitty/claude:latest"
command = ["sh"]
args = ["-lc", "exec sh"]
workdir = "/workspace"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	adapter, err := reg.Get("claude")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if adapter.Name != "claude" || adapter.Image == "" || len(adapter.Command) == 0 {
		t.Fatalf("unexpected adapter: %+v", adapter)
	}
}

func TestLoadDirRejectsInvalidAdapter(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "bad.toml", `
name = "claude"
image = ""
command = ["sh"]
workdir = "/workspace"
`)
	_, err := LoadDir(dir)
	if err == nil || !strings.Contains(err.Error(), "image is required") {
		t.Fatalf("expected image validation error, got %v", err)
	}
}

func TestGetRejectsUnknownAssistant(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
image = "swekitty/claude:latest"
command = ["sh"]
workdir = "/workspace"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	_, err = reg.Get("codex")
	if err == nil || !strings.Contains(err.Error(), `unknown assistant "codex"`) {
		t.Fatalf("expected unknown assistant error, got %v", err)
	}
}

func writeAdapter(t *testing.T, dir, name, body string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(strings.TrimSpace(body)+"\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}
