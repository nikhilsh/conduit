package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

func writeHandoffFakeAgents(t *testing.T, dir string) (agents.Adapter, agents.Adapter) {
	t.Helper()
	claudeBin := filepath.Join(dir, "claude")
	claudeScript := `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_AGENT_LOG/claude.argv"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-thread"}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$FAKE_AGENT_LOG/claude.requests"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"claude ok"}]}}'
  printf '%s\n' '{"type":"result","subtype":"success","result":"claude ok","is_error":false}'
done
`
	if err := os.WriteFile(claudeBin, []byte(claudeScript), 0o755); err != nil {
		t.Fatal(err)
	}

	codexBin := filepath.Join(dir, "codex")
	codexScript := `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_AGENT_LOG/codex.argv"
if [[ "$1" != "app-server" ]]; then
  while :; do sleep 60; done
fi
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$FAKE_AGENT_LOG/codex.requests"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"initialize"'*)
      printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id"
      ;;
    *'"thread/start"'*|*'"thread/resume"'*)
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"codex-thread"}}}'
      printf '{"id":%s,"result":{"thread":{"id":"codex-thread"}}}\n' "$id"
      ;;
    *'"turn/start"'*)
      printf '{"id":%s,"result":{"turn":{"id":"turn-fake"}}}\n' "$id"
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"codex-thread","turn":{"id":"turn-fake"}}}'
      printf '%s\n' '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m1","text":""},"threadId":"codex-thread"}}'
      printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"codex ok"},"threadId":"codex-thread"}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"codex-thread","turn":{"id":"turn-fake","status":"completed"}}}'
      ;;
  esac
done
`
	if err := os.WriteFile(codexBin, []byte(codexScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return agents.Adapter{
			Name: "claude", Command: []string{claudeBin}, Protocol: "stream-json",
		}, agents.Adapter{
			Name: "codex", Command: []string{codexBin}, Protocol: "codex-app-server",
		}
}

func waitTurnIdle(t *testing.T, s *Session) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !s.TurnActive() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("turn did not become idle")
}

func TestProductionShapedClaudeCodexRoundTrips(t *testing.T) {
	for _, initial := range []string{"claude", "codex"} {
		t.Run(initial, func(t *testing.T) {
			root := t.TempDir()
			logDir := filepath.Join(root, "logs")
			workspace := filepath.Join(root, "workspace")
			if err := os.MkdirAll(logDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(workspace, 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("FAKE_AGENT_LOG", logDir)
			t.Setenv("CONDUIT_DISABLE_TERMINAL_TMUX", "1")
			claude, codex := writeHandoffFakeAgents(t, root)
			first, second := claude, codex
			if initial == "codex" {
				first, second = codex, claude
			}
			first.Hooks.OnSwap = "exit 7"

			s, err := newSession("handoff-"+initial, first, sessionOptions{
				repoRoot: root, conduitRoot: root, requestedCWD: workspace,
			})
			if err != nil {
				t.Fatalf("newSession: %v", err)
			}
			t.Cleanup(s.Close)

			if !s.SendChat("first-agent-context") {
				t.Fatal("initial SendChat not handled")
			}
			waitTurnIdle(t, s)
			firstID := s.chatSessionID
			firstThread := s.codexThreadID

			if err := s.Switch(second); err != nil {
				t.Fatalf("first switch: %v", err)
			}
			memory, err := os.ReadFile(s.memoryPath)
			if err != nil || !strings.Contains(string(memory), "CONDUIT HANDOFF") {
				t.Fatalf("handoff not persisted in session memory: err=%v memory=%s", err, memory)
			}
			var pendingMeta sessionMetadata
			metaData, _ := os.ReadFile(s.metaPath)
			if json.Unmarshal(metaData, &pendingMeta) != nil ||
				pendingMeta.PendingHandoffAgent != second.Name {
				t.Fatalf("pending handoff not persisted for target: %s", metaData)
			}
			if !s.SendChat("second-agent-task") {
				t.Fatal("second SendChat not handled")
			}
			waitTurnIdle(t, s)
			if err := s.Switch(first); err != nil {
				t.Fatalf("switch back: %v", err)
			}
			if !s.SendChat("back-on-first") {
				t.Fatal("switch-back SendChat not handled")
			}
			waitTurnIdle(t, s)

			claudeRequests, _ := os.ReadFile(filepath.Join(logDir, "claude.requests"))
			codexRequests, _ := os.ReadFile(filepath.Join(logDir, "codex.requests"))
			allRequests := string(claudeRequests) + string(codexRequests)
			if !strings.Contains(allRequests, "CONDUIT HANDOFF") ||
				!strings.Contains(allRequests, "first-agent-context") {
				t.Fatalf("incoming prompt missing broker handoff: %s", allRequests)
			}
			conv, err := os.ReadFile(s.convLog.path)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(conv), "CONDUIT HANDOFF") {
				t.Fatal("private handoff leaked into conversation.jsonl")
			}
			if initial == "claude" && (firstID == "" || s.chatSessionID != firstID) {
				t.Fatalf("claude thread not independently resumed: before=%q after=%q", firstID, s.chatSessionID)
			}
			if initial == "codex" && (firstThread == "" || s.codexThreadID != firstThread) {
				t.Fatalf("codex thread not independently resumed: before=%q after=%q", firstThread, s.codexThreadID)
			}
			claudeArgv, _ := os.ReadFile(filepath.Join(logDir, "claude.argv"))
			codexRPC, _ := os.ReadFile(filepath.Join(logDir, "codex.requests"))
			if initial == "claude" && !strings.Contains(string(claudeArgv), "--resume claude-thread") {
				t.Fatalf("switch-back did not resume claude thread: %s", claudeArgv)
			}
			if initial == "codex" && !strings.Contains(string(codexRPC), "thread/resume") {
				t.Fatalf("switch-back did not resume codex thread: %s", codexRPC)
			}
		})
	}
}

func TestSwitchFailureLeavesOldBackendAndMetadata(t *testing.T) {
	root := t.TempDir()
	logDir := filepath.Join(root, "logs")
	workspace := filepath.Join(root, "workspace")
	_ = os.MkdirAll(logDir, 0o755)
	_ = os.MkdirAll(workspace, 0o755)
	t.Setenv("FAKE_AGENT_LOG", logDir)
	t.Setenv("CONDUIT_DISABLE_TERMINAL_TMUX", "1")
	claude, _ := writeHandoffFakeAgents(t, root)
	s, err := newSession("handoff-failure", claude, sessionOptions{
		repoRoot: root, conduitRoot: root, requestedCWD: workspace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	oldChat := s.chat
	broken := agents.Adapter{
		Name: "codex", Command: []string{filepath.Join(root, "missing-codex")},
		Protocol: "codex-app-server",
	}
	if err := s.Switch(broken); err == nil {
		t.Fatal("expected target startup failure")
	}
	if s.Assistant != "claude" || s.chat != oldChat {
		t.Fatalf("failed switch mutated live backend: assistant=%q chat=%T", s.Assistant, s.chat)
	}
	var meta sessionMetadata
	data, _ := os.ReadFile(s.metaPath)
	if json.Unmarshal(data, &meta) != nil || meta.Assistant != "claude" {
		t.Fatalf("failed switch mutated metadata: %s", data)
	}
}

func TestSwitchUsesCodexExecFallbackWhenAppServerHandshakeFails(t *testing.T) {
	root := t.TempDir()
	logDir := filepath.Join(root, "logs")
	workspace := filepath.Join(root, "workspace")
	_ = os.MkdirAll(logDir, 0o755)
	_ = os.MkdirAll(workspace, 0o755)
	t.Setenv("FAKE_AGENT_LOG", logDir)
	t.Setenv("CONDUIT_DISABLE_TERMINAL_TMUX", "1")
	claude, _ := writeHandoffFakeAgents(t, root)
	s, err := newSession("handoff-fallback", claude, sessionOptions{
		repoRoot: root, conduitRoot: root, requestedCWD: workspace,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	bin := filepath.Join(root, "codex-fallback")
	fallbackScript := `#!/bin/sh
if [ "$1" = "app-server" ]; then
  IFS= read -r line
  printf '%s\n' '{"id":1,"error":{"code":-1,"message":"app-server unavailable"}}'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(bin, []byte(fallbackScript), 0o755); err != nil {
		t.Fatal(err)
	}
	target := agents.Adapter{Name: "codex", Command: []string{bin}, Protocol: "codex-app-server"}
	if err := s.Switch(target); err != nil {
		t.Fatalf("fallback switch: %v", err)
	}
	if _, ok := s.chat.(*codexChatProcess); !ok {
		t.Fatalf("expected codex-exec fallback, got %T", s.chat)
	}
}

type switchBusyBackend struct {
	active bool
	card   bool
}

func (b *switchBusyBackend) Send(string) error { return nil }
func (b *switchBusyBackend) Interrupt() error  { return nil }
func (b *switchBusyBackend) Close() error      { return nil }
func (b *switchBusyBackend) TurnActive() bool  { return b.active }
func (b *switchBusyBackend) PendingApprovalCard() (string, bool) {
	return "pending", b.card
}

func TestSwitchRejectsActiveInteractionsBeforeMutation(t *testing.T) {
	target := agents.Adapter{Name: "codex", Command: []string{"sh"}, Protocol: "codex-exec"}
	for _, tc := range []struct {
		name string
		set  func(*Session)
	}{
		{"turn", func(s *Session) { s.chat = &switchBusyBackend{active: true} }},
		{"ask", func(s *Session) { s.pendingAsk = &pendingAsk{} }},
		{"approval", func(s *Session) { s.chat = &switchBusyBackend{card: true} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &Session{Assistant: "claude", adapter: agents.Adapter{Name: "claude"}}
			tc.set(s)
			if err := s.Switch(target); err == nil {
				t.Fatal("expected active interaction rejection")
			}
			if s.Assistant != "claude" {
				t.Fatalf("assistant changed on rejection: %q", s.Assistant)
			}
		})
	}
}
