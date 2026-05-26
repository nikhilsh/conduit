// Package session manages per-UUID sessions: a PTY-attached process,
// resize state, scrollback ring, and the channels that fan PTY output
// out to one or more attached WebSocket viewers.
//
// Task 001 scope: hardcoded `sh` as the "agent" — Docker-spawned agent
// containers land in task 006. Worktree creation / checkpoint / watchdog
// land in task 005. Everything in this file must be safe to extend
// behind the same public surface.
package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"

	"github.com/nikhilsh/swe-kitty/broker/internal/agents"
	"github.com/nikhilsh/swe-kitty/broker/internal/credentials"
	"github.com/nikhilsh/swe-kitty/broker/internal/replay"
	"github.com/nikhilsh/swe-kitty/broker/internal/termgrid"
)

const ringSize = 256 * 1024 // 256 KB scrollback per session

// Session is the per-UUID handle. Safe for concurrent use.
type Session struct {
	ID        string
	Assistant string

	pty       *os.File
	cmd       *exec.Cmd
	adapter   agents.Adapter
	rows      uint16
	cols      uint16
	closed    chan struct{}
	closeOnce sync.Once

	mu       sync.Mutex
	ring     []byte // circular scrollback
	ringPos  int
	ringFull bool
	subs     map[chan []byte]struct{}
	textSubs map[chan []byte]struct{}
	// dropped bytes accumulator (per-session, all subscribers) and
	// last-log time. Logged at most once per second so a chronically
	// slow viewer doesn't flood the operator's stderr.
	droppedBytes  int
	lastDroppedAt time.Time
	switchFn      func(string) error

	repoRoot          string
	kittyRoot         string
	sessionDir        string
	worktreeDir       string
	scrollbackPath    string
	memoryPath        string
	metaPath          string
	handoffPath       string
	handoffOutPath    string
	checkpointEvery   time.Duration
	watchdogEvery     time.Duration
	stallAfter        time.Duration
	handoffTimeout    time.Duration
	workspaceDir      string
	requestedCWD      string
	reasonCode        string
	exitCode          int
	hooks             agents.Hooks
	phase             string
	health            string
	lastOutput        time.Time
	lastCheckpoint    time.Time
	startedAt         time.Time
	handoffHTML       string
	checkpointMu      sync.Mutex
	lastMemoryModTime time.Time
	swapping          bool
	// displayName is the human-readable session label set by a
	// successful `rename_session` JSON control. Mirrors the docs in
	// `WEBSOCKET-PROTOCOL.md` §3.3: last-writer-wins, no ack, broadcast
	// back through the next `status` envelope as `session_name` plus
	// the typed `view_event` mirror's `display_name`. Empty until a
	// rename lands; persists for the lifetime of the in-memory session.
	displayName string

	// aiTitle is the broker AI-generated session title (task:
	// ai-session-titles) — a short human label minted from the first
	// meaningful exchange. SEPARATE from displayName: a manual rename
	// always wins over the AI title in the apps' display-name priority, so
	// the two never share a field. Emitted to the apps as a
	// `view:"session_title"` view_event, persisted into meta, and
	// re-emitted to a freshly attached client so a relisted session keeps
	// it. Empty until the first generation lands.
	aiTitle string

	// firstUserPrompt is the composer text that opened the conversation —
	// captured on the first SendChat/MarkUserChatSent so the title
	// generator can summarize the conversation's purpose. Set once; later
	// prompts don't overwrite it.
	firstUserPrompt string

	// titleGen mints aiTitle off the stream reader at turn-end. nil when
	// titling is off, there's no ephemeral HOME, or the backend isn't
	// claude. Methods tolerate the nil receiver.
	titleGen *titleGenerator

	// termgrid is the optional headless xterm.js sidecar handle. nil
	// when node isn't installed; callers must treat it as best-effort.
	termgrid *termgrid.Manager

	// chatScraper turns PTY output back into structured chat_event
	// JSON frames. Lives for the life of the session; capturing
	// state is gated on the user actually sending a chat message.
	// nil in stream-json mode (the PTY is a shell, not the agent).
	scraper *chatScraper

	// chat is the structured-chat backend. Non-nil only when the adapter
	// sets a structured chat_mode (claude stream-json or codex exec): the
	// agent runs headless here while the PTY hosts a shell for the
	// Terminal tab (B-i). See docs/PLAN-CHAT-CHANNEL.md (task #24).
	chat chatBackend

	// recorder writes PTY bytes + view_events to a per-session
	// `<replayBaseDir>/<sessionID>/replay.json` JSONL file so a
	// later browser visit to `GET /replay/<id>` can re-render the
	// session. nil when recording is disabled at manager
	// construction; methods on Recorder tolerate the nil receiver
	// so the drain / publish paths don't have to branch.
	recorder *replay.Recorder

	// convLog persists the full conversation (user + assistant + tool)
	// to `<sessionDir>/conversation.jsonl` so an exited session's
	// transcript can be re-read after reap. Unlike the recorder it
	// captures user prompts too (see convlog.go). Always non-nil once
	// applyPaths runs; appends tolerate concurrent callers.
	convLog *convLogger

	// override carries the optional per-session reasoning-effort / model
	// overrides supplied at creation (the fork-onto-a-different-model
	// path). Zero value = adapter defaults unchanged. Read-only after
	// newSession, so no locking needed.
	override SpawnOverride

	// agentHomeDir is the per-session ephemeral $HOME. ALWAYS populated
	// for every session (except in the rare case the mkdir fails, in
	// which case the agent falls back to inheriting the broker $HOME).
	// Sources: credStore Materialize (per-user OAuth, see
	// docs/PLAN-AGENT-OAUTH.md §G.2) OR a copy of the broker's real
	// $HOME credentials. The per-session HOME is what breaks the
	// concurrent-refresh race on `.claude/.credentials.json` —
	// each agent rotates its own copy of the OAuth refresh token,
	// not a shared file. Removed on Close.
	agentHomeDir string
}

func New(id string, adapter agents.Adapter) (*Session, error) {
	repoRoot, kittyRoot, err := resolveKittyRoots()
	if err != nil {
		return nil, err
	}
	return newSession(id, adapter, sessionOptions{
		repoRoot:  repoRoot,
		kittyRoot: kittyRoot,
	})
}

func newSession(id string, adapter agents.Adapter, opts sessionOptions) (*Session, error) {
	var cmd *exec.Cmd
	if structuredChatBackend(adapter.ChatMode) != "" {
		// B-i: a structured chat_mode runs the agent headless (started
		// below as a chatBackend); the PTY hosts an interactive shell
		// for the Terminal tab.
		//
		// Back the Terminal-tab shell with a per-session tmux session
		// keyed by the session ID so the terminal — and its scrollback —
		// survives a disconnect or app-background: the PTY's shell can
		// die and re-attach, but tmux keeps the real shell alive between
		// attaches. When tmux isn't on PATH we fall back to plain bash
		// with no behaviour change (terminalShellArgv handles both).
		tmuxPath, _ := exec.LookPath("tmux")
		argv := terminalShellArgv(tmuxPath, sanitizeTmuxName(id))
		cmd = exec.Command(argv[0], argv[1:]...)
	} else {
		// Apply the optional reasoning-effort / model override after the
		// adapter's own args. Empty override → adapter.Args unchanged, so
		// the normal start path is byte-for-byte identical to before.
		ptyArgs := append(append([]string{}, adapter.Args...), opts.override.extraArgsFor(adapter.Name)...)
		cmd = exec.Command(adapter.Command[0], append(append([]string{}, adapter.Command[1:]...), ptyArgs...)...)
	}
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "PS1=$ ")
	s := &Session{
		ID:           id,
		Assistant:    adapter.Name,
		termgrid:     opts.termgrid,
		adapter:      adapter,
		override:     opts.override,
		rows:         40,
		cols:         120,
		closed:       make(chan struct{}),
		ring:         make([]byte, ringSize),
		subs:         make(map[chan []byte]struct{}),
		textSubs:     make(map[chan []byte]struct{}),
		repoRoot:     opts.repoRoot,
		kittyRoot:    opts.kittyRoot,
		requestedCWD: strings.TrimSpace(opts.requestedCWD),
		checkpointEvery: durationFromEnv(
			"KITTY_SESSION_CHECKPOINT_INTERVAL_MS",
			60*time.Second,
		),
		watchdogEvery: durationFromEnv(
			"KITTY_SESSION_WATCHDOG_INTERVAL_MS",
			30*time.Second,
		),
		stallAfter: durationFromEnv(
			"KITTY_SESSION_STALL_AFTER_MS",
			5*time.Minute,
		),
		handoffTimeout: durationFromEnv(
			"KITTY_SESSION_HANDOFF_TIMEOUT_MS",
			250*time.Millisecond,
		),
		hooks:      adapter.Hooks,
		phase:      "running",
		health:     "healthy",
		reasonCode: "ok",
		lastOutput: time.Now().UTC(),
		startedAt:  time.Now().UTC(),
	}
	s.applyPaths()
	if err := s.prepareFilesystem(); err != nil {
		return nil, err
	}
	// Start the replay recorder before drain so we capture from the
	// first PTY byte. Failure is non-fatal: log and keep the session
	// alive without recording — the live WS path is the user-visible
	// surface, the recorder is the audit/debug side channel.
	if opts.replayBaseDir != "" {
		rec, err := replay.NewRecorder(s.ID, opts.replayBaseDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %s: replay recorder disabled: %v\n", s.ID, err)
		} else {
			s.recorder = rec
		}
	}
	s.workspaceDir = s.commandDir(adapter)
	cmd.Dir = s.workspaceDir
	// ALWAYS isolate $HOME per session. Multiple concurrent claude/codex
	// agents sharing the broker's real $HOME race on the OAuth refresh
	// token rotation in `.claude/.credentials.json` (or `.codex/auth.json`)
	// — whichever process refreshes last wins, all others get rejected
	// and prompt "Please run /login". A per-session HOME breaks the race
	// by giving each agent its own private copy of the credentials file
	// to refresh in isolation.
	//
	// Two population sources, in priority order:
	//   1. credStore (per-user OAuth blob, set via OAuth Stage 2) —
	//      docs/PLAN-AGENT-OAUTH.md §G.2.
	//   2. Otherwise: copy the broker's real $HOME credential files
	//      (`~/.claude/.credentials.json` + `~/.claude.json` for claude,
	//      `~/.codex/auth.json` + `~/.codex/config.toml` for codex).
	//
	// If the credentials don't exist on the broker host either, we log
	// and let the agent prompt for login on its own — that's a clean
	// "please /login" UX, far better than the silent refresh-token race.
	provider := providerForAssistant(adapter.Name)
	ephemeral := filepath.Join(s.workspaceDir, ".swe-kitty", "agent-home", s.ID)
	if err := os.MkdirAll(ephemeral, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: agent-home mkdir: %v (agent will inherit broker $HOME)\n", s.ID, err)
	} else {
		s.agentHomeDir = ephemeral
		populated := false
		if opts.credStore != nil && provider != "" && opts.credStore.Has(provider) {
			if err := opts.credStore.Materialize(provider, ephemeral); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: credentials.Materialize(%s): %v (falling back to host-creds copy)\n", s.ID, provider, err)
			} else {
				populated = true
			}
		}
		if !populated && provider != "" {
			if err := mirrorHostCredentials(provider, ephemeral); err != nil {
				// Non-fatal: agent will see an empty HOME and prompt
				// for login. Clean error path; no race with peers.
				fmt.Fprintf(os.Stderr, "session %s: mirrorHostCredentials(%s): %v (agent will prompt for login)\n", s.ID, provider, err)
			}
		}
		// Seed a theme + onboarding marker so Claude Code's first-run
		// interactive theme picker doesn't block the PTY. Non-fatal:
		// worst case the agent shows the picker once. Anthropic-only —
		// codex has no equivalent first-run prompt.
		if provider == "anthropic" {
			if err := seedClaudeConfig(ephemeral); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: seedClaudeConfig: %v (agent may show first-run theme picker)\n", s.ID, err)
			}
		}
	}
	cmd.Env = s.commandEnv(nil)
	if len(opts.snapshot) > 0 {
		s.restoreSnapshot(opts.snapshot)
	}
	if !opts.lastCheckpoint.IsZero() {
		s.lastCheckpoint = opts.lastCheckpoint
	}
	if opts.handoffHTML != "" {
		s.handoffHTML = opts.handoffHTML
	} else {
		s.handoffHTML = s.loadHandoffHTML()
	}
	f, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	s.pty = f
	s.cmd = cmd
	_ = pty.Setsize(f, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	if s.termgrid != nil {
		if err := s.termgrid.Create(s.ID, s.rows, s.cols); err != nil {
			// Non-fatal — fall back to ring snapshots for this session.
			fmt.Fprintf(os.Stderr, "session %s: termgrid.Create: %v (continuing with ring-only)\n", s.ID, err)
			s.termgrid = nil
		}
		// If we restored a snapshot from disk, replay it into the
		// headless grid so subsequent reflows have content.
		if s.termgrid != nil && len(opts.snapshot) > 0 {
			if err := s.termgrid.Write(s.ID, opts.snapshot); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: termgrid.Write(snapshot): %v\n", s.ID, err)
			}
		}
	}
	if err := s.persistMetadata(); err != nil {
		_ = f.Close()
		if s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
			_, _ = s.cmd.Process.Wait()
		}
		return nil, err
	}
	switch structuredChatBackend(adapter.ChatMode) {
	case "claude":
		// claude headless in stream-json. Publishes clean chat events via
		// the same path the scraper used — no PTY scraping (scraper stays
		// nil); the PTY (a shell) drains to the Terminal tab below.
		// AI quick replies (task #233): on each completed assistant turn,
		// a best-effort one-shot `claude -p` (cheap model) suggests up to
		// 4 tap-able user replies, emitted as a `view:"quick_replies"`
		// view_event. nil when the feature is off or there's no ephemeral
		// HOME to copy creds from — the stream reader then no-ops turn-end.
		gen := newQuickReplyGenerator(
			s.ID,
			adapter.Command[0],
			s.agentHomeDir,
			s.workspaceDir,
			s.commandEnv(nil),
			s.PublishText,
		)
		// AI session titles (task: ai-session-titles): after the first
		// meaningful exchange the generator mints a short human title from
		// the conversation and emits a `view:"session_title"` view_event;
		// the apps slot it BELOW a manual rename in the display name. nil
		// when titling is off / no ephemeral HOME — turn-end then no-ops.
		s.titleGen = newTitleGenerator(
			s.ID,
			adapter.Command[0],
			s.agentHomeDir,
			s.firstPrompt,
			s.applyAITitle,
		)
		chat, cerr := startChatProcess(
			context.Background(),
			claudeStreamCommand(adapter.Command, append(append([]string{}, adapter.Args...), opts.override.extraArgsFor(adapter.Name)...)),
			s.commandEnv(nil),
			s.workspaceDir,
			s.PublishText,
			gen,
			s.titleGen,
		)
		if cerr != nil {
			fmt.Fprintf(os.Stderr, "session %s: startChatProcess: %v (chat disabled)\n", s.ID, cerr)
		} else {
			s.chat = chat
		}
	case "codex":
		// codex via per-turn exec/resume; constructed lazily (spawns on
		// first Send). Same publish path; PTY is a shell.
		s.chat = newCodexChatProcess(adapter.Command[0], s.workspaceDir, s.commandEnv(nil), opts.override.extraArgsFor(adapter.Name), s.PublishText)
	default:
		s.scraper = newChatScraper(s.PublishText)
		go s.scraper.run(s.closed)
	}
	go s.drain(f)
	s.startBackgroundLoops()
	return s, nil
}

// Write sends bytes to the PTY input (terminal keystrokes).
func (s *Session) Write(p []byte) (int, error) {
	return s.pty.Write(p)
}

// Resize updates the PTY winsize. Both dimensions must be > 0.
func (s *Session) Resize(rows, cols uint16) error {
	if rows == 0 || cols == 0 {
		return errors.New("resize: rows and cols must be > 0")
	}
	s.mu.Lock()
	s.rows, s.cols = rows, cols
	tg := s.termgrid
	s.mu.Unlock()
	if tg != nil {
		if err := tg.Resize(s.ID, rows, cols); err != nil {
			fmt.Fprintf(os.Stderr, "session %s: termgrid.Resize: %v\n", s.ID, err)
		}
	}
	return pty.Setsize(s.pty, &pty.Winsize{Rows: rows, Cols: cols})
}

// Subscribe returns a channel that receives every subsequent PTY chunk
// until Unsubscribe is called or the session closes. The channel is
// closed when the session ends.
//
// Multi-viewer fan-out: every PTY byte is delivered to every live
// subscriber. The send is non-blocking with a drop-oldest backpressure
// policy (see fanout), so one slow viewer cannot stall the PTY reader
// or any of its peers.
func (s *Session) Subscribe() chan []byte {
	ch := make(chan []byte, 64)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

func (s *Session) Unsubscribe(ch chan []byte) {
	s.mu.Lock()
	if _, ok := s.subs[ch]; ok {
		delete(s.subs, ch)
		close(ch)
	}
	s.mu.Unlock()
}

// SubscriberCount returns the number of live binary PTY subscribers.
// Mirrors the `viewer_count` field of the `view: "status"` view_event
// and the top-level `status.viewers` envelope value.
func (s *Session) SubscriberCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.subs)
}

// Dimensions returns the current PTY rows and cols. Used by the
// `view: "status"` view_event mirror so late-joining viewers can
// render scrollback at the correct geometry without waiting for the
// next top-level status envelope.
func (s *Session) Dimensions() (rows, cols uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rows, s.cols
}

func (s *Session) SubscribeText() chan []byte {
	ch := make(chan []byte, 32)
	s.mu.Lock()
	s.textSubs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

func (s *Session) UnsubscribeText(ch chan []byte) {
	s.mu.Lock()
	if _, ok := s.textSubs[ch]; ok {
		delete(s.textSubs, ch)
		close(ch)
	}
	s.mu.Unlock()
}

// Snapshot returns a copy of the current scrollback (oldest-first)
// from the raw PTY ring. This is the legacy / fallback path used by
// the memory-html writer, tests, and clients that don't supply a
// target size.
func (s *Session) Snapshot() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.ringFull {
		out := make([]byte, s.ringPos)
		copy(out, s.ring[:s.ringPos])
		return out
	}
	out := make([]byte, ringSize)
	copy(out, s.ring[s.ringPos:])
	copy(out[ringSize-s.ringPos:], s.ring[:s.ringPos])
	return out
}

// SnapshotForSize returns a size-correct snapshot for the attaching
// client. If the headless xterm.js sidecar is available, the grid is
// reflowed to (targetRows, targetCols) first and then serialized,
// yielding bit-identical rendering on the client. If the sidecar is
// unavailable, errors, or returns empty, the ring snapshot is
// returned instead.
//
// If targetRows or targetCols is zero, the ring snapshot is used.
func (s *Session) SnapshotForSize(targetRows, targetCols uint16) []byte {
	if targetRows == 0 || targetCols == 0 {
		return s.Snapshot()
	}
	s.mu.Lock()
	tg := s.termgrid
	s.mu.Unlock()
	if tg == nil {
		return s.Snapshot()
	}
	if err := tg.Resize(s.ID, targetRows, targetCols); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: SnapshotForSize: resize: %v\n", s.ID, err)
		return s.Snapshot()
	}
	data, err := tg.Serialize(s.ID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "session %s: SnapshotForSize: serialize: %v\n", s.ID, err)
		return s.Snapshot()
	}
	if data == "" {
		return s.Snapshot()
	}
	// Also push the client's size into the PTY so the agent knows the
	// real viewport. Best-effort.
	_ = s.Resize(targetRows, targetCols)
	return []byte(data)
}

func (s *Session) WorkspaceDir() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.workspaceDir
}

// Close terminates the session. Idempotent.
// PublishText broadcasts an already-serialized JSON frame to every
// text subscriber. Same drop-oldest backpressure policy as fanout —
// the scraper must never block the PTY drain.
func (s *Session) PublishText(payload []byte) {
	// Record the view_event (if it is one) before fan-out. Re-parsing
	// the JSON here is cheap relative to the JSON.Marshal that
	// produced it, and keeps the recorder schema-stable (we record
	// `event` not the WS envelope, so the replay player can render
	// without re-decoding swe-kitty's WS shape).
	// Parse the view_event once and feed two sinks: the replay recorder
	// (full PTY+event stream, debug/replay) and the conversation log
	// (chat frames only, for reopening an exited session's transcript).
	// Re-parsing here is cheap relative to the Marshal that produced the
	// payload.
	{
		var frame struct {
			Type  string          `json:"type"`
			View  string          `json:"view"`
			Event json.RawMessage `json:"event"`
		}
		if err := json.Unmarshal(payload, &frame); err == nil && frame.Type == "view_event" {
			if s.recorder != nil {
				var evt any
				if uerr := json.Unmarshal(frame.Event, &evt); uerr == nil {
					s.recorder.RecordEvent(frame.View, evt, time.Now())
				}
			}
			// Persist assistant/tool/system chat messages. User prompts
			// are captured separately in SendChat (they never flow back
			// through PublishText).
			if frame.View == "chat" {
				s.convLog.appendRaw(frame.Event)
			}
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.textSubs {
		select {
		case ch <- payload:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- payload:
			default:
			}
		}
	}
}

// MarkUserChatSent primes the chat scraper to capture the next
// assistant reply. Called by the websocket chat handler right before
// the user's message is written into the PTY — i.e. the legacy
// TUI-scrape path (s.chat == nil), the structured path goes through
// SendChat instead.
//
// We also persist the user prompt here. On this path the assistant
// reply lands in conversation.jsonl via the scraper's chat view_event
// (PublishText → appendRaw), but the user's side never flows back
// through PublishText, so without this the reopened transcript would be
// one-sided (replies with no questions) — or empty when the very first
// turn hasn't replied yet. This mirrors what SendChat already does for
// the structured channel, so history works regardless of chat_mode.
func (s *Session) MarkUserChatSent(msg string) {
	s.convLog.appendUser(msg)
	if s.scraper != nil {
		s.scraper.markUserSent(msg)
	}
}

// SendChat routes a composer message to the structured chat channel when
// the session runs in stream-json mode (chat_mode="stream-json"). It
// returns true when it handled the message, so the websocket handler skips
// the legacy "write to PTY + scrape" path. Returns false for the default
// TUI path (the caller then does MarkUserChatSent + the PTY write).
func (s *Session) SendChat(msg string) bool {
	if s.chat == nil {
		return false
	}
	// Persist the user prompt before handing it to the agent — the
	// publish stream only carries the agent's side, so without this the
	// reopened transcript would show replies with no questions.
	s.convLog.appendUser(msg)
	// Capture the opening prompt (once) so the AI title generator can
	// summarize the conversation's purpose at the next turn-end.
	s.captureFirstUserPrompt(msg)
	if err := s.chat.Send(msg); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: chat send: %v\n", s.ID, err)
	}
	return true
}

func (s *Session) Close() {
	s.closeOnce.Do(func() {
		if s.chat != nil {
			// Stop the headless stream-json agent (closes stdin + kills
			// the process) so it doesn't outlive the session.
			_ = s.chat.Close()
		}
		if s.scraper != nil {
			// One last flush in case a reply was in flight when the
			// session ends, so the user still sees the assistant's
			// last turn.
			s.scraper.flush()
			s.scraper.stop()
		}
		_ = s.Checkpoint("exit")
		_ = s.pty.Close()
		exitCode := 0
		if s.cmd != nil && s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
		}
		if s.cmd != nil && s.cmd.Process != nil {
			state, _ := s.cmd.Process.Wait()
			if state != nil {
				exitCode = state.ExitCode()
			}
		}
		s.mu.Lock()
		s.exitCode = exitCode
		s.phase = "exited"
		s.reasonCode = "session_closed"
		s.mu.Unlock()
		_ = s.persistMetadata()
		_ = s.runHook(s.hooks.OnExit, map[string]string{
			"AGENT_NAME": s.Assistant,
			"EXIT_CODE":  fmt.Sprintf("%d", exitCode),
		})
		s.mu.Lock()
		for ch := range s.subs {
			close(ch)
		}
		for ch := range s.textSubs {
			close(ch)
		}
		s.subs = nil
		s.textSubs = nil
		tg := s.termgrid
		s.termgrid = nil
		s.mu.Unlock()
		if tg != nil {
			if err := tg.Delete(s.ID); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: termgrid.Delete: %v\n", s.ID, err)
			}
		}
		if s.recorder != nil {
			if err := s.recorder.Close(); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: replay.Close: %v\n", s.ID, err)
			}
			s.recorder = nil
		}
		// Best-effort cleanup of the per-session ephemeral $HOME so
		// rotated OAuth refresh tokens don't linger on disk after the
		// agent exits. Failure is logged and ignored — the worktree GC
		// will sweep it eventually.
		if s.agentHomeDir != "" {
			if err := os.RemoveAll(s.agentHomeDir); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: remove agent-home: %v\n", s.ID, err)
			}
		}
		close(s.closed)
	})
}

// Done returns a channel closed when the session ends.
func (s *Session) Done() <-chan struct{} { return s.closed }

// ReasoningEffort returns the per-agent label set in the adapter toml
// (e.g. "low" / "medium" / "high"). Returns "" when the toml didn't
// specify one; the ws layer falls back to "medium" so the iOS pill
// always has something to render.
func (s *Session) ReasoningEffort() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Surface the validated per-session override when the session was
	// forked onto a different effort; otherwise the adapter default.
	return s.override.effectiveEffort(s.Assistant, s.adapter.ReasoningEffort)
}

// DisplayName returns the human-readable session label set by the most
// recent `rename_session` JSON control. Empty string when no rename has
// been applied — clients should fall back to the session id or
// workspace dir for the title.
func (s *Session) DisplayName() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.displayName
}

// displayNameRegex is the validation rule documented in
// `WEBSOCKET-PROTOCOL.md` §3.3 — 1..32 chars from the ASCII safe set
// (letters, digits, space, underscore, hyphen). Whitespace-only and
// empty strings fail to match because the range is `{1,32}` and `^$`
// is excluded by the character class.
var displayNameRegex = regexp.MustCompile(`^[A-Za-z0-9 _-]{1,32}$`)

// SetDisplayName validates `name` against the §3.3 regex and stores it
// last-writer-wins. Returns true when the rename was accepted; false
// when the name failed validation (the broker silently ignores invalid
// renames per the protocol — the socket stays open).
//
// The regex permits ASCII space inside the character class so a name
// like "rust core" passes. The protocol notes further reject
// "whitespace-only strings" — the regex alone would accept "   " — so
// we trim and check non-empty separately. Empty / too-long / illegal
// chars are caught by the regex; whitespace-only is caught by the trim.
func (s *Session) SetDisplayName(name string) bool {
	if !displayNameRegex.MatchString(name) {
		return false
	}
	if strings.TrimSpace(name) == "" {
		return false
	}
	s.mu.Lock()
	s.displayName = name
	s.mu.Unlock()
	return true
}

// AITitle returns the broker AI-generated session title, or "" when none
// has been generated. Distinct from DisplayName (manual rename) — the
// apps prefer a manual rename over this title.
func (s *Session) AITitle() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.aiTitle
}

// applyAITitle stores the generated title, persists it to meta (so a
// relisted session survives a restart without re-generating), and emits a
// `view:"session_title"` view_event to every viewer so the apps update
// live. Called by the title generator on a successful generation. No-ops
// when the title is empty or unchanged so a refine that lands the same
// label doesn't spam viewers.
func (s *Session) applyAITitle(title string) {
	title = strings.TrimSpace(title)
	if title == "" {
		return
	}
	s.mu.Lock()
	if s.aiTitle == title {
		s.mu.Unlock()
		return
	}
	s.aiTitle = title
	s.mu.Unlock()
	_ = s.persistMetadata()
	s.publishAITitle(title)
}

// publishAITitle emits the `view:"session_title"` view_event carrying
// {session_id, title}. Mirrors the quick_replies shape so core
// transport.rs routes it through on_view_event to the apps.
func (s *Session) publishAITitle(title string) {
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "session_title",
		"event": map[string]any{
			"session_id": s.ID,
			"title":      title,
		},
	})
	if err != nil {
		return
	}
	s.PublishText(payload)
}

// captureFirstUserPrompt records the conversation's opening composer text
// (once) so the title generator has something to summarize. Idempotent:
// later prompts don't overwrite the first.
func (s *Session) captureFirstUserPrompt(msg string) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return
	}
	s.mu.Lock()
	if s.firstUserPrompt == "" {
		s.firstUserPrompt = msg
	}
	s.mu.Unlock()
}

// firstPrompt reads the captured opening user prompt (for the title
// generator's closure).
func (s *Session) firstPrompt() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.firstUserPrompt
}

func (s *Session) SwitchAdapter(assistant string) error {
	if s.switchFn == nil {
		return errors.New("switch_agent unavailable")
	}
	return s.switchFn(assistant)
}

func (s *Session) Switch(adapter agents.Adapter) error {
	return s.switchToAdapter(adapter)
}

func (s *Session) drain(f *os.File) {
	buf := make([]byte, 8192)
	for {
		n, err := f.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.append(chunk)
			s.fanout(chunk)
			if s.recorder != nil {
				// Best-effort: nil-safe inside the recorder, errors
				// only logged. Drain must never block on disk I/O.
				s.recorder.RecordBytes(chunk, time.Now())
			}
			if s.scraper != nil {
				s.scraper.feed(chunk)
			}
			s.mu.Lock()
			tg := s.termgrid
			s.mu.Unlock()
			if tg != nil {
				if werr := tg.Write(s.ID, chunk); werr != nil {
					// Best-effort — log and continue. Ring is still
					// authoritative for live streaming.
					fmt.Fprintf(os.Stderr, "session %s: termgrid.Write: %v\n", s.ID, werr)
				}
			}
		}
		if err != nil {
			s.mu.Lock()
			stillCurrent := s.pty == f && !s.swapping
			s.mu.Unlock()
			if !stillCurrent {
				return
			}
			s.Close()
			return
		}
	}
}

func (s *Session) append(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastOutput = time.Now().UTC()
	for _, b := range p {
		s.ring[s.ringPos] = b
		s.ringPos++
		if s.ringPos == ringSize {
			s.ringPos = 0
			s.ringFull = true
		}
	}
}

func (s *Session) fanout(p []byte) {
	s.mu.Lock()
	droppedThisCall := 0
	for ch := range s.subs {
		select {
		case ch <- p:
		default:
			// slow subscriber; drop oldest by draining once, then
			// retry the send. If the retry still fails the chunk is
			// dropped — that's the contract: PTY reader never blocks.
			select {
			case <-ch:
				droppedThisCall += len(p)
			default:
			}
			select {
			case ch <- p:
			default:
				droppedThisCall += len(p)
			}
		}
	}
	logNow := false
	logCount := 0
	if droppedThisCall > 0 {
		s.droppedBytes += droppedThisCall
		now := time.Now()
		if now.Sub(s.lastDroppedAt) >= time.Second {
			logNow = true
			logCount = s.droppedBytes
			s.droppedBytes = 0
			s.lastDroppedAt = now
		}
	}
	s.mu.Unlock()
	if logNow {
		fmt.Fprintf(os.Stderr, "session %s: dropped %d bytes for slow subscriber(s)\n", s.ID, logCount)
	}
}

// Manager owns the lookup table of sessions.
type Manager struct {
	mu             sync.RWMutex
	sessions       map[string]*Session
	recentProjects []RecentProject
	registry       *agents.Registry
	repoRoot       string
	kittyRoot      string

	// termgrid is the optional headless xterm.js sidecar. nil when node
	// isn't installed at startup. Shared by all sessions.
	termgrid *termgrid.Manager

	// replayBaseDir, when non-empty, is propagated to every session's
	// recorder so PTY bytes + view_events are persisted under
	// `<replayBaseDir>/<id>/replay.json`. Set via SetReplayBaseDir
	// from cmd/swe-kitty-broker — empty in unit tests by default.
	replayBaseDir string

	// stopGC closes when Manager.Close is called; the background GC
	// goroutine watches it to exit cleanly.
	stopGC chan struct{}

	// credStore is the per-identity OAuth credential store wired in
	// from cmd/swe-kitty-broker (see docs/PLAN-AGENT-OAUTH.md §G).
	// nil-safe: when nil, every session spawn falls back to the
	// legacy global host-mirror behaviour and no agent-home dir is
	// created. Manager owns the pointer because the WS layer wires
	// it in at startup; sessions read it through commandEnv.
	credStore *credentials.Store
}

// SetCredentialStore wires the per-identity OAuth credential store into
// the manager. Called from cmd/swe-kitty-broker once the store is
// constructed. nil clears it (mostly useful for tests).
func (m *Manager) SetCredentialStore(s *credentials.Store) {
	m.mu.Lock()
	m.credStore = s
	m.mu.Unlock()
}

// SetReplayBaseDir enables replay recording for sessions created
// after the call. Existing sessions keep whatever recorder state they
// had at construction. Pass an empty string to disable for any
// future creates.
func (m *Manager) SetReplayBaseDir(dir string) {
	m.mu.Lock()
	m.replayBaseDir = strings.TrimSpace(dir)
	m.mu.Unlock()
}

// ReplayBaseDir returns the currently configured replay base
// directory ("" when disabled). Mostly used by the broker entry
// point to log the resolved path at startup.
func (m *Manager) ReplayBaseDir() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.replayBaseDir
}

type CreateOptions struct {
	CWD string
	// Override carries the optional reasoning-effort / model override
	// applied when this session is created (fork-onto-different-model).
	// Zero value = adapter defaults unchanged. Honored only on create.
	Override SpawnOverride
}

func NewManager(registry *agents.Registry) *Manager {
	repoRoot, kittyRoot, _ := resolveKittyRoots()
	m := &Manager{
		sessions:  make(map[string]*Session),
		registry:  registry,
		repoRoot:  repoRoot,
		kittyRoot: kittyRoot,
		stopGC:    make(chan struct{}),
	}
	if strings.TrimSpace(os.Getenv("SWE_KITTY_DISABLE_SIDECAR")) == "" {
		tg, err := termgrid.NewManager()
		if err != nil {
			if errors.Is(err, termgrid.ErrNoNode) {
				fmt.Fprintln(os.Stderr, "session: node not on PATH — running with ring-only snapshots (no client-size reflow)")
			} else {
				fmt.Fprintf(os.Stderr, "session: termgrid.NewManager: %v — running with ring-only snapshots\n", err)
			}
		} else {
			m.termgrid = tg
		}
	}
	m.loadRecentProjects()
	m.startGCLoop(m.stopGC)
	return m
}

// Health reports whether the broker is fully operational.
//   - `Live` is always true if the broker process is responding (this
//     function returns) — kept so the response shape never collapses.
//   - `SidecarExpected` mirrors the "did node exist at startup" check
//     in NewManager. A false here is fine; it just means scrollback
//     replay is ring-only and we shouldn't fault the sidecar absence.
//   - `SidecarHealthy` is true only when the headless xterm.js sidecar
//     answers a Ping within the termgrid manager's existing timeout.
//     Surfaces silent sidecar crashes that today only manifest as
//     garbled snapshots in the iOS terminal tab.
type Health struct {
	Live            bool
	SidecarExpected bool
	SidecarHealthy  bool
	SidecarError    string
}

func (m *Manager) Health() Health {
	m.mu.RLock()
	tg := m.termgrid
	m.mu.RUnlock()
	h := Health{Live: true, SidecarExpected: tg != nil}
	if tg == nil {
		return h
	}
	if _, err := tg.Ping(); err != nil {
		h.SidecarError = err.Error()
		return h
	}
	h.SidecarHealthy = true
	return h
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

func (m *Manager) AssistantNames() []string {
	return m.registry.Names()
}

// ConversationLog returns the persisted conversation transcript for a
// session id, read from `<kittyRoot>/sessions/<id>/conversation.jsonl`.
// Works for both live and exited sessions — both append to the same
// on-disk log, which survives reap — so the app can reopen a past
// session read-only. Returns an error only when no log exists for the id.
//
// Falls back to `<kittyRoot>/archived-sessions/<id>/conversation.jsonl`
// when the active dir has none, so a session deleted (archived) via
// DeleteSession stays reachable read-only — the delete preserves the
// transcript, it just takes the session out of the active set.
func (m *Manager) ConversationLog(id string) ([]ConvEntry, error) {
	if id == "" {
		return nil, os.ErrNotExist
	}
	entries, err := readConvLog(filepath.Join(m.kittyRoot, "sessions", id, "conversation.jsonl"))
	if err == nil {
		return entries, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return readConvLog(filepath.Join(m.kittyRoot, archivedSessionsDirName, id, "conversation.jsonl"))
}

// GetOrCreate returns the existing session for id, or starts a new one
// with the given assistant. assistant is honored only on creation.
func (m *Manager) GetOrCreate(id, assistant string) (*Session, bool, error) {
	return m.GetOrCreateWithOptions(id, assistant, CreateOptions{})
}

// GetOrCreateWithOptions is like GetOrCreate but accepts creation options.
// Options are honored only when a new session is created.
func (m *Manager) GetOrCreateWithOptions(id, assistant string, opts CreateOptions) (*Session, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.sessions[id]; ok {
		return s, false, nil
	}
	if m.sessionOnDisk(id) {
		s, err := m.recoverSessionLocked(id)
		if err == nil {
			return s, false, nil
		}
	}
	adapter, err := m.registry.Get(assistant)
	if err != nil {
		return nil, false, err
	}
	requestedCWD := strings.TrimSpace(opts.CWD)
	if requestedCWD != "" {
		if !filepath.IsAbs(requestedCWD) {
			return nil, false, fmt.Errorf("invalid cwd %q: must be an absolute path", requestedCWD)
		}
		if !dirExists(requestedCWD) {
			return nil, false, fmt.Errorf("invalid cwd %q: directory does not exist", requestedCWD)
		}
	}
	s, err := newSession(id, adapter, sessionOptions{
		repoRoot:      m.repoRoot,
		kittyRoot:     m.kittyRoot,
		requestedCWD:  requestedCWD,
		termgrid:      m.termgrid,
		replayBaseDir: m.replayBaseDir,
		credStore:     m.credStore,
		override:      opts.Override,
	})
	if err != nil {
		return nil, false, err
	}
	s.switchFn = func(next string) error {
		nextAdapter, err := m.registry.Get(next)
		if err != nil {
			return err
		}
		return s.Switch(nextAdapter)
	}
	m.sessions[id] = s
	m.recordRecentProjectLocked(s.WorkspaceDir(), s.Assistant, s.ID)
	go func() {
		<-s.Done()
		m.mu.Lock()
		delete(m.sessions, id)
		m.mu.Unlock()
	}()
	return s, true, nil
}

func (m *Manager) Recover() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(m.kittyRoot, "sessions"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	recovered := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		if _, ok := m.sessions[id]; ok {
			continue
		}
		s, err := m.recoverSessionLocked(id)
		if err != nil {
			continue
		}
		recovered = append(recovered, s.ID)
	}
	slices.Sort(recovered)
	return recovered, nil
}

func (m *Manager) Close() {
	m.mu.Lock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		sessions = append(sessions, s)
	}
	tg := m.termgrid
	m.termgrid = nil
	stopGC := m.stopGC
	m.stopGC = nil
	m.mu.Unlock()
	if stopGC != nil {
		// Idempotent: Close-after-Close is rare but harmless.
		select {
		case <-stopGC:
		default:
			close(stopGC)
		}
	}
	for _, s := range sessions {
		s.Close()
	}
	if tg != nil {
		_ = tg.Close()
	}
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

type sessionOptions struct {
	repoRoot       string
	kittyRoot      string
	snapshot       []byte
	lastCheckpoint time.Time
	handoffHTML    string
	requestedCWD   string
	termgrid       *termgrid.Manager
	// replayBaseDir, when non-empty, enables per-session replay
	// recording under `<replayBaseDir>/<sessionID>/replay.json`.
	// Manager fills this in from its own field; tests can leave it
	// empty to keep recording off.
	replayBaseDir string
	// credStore, when non-nil, drives per-session OAuth credential
	// materialization (docs/PLAN-AGENT-OAUTH.md §G). nil → the
	// legacy host-mirror $HOME behaviour. Manager fills this in
	// from its own field; tests typically leave it empty.
	credStore *credentials.Store
	// override carries the optional reasoning-effort / model override
	// applied to the spawned agent's argv. Zero value = adapter
	// defaults unchanged (the normal start path).
	override SpawnOverride
}

type sessionMetadata struct {
	ID             string `json:"id"`
	Assistant      string `json:"assistant"`
	Rows           uint16 `json:"rows"`
	Cols           uint16 `json:"cols"`
	Phase          string `json:"phase"`
	Health         string `json:"health"`
	ReasonCode     string `json:"reason_code,omitempty"`
	ExitCode       int    `json:"exit_code,omitempty"`
	LastCheckpoint string `json:"last_checkpoint,omitempty"`
	// AITitle is the broker AI-generated title (task: ai-session-titles),
	// persisted so a reopened/relisted session keeps it without
	// re-generating. omitempty: pre-feature sessions simply have no title.
	AITitle string `json:"ai_title,omitempty"`
}

func (s *Session) applyPaths() {
	s.sessionDir = filepath.Join(s.kittyRoot, "sessions", s.ID)
	s.convLog = newConvLogger(filepath.Join(s.sessionDir, "conversation.jsonl"))
	s.worktreeDir = filepath.Join(s.sessionDir, "work")
	s.scrollbackPath = filepath.Join(s.sessionDir, "scrollback.bin")
	s.metaPath = filepath.Join(s.sessionDir, "meta.json")
	s.memoryPath = filepath.Join(s.kittyRoot, "memory", "sessions", s.ID+".html")
	s.handoffPath = filepath.Join(s.worktreeDir, ".swe-kitty", "HANDOFF.html")
	s.handoffOutPath = filepath.Join(s.worktreeDir, ".swe-kitty", "HANDOFF-OUT.html")
}

func (s *Session) persistMetadata() error {
	s.mu.Lock()
	meta := sessionMetadata{
		ID:         s.ID,
		Assistant:  s.Assistant,
		Rows:       s.rows,
		Cols:       s.cols,
		Phase:      s.phase,
		Health:     s.health,
		ReasonCode: s.reasonCode,
		ExitCode:   s.exitCode,
		AITitle:    s.aiTitle,
	}
	if !s.lastCheckpoint.IsZero() {
		meta.LastCheckpoint = s.lastCheckpoint.UTC().Format(time.RFC3339Nano)
	}
	s.mu.Unlock()
	return atomicWriteJSON(s.metaPath, meta)
}

func atomicWriteJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(path, append(data, '\n'))
}

func resolveKittyRoots() (string, string, error) {
	if root := strings.TrimSpace(os.Getenv("SWE_KITTY_ROOT")); root != "" {
		abs, err := filepath.Abs(root)
		if err != nil {
			return "", "", err
		}
		return filepath.Dir(abs), abs, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	cur := wd
	for {
		if dirExists(filepath.Join(cur, ".git")) || dirExists(filepath.Join(cur, ".swe-kitty")) {
			return cur, filepath.Join(cur, ".swe-kitty"), nil
		}
		next := filepath.Dir(cur)
		if next == cur {
			return wd, filepath.Join(wd, ".swe-kitty"), nil
		}
		cur = next
	}
}
