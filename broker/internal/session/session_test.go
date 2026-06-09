package session

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// TestMain disables the Terminal-tab tmux backing for the entire session
// test package. Structured-chat sessions otherwise spawn a real
// `tmux new-session` on the shared tmux server (terminalShellArgv), and
// because tests tear their Manager down with Close() — not a per-session
// DeleteSession — those detached sessions leak past the test exactly as
// the stray `kitty-switch-chat` orphan did. Forcing the plain-bash
// fallback keeps `go test` from polluting the dev box's tmux server.
func TestMain(m *testing.M) {
	os.Setenv("CONDUIT_DISABLE_TERMINAL_TMUX", "1")
	os.Exit(m.Run())
}

func TestCheckpointPersistsSessionRails(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("checkpoint-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-checkpoint", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}

	waitForOutput(t, sess, "checkpoint-ready")
	if _, err := sess.Write([]byte("echo persisted\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "persisted")

	if err := sess.Checkpoint("manual"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	scrollback, err := os.ReadFile(filepath.Join(root, ".conduit", "sessions", sess.ID, "scrollback.bin"))
	if err != nil {
		t.Fatalf("ReadFile(scrollback): %v", err)
	}
	if !bytes.Contains(scrollback, []byte("persisted")) {
		t.Fatalf("scrollback missing persisted output: %q", string(scrollback))
	}

	memoryDoc, err := os.ReadFile(filepath.Join(root, ".conduit", "memory", "sessions", sess.ID+".html"))
	if err != nil {
		t.Fatalf("ReadFile(memory): %v", err)
	}
	if !bytes.Contains(memoryDoc, []byte("session-checkpoint")) {
		t.Fatalf("memory doc missing session id: %q", string(memoryDoc))
	}
}

func TestSwitchAdapterFallsBackToCheckpointAndKeepsSessionUsable(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": handoffTrapScript("claude-ready"),
		"codex":  idleScript("codex-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-switch", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "claude-ready")
	if err := sess.Checkpoint("before-switch"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	if err := sess.SwitchAdapter("codex"); err != nil {
		t.Fatalf("SwitchAdapter: %v", err)
	}
	waitForOutput(t, sess, "codex-ready")

	handoffDoc, err := os.ReadFile(filepath.Join(root, ".conduit", "sessions", sess.ID, "work", ".conduit", "HANDOFF.html"))
	if err != nil {
		t.Fatalf("ReadFile(HANDOFF): %v", err)
	}
	if !bytes.Contains(handoffDoc, []byte(`data-section="handoff"`)) {
		t.Fatalf("handoff file missing handoff section: %q", string(handoffDoc))
	}

	if _, err := sess.Write([]byte("echo switched\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "switched")
}

func TestWatchdogMarksWarningAndDead(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("watchdog-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-watchdog", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "watchdog-ready")

	sess.mu.Lock()
	sess.lastOutput = time.Now().Add(-time.Second)
	sess.mu.Unlock()
	sess.stallAfter = 20 * time.Millisecond
	sess.runWatchdogChecks()
	if got := sess.Status().Health; got != "warning" {
		t.Fatalf("expected warning health, got %q", got)
	}
	// Regression guard: a quiet-but-alive process is a HEALTH warning, not
	// a phase change. Phase must stay "running" so clients keep the session
	// live (a non-running phase mid-turn made the app composer read-only).
	if got := sess.Status().Phase; got != "running" {
		t.Fatalf("expected phase to stay running on a no_output warning, got %q", got)
	}
	if got := sess.Status().ReasonCode; got != "no_output" {
		t.Fatalf("expected reason no_output, got %q", got)
	}

	if sess.cmd == nil || sess.cmd.Process == nil {
		t.Fatal("session process missing")
	}
	_ = sess.cmd.Process.Kill()
	_, _ = sess.cmd.Process.Wait()
	sess.runWatchdogChecks()
	if got := sess.Status().Health; got != "dead" {
		t.Fatalf("expected dead health, got %q", got)
	}
}

// TestTUIScrapeChatPersistsBothSides proves the regression fix: on the
// legacy TUI-scrape path (adapter with no chat_mode → s.chat == nil),
// a chat exchange persists BOTH the user prompt and the assistant reply
// to conversation.jsonl, and ConversationLog reads them back in order.
//
// Before the fix, MarkUserChatSent only primed the scraper and never
// recorded the user side — so a reopened session showed "No saved
// transcript" (the file was never created when the first turn's reply
// hadn't been scraped yet) or a one-sided transcript (replies with no
// questions). The two calls driven here are exactly the ones the
// websocket chat handler + chat scraper make on a TUI-path turn:
//
//	user side:      Session.MarkUserChatSent(prompt)
//	assistant side: Session.PublishText(<view_event view:"chat">)
//
// PublishText with a chat frame is byte-for-byte what chatScraper.flush
// emits, so this exercises the real persistence seam without depending
// on PTY/ANSI scrape timing.
func TestTUIScrapeChatPersistsBothSides(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("scrape-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-scrape-chat", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	// No chat_mode → TUI-scrape path: the structured chat backend is
	// absent (s.chat == nil) and the scraper is active. This is the
	// configuration that produced the "No saved transcript" bug.
	if sess.chat != nil {
		t.Fatal("expected TUI-scrape path (s.chat == nil) for an adapter without chat_mode")
	}
	if sess.scraper == nil {
		t.Fatal("expected an active chat scraper on the TUI path")
	}
	waitForOutput(t, sess, "scrape-ready")

	// Turn 1: user prompt (recorded by the fix) then the scraped reply.
	sess.MarkUserChatSent("what is two plus two")
	sess.PublishText(scrapedAssistantFrame(t, "the answer is four"))
	// Turn 2: prove ordering across turns and that the user side of a
	// follow-up is captured too.
	sess.MarkUserChatSent("thanks, and three plus three?")
	sess.PublishText(scrapedAssistantFrame(t, "six"))

	entries, err := m.ConversationLog("session-scrape-chat")
	if err != nil {
		t.Fatalf("ConversationLog: %v", err)
	}
	want := []ConvEntry{
		{Role: "user", Content: "what is two plus two"},
		{Role: "assistant", Content: "the answer is four"},
		{Role: "user", Content: "thanks, and three plus three?"},
		{Role: "assistant", Content: "six"},
	}
	if len(entries) != len(want) {
		t.Fatalf("want %d entries, got %d (%+v)", len(want), len(entries), entries)
	}
	for i, w := range want {
		if entries[i].Role != w.Role || entries[i].Content != w.Content {
			t.Fatalf("entry %d = {%s %q}, want {%s %q}", i, entries[i].Role, entries[i].Content, w.Role, w.Content)
		}
	}
}

// scrapedAssistantFrame builds the exact view_event JSON envelope the
// chat scraper publishes for an assistant turn (and that PublishText
// persists via appendRaw).
func scrapedAssistantFrame(t *testing.T, content string) []byte {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    "assistant",
			"content": content,
			"ts":      time.Now().UTC().Format(time.RFC3339Nano),
			"files":   []any{},
		},
	})
	if err != nil {
		t.Fatalf("marshal frame: %v", err)
	}
	return payload
}

func TestManagerRecoverRestoresPersistedSnapshot(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("recover-ready"),
	})

	m1 := NewManager(reg)
	sess, _, err := m1.GetOrCreate("session-recover", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "recover-ready")
	if _, err := sess.Write([]byte("echo restore-me\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "restore-me")
	if err := sess.Checkpoint("recover"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	m1.Close()

	m2 := NewManager(reg)
	t.Cleanup(m2.Close)
	recovered, err := m2.Recover()
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if len(recovered) != 1 || recovered[0] != "session-recover" {
		t.Fatalf("unexpected recovered ids: %v", recovered)
	}
	// Lazy recovery: Recover() enumerates the session but must NOT spawn it
	// yet (eager respawn of every session at boot was a process storm that
	// wedged the host). It only becomes live when a client opens it.
	if _, ok := m2.Get("session-recover"); ok {
		t.Fatal("Recover must not eagerly spawn the session (lazy recovery)")
	}
	// On-demand open spawns + restores the persisted snapshot.
	sess2, _, err := m2.GetOrCreate("session-recover", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate (on-demand recover): %v", err)
	}
	if !bytes.Contains(sess2.Snapshot(), []byte("restore-me")) {
		t.Fatalf("snapshot missing restored output: %q", string(sess2.Snapshot()))
	}
}

// TestRecoverRestoresWorkspaceDir proves that a session created with a
// user-chosen CWD recovers to the same workspace dir after a simulated
// broker restart (manager close + re-open + Recover). Before the fix,
// requestedCWD was not persisted in meta.json so the recovered agent
// ran in the empty per-session work/ dir instead of the user's project.
func TestRecoverRestoresWorkspaceDir(t *testing.T) {
	root := testRoot(t)

	// A separate real directory the "user" chose as their project.
	projectDir := t.TempDir()

	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("cwd-ready"),
	})

	// Create session with an explicit CWD.
	m1 := NewManager(reg)
	sess, _, err := m1.GetOrCreateWithOptions("session-cwd", "claude", CreateOptions{CWD: projectDir})
	if err != nil {
		t.Fatalf("GetOrCreateWithOptions: %v", err)
	}
	waitForOutput(t, sess, "cwd-ready")
	if sess.WorkspaceDir() != projectDir {
		t.Fatalf("workspaceDir before persist = %q, want %q", sess.WorkspaceDir(), projectDir)
	}
	if err := sess.Checkpoint("cwd"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	m1.Close()

	// Simulate broker restart: new manager, recover sessions.
	m2 := NewManager(reg)
	t.Cleanup(m2.Close)
	recovered, err := m2.Recover()
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if len(recovered) != 1 || recovered[0] != "session-cwd" {
		t.Fatalf("unexpected recovered ids: %v", recovered)
	}
	// Lazy recovery: opening the session on demand restores its workspace dir.
	sess2, _, err := m2.GetOrCreate("session-cwd", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate (on-demand recover): %v", err)
	}
	if sess2.WorkspaceDir() != projectDir {
		t.Fatalf("workspaceDir after recover = %q, want %q", sess2.WorkspaceDir(), projectDir)
	}
}

// TestRecoverPreservesStartedAt proves a recovered session keeps its
// ORIGINAL creation timestamp instead of resetting to the recovery moment.
// Before the fix, startedAt was re-seeded to time.Now() on recovery, so
// every reattached/historic session reported "just now" ("2m ago" in the
// app) regardless of when it was really created.
func TestRecoverPreservesStartedAt(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("ts-ready"),
	})

	m1 := NewManager(reg)
	sess, _, err := m1.GetOrCreate("session-ts", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "ts-ready")

	// Pin a known, clearly-in-the-past creation time, then persist it.
	want := time.Now().UTC().Add(-72 * time.Hour).Truncate(time.Second)
	sess.mu.Lock()
	sess.startedAt = want
	sess.mu.Unlock()
	if err := sess.Checkpoint("ts"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	m1.Close()

	// Simulate broker restart and recover.
	m2 := NewManager(reg)
	t.Cleanup(m2.Close)
	if _, err := m2.Recover(); err != nil {
		t.Fatalf("Recover: %v", err)
	}
	sess2, _, err := m2.GetOrCreate("session-ts", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate (on-demand recover): %v", err)
	}
	got := sess2.Status().StartedAt.UTC().Truncate(time.Second)
	if !got.Equal(want) {
		t.Fatalf("recovered StartedAt = %v, want preserved %v (reset to ~now is the bug)", got, want)
	}
}

func testRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".conduit"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.conduit): %v", err)
	}
	t.Setenv("CONDUIT_ROOT", filepath.Join(root, ".conduit"))
	t.Setenv("CONDUIT_SESSION_CHECKPOINT_INTERVAL_MS", "1000")
	t.Setenv("CONDUIT_SESSION_WATCHDOG_INTERVAL_MS", "1000")
	t.Setenv("CONDUIT_SESSION_STALL_AFTER_MS", "1000")
	t.Setenv("CONDUIT_SESSION_HANDOFF_TIMEOUT_MS", "500")
	return root
}

func testRegistry(t *testing.T, root string, scripts map[string]string) *agents.Registry {
	t.Helper()
	dir := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatalf("MkdirAll(workspace): %v", err)
	}
	for name, script := range scripts {
		body := strings.Join([]string{
			`name = "` + name + `"`,
			`image = "conduit/` + name + `:latest"`,
			`command = ["sh"]`,
			`args = ["-lc", ` + quoteTOML(script) + `]`,
			`workdir = ` + quoteTOML(workspace),
		}, "\n")
		path := filepath.Join(dir, name+".toml")
		if err := os.WriteFile(path, []byte(body+"\n"), 0o644); err != nil {
			t.Fatalf("WriteFile(%s): %v", path, err)
		}
	}
	reg, err := agents.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	return reg
}

func waitForOutput(t *testing.T, sess *Session, want string) {
	t.Helper()
	if bytes.Contains(sess.Snapshot(), []byte(want)) {
		return
	}
	sub := sess.Subscribe()
	defer sess.Unsubscribe(sub)

	deadline := time.After(3 * time.Second)
	var out bytes.Buffer
	for {
		select {
		case chunk := <-sub:
			out.Write(chunk)
			if strings.Contains(out.String(), want) {
				return
			}
		case <-deadline:
			if bytes.Contains(sess.Snapshot(), []byte(want)) {
				return
			}
			t.Fatalf("timed out waiting for %q in %q", want, out.String())
		}
	}
}

func idleScript(ready string) string {
	return "echo " + ready + "; while :; do sleep 1; done"
}

func handoffTrapScript(ready string) string {
	return "trap 'cp \"$CONDUIT_HANDOFF_PATH\" \"$CONDUIT_HANDOFF_OUT_PATH\"; exit 0' USR1; echo " + ready + "; while :; do sleep 1; done"
}

func quoteTOML(v string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `"`, `\"`) + `"`
}
