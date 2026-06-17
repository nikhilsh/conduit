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
	// claudeAppendSystemPromptForWorkspace). Log once per spawn so a "the agent
	// didn't know about $PORT" report is diagnosable from box logs. The
	// mechanism suffix notes whether the KB section was included.
	if conduitAwarenessEnabled() {
		mechanism := "claude:append-system-prompt"
		_, hasKB := kbSection(s.workspaceDir)
		if hasKB {
			mechanism = "claude:append-system-prompt+kb"
		}
		logConduitAwarenessInjected(s.ID, adapter.Name, mechanism)
	}

	// Subagent registry handle: declared here (before the fork block) so
	// it can be captured by both the fork respawn and the normal respawn.
	subagentH := s.subagentHandle()

	argsFor := func(resume string, continueLatest bool) []string {
		baseArgs := append(append([]string{}, adapter.Args...), s.override.extraArgsForAdapter(adapter)...)
		// Apply the chosen permission mode (e.g. plan): for claude this may
		// drop --dangerously-skip-permissions, so it must wrap the adapter args
		// before the stream-json flags are appended.
		baseArgs = applyPermissionModeFromManifest(baseArgs, adapter, s.override.PermissionMode)
		return claudeStreamCommandForkWithWorkspace(adapter.Command, baseArgs, resume, continueLatest, false, s.workspaceDir)
	}

	// Fork path: --resume <external_id> --fork-session branches the
	// conversation into a new claude session id without touching the original.
	if req.forkChatSessionID != "" {
		baseArgs := append(append([]string{}, adapter.Args...), s.override.extraArgsForAdapter(adapter)...)
		baseArgs = applyPermissionModeFromManifest(baseArgs, adapter, s.override.PermissionMode)
		forkArgv := claudeStreamCommandForkWithWorkspace(adapter.Command, baseArgs, req.forkChatSessionID, false, true, s.workspaceDir)
		// Seed resumeChatSessionID so latchChatSessionID captures the new
		// fork's session id and respawns resume it going forward.
		s.mu.Lock()
		s.chatSessionID = req.forkChatSessionID // interim; overwritten on init
		s.mu.Unlock()

		chat, cerr := startChatProcess(
			context.Background(),
			forkArgv,
			s.commandEnv(nil),
			s.workspaceDir,
			s.PublishText,
			newQuickReplyGeneratorWithProvider(s.ID, req.aiGen, s.PublishText),
			s.titleGen,
			s.accumulateUsage,
			s.handleAskControl,
			s.latchChatSessionID,
			s.subagentHandle(),
		)
		if cerr != nil {
			fmt.Fprintf(os.Stderr, "session %s: fork startChatProcess: %v (chat disabled)\n", s.ID, cerr)
			publishChatSystem(s.PublishText, "⚠️ claude: fork failed: "+cerr.Error())
			return spawnResult{}, cerr
		}
		// Respawn after fork resumes normally (the new forked session id,
		// latched on init, is the one to resume going forward).
		respawnFork := func() (chatBackend, error) {
			s.mu.Lock()
			resume := s.chatSessionID
			s.mu.Unlock()
			return startChatProcess(
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
		}
		return spawnResult{backend: chat, respawn: respawnFork}, nil
	}

	// On-demand install: if the claude CLI is missing and the adapter has an
	// install_cmd, install it now (single-flight, ~300 s timeout) and retry.
	// A visible "Installing…" / "installed" / error message is published to
	// the Chat tab so the user knows why the session is taking longer.
	if installErr := maybeInstallAgent(adapter.Name, adapter.Command[0], adapter.InstallCmd, s.PublishText); installErr != nil {
		fmt.Fprintf(os.Stderr, "session %s: agent install: %v (chat disabled)\n", s.ID, installErr)
		publishChatSystem(s.PublishText, "⚠️ claude: failed to start: "+installErr.Error())
		return spawnResult{}, installErr
	}

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
