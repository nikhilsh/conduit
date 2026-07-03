package session

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// streamjsonBackend is the claude stream-json control-protocol backend. It is
// registered under protocol "stream-json"; the construction here is a
// behavior-preserving MOVE of the former `case "claude"` branch of
// startChatBackend (manager.go), probeClaudeCatalog (modelcatalog.go), and the
// claude leg of RefreshAccountUsage (accountusage.go). No wire behavior
// changed — the goldens pin the argv/frames.
// phaseRateLimiter coalesces rapid turn-phase status broadcasts to at most
// one per second. It is trailing-edge: the FINAL phase value in any window
// always broadcasts (via a timer) so no state is permanently lost. Phase ""
// (turn end) and calls via immediate() always bypass the limiter.
type phaseRateLimiter struct {
	mu            sync.Mutex
	lastBroadcast time.Time
	timer         *time.Timer
	hasPending    bool
	broadcast     func()
}

func newPhaseRateLimiter(broadcast func()) *phaseRateLimiter {
	return &phaseRateLimiter{broadcast: broadcast}
}

// immediate broadcasts now and cancels any pending timer.
// Used for turn-end (phase "") transitions that must never be coalesced.
func (r *phaseRateLimiter) immediate() {
	r.mu.Lock()
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
	r.hasPending = false
	r.mu.Unlock()
	r.broadcast()
}

// schedule coalesces the broadcast: fires immediately if the last broadcast
// was more than 1 second ago, otherwise schedules a trailing-edge timer so
// the current phase always lands within 1 second.
func (r *phaseRateLimiter) schedule() {
	r.mu.Lock()
	now := time.Now()
	if now.Sub(r.lastBroadcast) >= time.Second {
		r.lastBroadcast = now
		r.hasPending = false
		r.mu.Unlock()
		r.broadcast()
		return
	}
	if !r.hasPending {
		r.hasPending = true
		delay := time.Second - now.Sub(r.lastBroadcast)
		r.timer = time.AfterFunc(delay, func() {
			r.mu.Lock()
			r.hasPending = false
			r.lastBroadcast = time.Now()
			r.mu.Unlock()
			r.broadcast()
		})
	}
	r.mu.Unlock()
}

type streamjsonBackend struct{}

func init() { registerBackend("stream-json", streamjsonBackend{}) }

func (streamjsonBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         true,
		Clear:           true, // /clear pass-through → new session_id, confirmation
		AskUserQuestion: true, // stdio control bridge → tappable cards
		Effort:          true,
		Resume:          true, // --resume / --continue across respawns
		Interrupt:       true, // control_request{interrupt}
		Usage:           true, // api.anthropic.com/api/oauth/usage
	}
}

func (streamjsonBackend) CatalogProbe(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
	return probeClaudeCatalog(ctx, bin, extraEnv)
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
	gen := newQuickReplyGeneratorWithProvider(s.ID, req.aiGen, s.PublishText, s.SubscriberCount)
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
	// --append-system-prompt (via claudeAppendSystemPromptForWorkspace). Log
	// once per spawn so a "the agent didn't know about $PORT" report is
	// diagnosable from box logs. The mechanism suffix notes whether the KB
	// section was included.
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

	// onTurnPhase updates the session's turnPhase field and broadcasts a
	// fresh status frame when the phase changes.
	//
	// Rate-limiting: intermediate phase changes (e.g. thinking→writing→working
	// during streaming) are coalesced to at most 1 broadcast per second via
	// phaseRateLimiter. A suppressed intermediate is fine; the trailing-edge
	// timer guarantees the final phase in each window still broadcasts.
	//
	// Turn END (phase == "") bypasses rate-limiting and broadcasts immediately.
	// The app's queued-send flush depends on prompt-idle notification (#865/#866)
	// so this transition must never be delayed.
	prl := newPhaseRateLimiter(s.broadcastStatus)
	onTurnPhase := func(phase string) {
		s.mu.Lock()
		changed := s.turnPhase != phase
		s.turnPhase = phase
		s.mu.Unlock()
		if !changed {
			return
		}
		if phase == "" {
			// Turn END: must broadcast immediately, never coalesced.
			prl.immediate()
		} else {
			// Intermediate phase: rate-limit to 1/sec, trailing edge guaranteed.
			prl.schedule()
		}
	}

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
			newQuickReplyGeneratorWithProvider(s.ID, req.aiGen, s.PublishText, s.SubscriberCount),
			s.titleGen,
			s.accumulateUsage,
			s.handleAskControl,
			s.latchChatSessionID,
			s.subagentHandle(),
			onTurnPhase,
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
				onTurnPhase,
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
		onTurnPhase,
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
			onTurnPhase,
		)
		return fresh, ferr
	}

	return spawnResult{backend: chat, respawn: respawn}, nil
}
