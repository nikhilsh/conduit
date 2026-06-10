package session

import (
	"context"
	"fmt"
	"os"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// This file holds the two codex backends (app-server JSON-RPC and the
// exec-per-turn fallback) plus the AI-niceties wiring they share. Both are
// behavior-preserving MOVES of the former `case "codex"` branch of
// startChatBackend (manager.go): the app-server-vs-exec selection, the
// thread-id seeding, the codex catalog probe, and the codex leg of
// RefreshAccountUsage. No wire behavior changed — the codexappserver tests
// pin the frames.

// codexSeedThread records the recovered/prior thread id on the session so the
// first turn resumes codex's own conversation (the codex twin of claude's
// --resume seed). codex has no long-lived-process self-heal respawn, so
// chatRespawn is cleared.
func codexSeedThread(s *Session, resumeCodexThreadID string) {
	s.mu.Lock()
	s.codexThreadID = resumeCodexThreadID
	s.chatRespawn = nil
	s.mu.Unlock()
}

// wireCodexTurnHook builds the per-session AI-niceties generators (titles +
// quick replies) and attaches them to a codex backend via its native
// setTurnHook. nil aiGen → nil generators → the hook no-ops, so a codex
// session with no creds behaves as before (the WS-0.1 parity guarantee). This
// is the codex twin of the stream-json path passing gen/titleGen into
// startChatProcess.
func wireCodexTurnHook(s *Session, aiGen aiGenProvider, backend chatBackend) {
	qrGen := newQuickReplyGeneratorWithProvider(s.ID, aiGen, s.PublishText)
	s.titleGen = newTitleGeneratorWithProvider(s.ID, aiGen, s.firstPrompt, s.applyAITitle)
	if qrGen == nil && s.titleGen == nil {
		return
	}
	onTurn := func(lastAssistant, msgID string) {
		qrGen.kickoff(lastAssistant, msgID)
		s.titleGen.onTurnEnd(lastAssistant)
	}
	switch b := backend.(type) {
	case *codexAppServerProcess:
		b.setTurnHook(onTurn)
	case *codexChatProcess:
		b.setTurnHook(onTurn)
	}
}

// newCodexExecBackend constructs the codex-exec per-turn backend. Shared by the
// codexExecBackend.Spawn and by the codex-app-server hard-spawn-failure
// fallback, so the construction stays in one place.
func newCodexExecBackend(s *Session, adapter agents.Adapter, resumeCodexThreadID string) *codexChatProcess {
	return newCodexChatProcess(
		adapter.Command[0],
		s.workspaceDir,
		s.commandEnv(nil),
		s.override.extraArgsForAdapter(adapter),
		s.PublishText,
		s.accumulateUsage,
		resumeCodexThreadID,
		s.latchCodexThreadID,
		s.override.PermissionMode,
	)
}

// --- codex app-server backend ---

// codexAppServerBackend is the long-lived `codex app-server` JSON-RPC backend
// (one persistent thread; unlocks manual /compact and on-request approvals).
// Registered under protocol "codex-app-server".
type codexAppServerBackend struct{}

func init() { registerBackend("codex-app-server", codexAppServerBackend{}) }

func (codexAppServerBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         true, // persistent thread → /compact
		AskUserQuestion: true, // on-request approval cards
		Effort:          true,
		Resume:          true, // thread/resume across restarts
		Interrupt:       true, // turn/interrupt
		Usage:           true, // chatgpt.com /wham/usage
	}
}

func (codexAppServerBackend) CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error) {
	return probeCodexCatalog(ctx, bin)
}

func (codexAppServerBackend) Usage(ctx context.Context, do httpDoFunc, homeDir string) (AccountUsage, bool, error) {
	u, err := fetchCodexAccountUsage(ctx, do, homeDir)
	return u, true, err
}

// Spawn starts the codex app-server (initialize/thread handshake runs
// synchronously now). On a hard spawn failure it falls back to the codex-exec
// backend so chat still works — the original behavior, moved verbatim.
func (codexAppServerBackend) Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error) {
	codexSeedThread(s, req.resumeCodexThreadID)
	// Build the backend OUTSIDE s.mu: the app-server constructor runs the
	// initialize/thread-start handshake synchronously and latches the thread
	// id via s.latchCodexThreadID (which takes s.mu) — doing it under the lock
	// would deadlock.
	var backend chatBackend
	if proc, cerr := newCodexAppServerProcess(adapter.Command[0], s.workspaceDir, s.commandEnv(nil), s.override, s.PublishText, s.accumulateUsage, req.resumeCodexThreadID, s.latchCodexThreadID); cerr == nil {
		backend = proc
	} else {
		fmt.Fprintf(os.Stderr, "session %s: codex app-server spawn failed: %v (falling back to codex-exec)\n", s.ID, cerr)
		backend = newCodexExecBackend(s, adapter, req.resumeCodexThreadID)
	}
	wireCodexTurnHook(s, req.aiGen, backend)
	return spawnResult{backend: backend}, nil
}

// --- codex exec backend (fallback) ---

// codexExecBackend is the per-turn `codex exec`/`exec resume` backend. No
// long-lived process, no on-request approvals, no /compact. Registered under
// protocol "codex-exec".
type codexExecBackend struct{}

func init() { registerBackend("codex-exec", codexExecBackend{}) }

func (codexExecBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         false, // per-turn exec has no persistent thread
		AskUserQuestion: false, // exec path has no on-request approval flow
		Effort:          true,
		Resume:          true, // exec resume by thread id
		Interrupt:       true, // proc kill
		Usage:           true, // chatgpt.com /wham/usage
	}
}

func (codexExecBackend) CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error) {
	return probeCodexCatalog(ctx, bin)
}

func (codexExecBackend) Usage(ctx context.Context, do httpDoFunc, homeDir string) (AccountUsage, bool, error) {
	u, err := fetchCodexAccountUsage(ctx, do, homeDir)
	return u, true, err
}

func (codexExecBackend) Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error) {
	codexSeedThread(s, req.resumeCodexThreadID)
	backend := newCodexExecBackend(s, adapter, req.resumeCodexThreadID)
	wireCodexTurnHook(s, req.aiGen, backend)
	return spawnResult{backend: backend}, nil
}
