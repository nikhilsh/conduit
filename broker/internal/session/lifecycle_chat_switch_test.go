package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// Switching agents must re-point the structured chat backend at the NEW
// adapter (task: switch-chat-integration). Pre-fix, switchToAdapter
// restarted only the PTY: s.chat kept driving the OLD agent's binary and
// the respawn closure re-spawned the old adapter forever.
//
// Uses codex-mode adapters because that backend constructs lazily (no
// subprocess until the first Send), so the test exercises the dispatch
// without spawning agents.
func TestSwitchRepointsChatBackend(t *testing.T) {
	root := testRoot(t)
	dir := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	// Distinct REAL executables (the switch spawns the new adapter's
	// PTY) so the rebuilt backend is distinguishable by binary.
	bins := map[string]string{"codex": "sh", "claude": "bash"}
	for _, name := range []string{"codex", "claude"} {
		body := strings.Join([]string{
			`name = "` + name + `"`,
			`image = "conduit/` + name + `:latest"`,
			`command = ["` + bins[name] + `"]`,
			`args = ["-lc", "sleep 60"]`,
			`workdir = ` + quoteTOML(workspace),
			`chat_mode = "codex-exec"`,
		}, "\n")
		if err := os.WriteFile(filepath.Join(dir, name+".toml"), []byte(body+"\n"), 0o644); err != nil {
			t.Fatalf("write toml: %v", err)
		}
	}
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatalf("MkdirAll(workspace): %v", err)
	}
	reg, err := agents.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("switch-chat", "codex")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	before, ok := sess.chat.(*codexChatProcess)
	if !ok || before == nil {
		t.Fatalf("expected codex chat backend at create, got %T", sess.chat)
	}
	if before.binary != "sh" {
		t.Fatalf("create backend binary = %q", before.binary)
	}
	// Simulate an established thread so the seed survives the switch round trip.
	sess.latchCodexThreadID("thread-original")

	target, err := reg.Get("claude")
	if err != nil {
		t.Fatalf("registry Get: %v", err)
	}
	if err := sess.Switch(target); err != nil {
		t.Fatalf("Switch: %v", err)
	}

	after, ok := sess.chat.(*codexChatProcess)
	if !ok || after == nil {
		t.Fatalf("expected chat backend after switch, got %T", sess.chat)
	}
	if after == before {
		t.Fatal("switch must rebuild the chat backend, not keep the old one")
	}
	if after.binary != "bash" {
		t.Fatalf("switched backend binary = %q (still driving the old agent)", after.binary)
	}
	// The persisted thread id rides through so switching BACK resumes it.
	if after.threadID != "thread-original" {
		t.Fatalf("thread seed lost across switch: %q", after.threadID)
	}
}
