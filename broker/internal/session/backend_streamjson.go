package session

import (
	"context"
	"fmt"
	"os"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// streamjsonBackend is the claude stream-json control-protocol backend. It is
// registered under protocol "stream-json"; the construction here is a
// behavior-preserving MOVE of the former `case "claude"` branch of
// startChatBackend (manager.go), probeClaudeCatalog (modelcatalog.go), and the
// claude leg of RefreshAccountUsage (accountusage.go). No wire behavior
// changed — the goldens pin the argv/frames.
type streamjsonBackend struct{}

func init() { registerBackend("stream-json", streamjsonBackend{}) }

func (streamjsonBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         true,
		AskUserQuestion: true, // stdio control bridge → tappable cards
		Effort:          true,
		Resume:          true, // --resume / --continue across respawns
		Interrupt:       true, // control_request{interrupt}
		Usage:           true, // api.anthropic.com/api/oauth/usage
	}
}

func (streamjsonBackend) CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error) {
	return probeClaudeCatalog(ctx, bin)
}

func (streamjsonBackend) Usage(ctx context.Context, do httpDoFunc, homeDir string) (AccountUsage, bool, error) {
	u, err := fetchAccountUsage(ctx, do, homeDir)
	return u, true, err
}

// Spawn runs claude headless in stream-json as a structured chat channel. The
// PTY (a shell) drains to the Terminal tab; the scraper stays nil. The AI
// niceties (quick replies + titles) are wired the way claude natively expects:
// passed into startChatProcess as constructor args. The respawn closure
// re-spawns on the latched conversation id for SendChat's self-heal.
func (streamjsonBackend) Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error) {
	// AI quick replies (task #233): on each completed assistant turn, a
	// best-effort one-shot completion suggests up to 4 tap-able user replies,
	// emitted as a `view:"quick_replies"` view_event. nil when the feature is
	// off or no provider has creds — turn-end no-ops.
	gen := newQuickReplyGeneratorWithProvider(s.ID, req.aiGen, s.PublishText)
	// AI session titles: after the first meaningful exchange the generator
	// mints a short human title and emits a `view:"session_title"` view_event;
	// the apps slot it BELOW a manual rename. nil when titling is off / no
	// provider — turn-end then no-ops.
	s.titleGen = newTitleGeneratorWithProvider(
		s.ID,
		req.aiGen,
		s.firstPrompt,
		s.applyAITitle,
	)
	// Recovery/switch hands us the prior conversation id — seed it so the
	// FIRST spawn resumes, and persistMetadata keeps carrying it.
	s.mu.Lock()
	s.chatSessionID = req.resumeChatSessionID
	s.mu.Unlock()

	// Part A breadcrumb: the conduit-awareness addendum rides claude's
	// --append-system-prompt (merged with the askUserQuestionNudge in
	// claudeAppendSystemPrompt). Log once per spawn so a "the agent didn't
	// know about $PORT" report is diagnosable from box logs.
	if conduitAwarenessEnabled() {
		logConduitAwarenessInjected(s.ID, adapter.Name, "claude:append-system-prompt")
	}

	argsFor := func(resume string, continueLatest bool) []string {
		baseArgs := append(append([]string{}, adapter.Args...), s.override.extraArgsForAdapter(adapter)...)
		// Apply the chosen permission mode (e.g. plan): for claude this may
		// drop --dangerously-skip-permissions, so it must wrap the adapter args
		// before the stream-json flags are appended.
		baseArgs = applyPermissionModeFromManifest(baseArgs, adapter, s.override.PermissionMode)
		return claudeStreamCommand(adapter.Command, baseArgs, resume, continueLatest)
	}

	// Subagent registry handle: carries s.mu + s.subagents so the stream
	// pump can update the roster and emit view_event{view:"agents"}. Built
	// once here and reused for the self-heal respawn so the registry state
	// (which lives on the Session) persists across process restarts.
	subagentH := s.subagentHandle()

	chat, cerr := startChatProcess(
		context.Background(),
		argsFor(req.resumeChatSessionID, req.continueLatestChat),
		s.commandEnv(nil),
		s.workspaceDir,
		s.PublishText,
		gen,
		s.titleGen,
		s.accumulateUsage,
		s.handleAskControl,
		s.latchChatSessionID,
		subagentH,
	)
	if cerr != nil {
		fmt.Fprintf(os.Stderr, "session %s: startChatProcess: %v (chat disabled)\n", s.ID, cerr)
		publishChatSystem(s.PublishText, "⚠️ claude: failed to start: "+cerr.Error())
		return spawnResult{}, cerr
	}

	// Same argv/env for the self-heal respawn in SendChat. The captured
	// generators are per-session, not per-process, so the fresh agent keeps
	// quick replies + titling.
	respawn := func() (chatBackend, error) {
		// Resume the conversation the dead agent was holding — the latched id
		// is the whole point of the respawn not being amnesiac. Falls back to
		// a fresh conversation when no init line was ever captured.
		s.mu.Lock()
		resume := s.chatSessionID
		s.mu.Unlock()
		fresh, ferr := startChatProcess(
			context.Background(),
			argsFor(resume, false),
			s.commandEnv(nil),
			s.workspaceDir,
			s.PublishText,
			gen,
			s.titleGen,
			s.accumulateUsage,
			s.handleAskControl,
			s.latchChatSessionID,
			subagentH,
		)
		return fresh, ferr
	}

	return spawnResult{backend: chat, respawn: respawn}, nil
}
