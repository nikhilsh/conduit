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
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/credentials"
	"github.com/nikhilsh/conduit/broker/internal/push"
	"github.com/nikhilsh/conduit/broker/internal/replay"
	"github.com/nikhilsh/conduit/broker/internal/termgrid"
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

	repoRoot        string
	conduitRoot     string
	sessionDir      string
	worktreeDir     string
	scrollbackPath  string
	memoryPath      string
	metaPath        string
	handoffPath     string
	handoffOutPath  string
	checkpointEvery time.Duration
	watchdogEvery   time.Duration
	stallAfter      time.Duration
	handoffTimeout  time.Duration
	workspaceDir    string
	requestedCWD    string
	// previewPort is the per-session dev-server port (3000–3019) exported to
	// the agent as $PORT and reverse-proxied to the app via `/preview/<id>/`.
	// 0 when the pool was exhausted at create time (the session simply has no
	// preview). Set once under Manager.mu before the session is shared, then
	// read-only — safe to read without s.mu.
	previewPort int
	// previewCfg caches the parsed `.conduit/preview.json` override (see
	// preview.go); previewCfgMod/Path key the cache so it's re-read only when
	// the file changes. Guarded by s.mu.
	previewCfg     previewConfig
	previewCfgMod  time.Time
	previewCfgPath string
	// previewDetectedPort caches the last auto-detected dev-server port (the
	// port the session's process tree was found listening on). Refreshed on
	// the status-frame cadence so the proxy hot path needn't rescan /proc.
	// Guarded by s.mu.
	previewDetectedPort int
	reasonCode          string
	exitCode            int
	hooks               agents.Hooks
	phase               string
	health              string
	lastOutput          time.Time
	lastCheckpoint      time.Time
	startedAt           time.Time
	// spawnedAt is when THIS agent process started. Unlike startedAt it
	// is never restored from metadata on recovery — it anchors the
	// fast-exit detection in restartbudget.go.
	spawnedAt time.Time
	// consecutiveFastExits counts agent deaths within fastExitWindow of
	// spawn (persisted across recoveries; reset by any healthy run).
	// At maxConsecutiveFastExits the session refuses to respawn.
	consecutiveFastExits int
	// closing marks an intentional Close() in progress so drain's EOF
	// wakeup doesn't count the teardown as an agent crash.
	closing bool
	// Per-session token/cost usage, folded from each turn's usage event
	// (claude `result` / codex `turn.completed`). Guarded by mu; surfaced
	// via Usage() into the status frame. See usage.go.
	totalInputTokens    uint64
	totalOutputTokens   uint64
	totalCachedTokens   uint64
	totalCostUSD        float64
	contextUsedTokens   uint64
	contextWindowTokens uint64
	hasUsage            bool
	// Per-session "outcome" stats (OutcomeChips) computed from the workspace
	// git repo + `gh`. Guarded by mu; surfaced via Outcome() into the status
	// frame, refreshed by the watchdog loop. See outcome.go. `startCommit` is
	// the git HEAD captured at session create so diffs measure only this
	// session's work.
	startCommit         string
	outcomeHasGit       bool
	outcomeLinesAdded   int
	outcomeLinesRemoved int
	outcomeCommits      int
	outcomePRNumber     int
	outcomePRState      string
	outcomePRURL        string // web URL of the PR/MR (pr_url in status frame)
	outcomePRProvider   string // "github" | "gitlab" | ""
	outcomeGitAt        time.Time
	outcomePRAt         time.Time
	// Account-level subscription usage (5-hour + weekly windows) — the data
	// behind the on-demand /usage feature. Guarded by mu; surfaced via
	// AccountUsage() into the status frame, fetched from the OAuth endpoint on
	// connect + on an explicit client refresh. See accountusage.go.
	// accountUsageDo is an injectable HTTP doer (nil → http.DefaultClient).
	accountUsage      AccountUsage
	accountUsageDo    httpDoFunc
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

	// gitStateCache caches the live git state (branch/dirty/ahead/behind)
	// computed for the session's workspace directory so the hot status-emit
	// path doesn't shell out on every broadcast. See gitstate.go.
	gitStateCache sessionGitCache

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
	// chatRespawn re-creates the long-lived stream-json chat process
	// after it died underneath us (crash/OOM while the app was
	// backgrounded). Set only for the claude backend — codex spawns
	// per-turn and needs no respawn. nil → no self-heal, errors surface
	// via the system chat message in SendChat.
	chatRespawn func() (chatBackend, error)
	// pendingAsk is a blocked AskUserQuestion control request waiting
	// for the user's answer (askcontrol.go). Guarded by mu.
	pendingAsk *pendingAsk

	// subagents is the per-session registry of spawned subagents, updated
	// from system/task_* stream-json frames via the subagentRegistryHandle
	// in the claude chat process pump. Guarded by mu. Non-nil from session
	// create time so the handle can safely acquire mu without nil checks.
	subagents *subagentRegistry

	// connectedOwnerCount tracks how many WS clients whose device_id equals
	// this session's OwnerDeviceID are currently connected. Guarded by mu.
	// Used by the push-gate: suppress alert push only when the owner device
	// is actively watching (not when any arbitrary subscriber is present).
	// Zero for sessions with no OwnerDeviceID (legacy path uses SubscriberCount).
	connectedOwnerCount int

	// pushState holds the per-session push-notification state (notifier,
	// identity, and debounce latches). See push_notify.go. Has its own
	// mutex so the push path never nests under s.mu.
	pushState pushNotifyState
	// laState holds the per-session Live Activity push state (LA token
	// registry, sender, content-state fields, and debounce latch).
	// See push_notify.go. Has its own mutex.
	laState laPushState
	// chatSessionID is the claude CLI's OWN conversation id, latched
	// from the stream-json init line and persisted (meta.json) so a
	// respawned agent --resumes the conversation instead of starting
	// amnesiac. Guarded by mu.
	chatSessionID string
	// turnPhase is the sub-state of the current in-flight agent turn:
	// "writing" | "working" | "thinking" | "" (none/idle).
	// Set by the onTurnPhase closure in backend_streamjson.go; guarded by mu.
	turnPhase string
	// codexThreadID is codex's equivalent (thread.started id), persisted
	// so recovery seeds `exec resume <id>`. Guarded by mu.
	codexThreadID string

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

	// kbSurfaced tracks which knowledge-base slugs the per-turn relevance
	// hook (kbrelevance.go) has already injected into THIS session's prompts,
	// so a long session never re-surfaces the same hint turn after turn.
	// Guarded by mu; lazily initialized on first use.
	kbSurfaced map[string]bool

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
	// agentCredProvider is the OAuth provider key whose credentials were
	// (attempted to be) populated into agentHomeDir ("anthropic" /
	// "openai", "" when the adapter has no OAuth flow). Set once at
	// spawn before the session is shared; read-only after — drives the
	// watchdog's stale-credential re-mirror (credfresh.go).
	agentCredProvider string
	// agentCredStore is the credential store used at spawn time. Retained
	// so the watchdog can re-materialize an app-pushed blob into sessions
	// that spawned BEFORE the app credential arrived (credfresh.go).
	// nil when no store was wired (legacy host-mirror path).
	agentCredStore *credentials.Store
	// sharedCredConfigEnv carries the CONDUIT_SHARED_AGENT_CREDS config-dir
	// relocation env vars (CLAUDE_CONFIG_DIR / CODEX_HOME → canonical dir)
	// to inject in commandEnv. Populated at spawn ONLY when the flag is on;
	// nil/empty on the default (flag-off) per-session-copy path, which keeps
	// commandEnv byte-for-byte unchanged. See credseed.go.
	sharedCredConfigEnv map[string]string
	// sharedCredHome is the credential lookup home chosen for this session
	// under CONDUIT_SHARED_AGENT_CREDS: the operator's real $HOME (Option A)
	// or the broker-owned <conduitRoot>/agent-cred dir (Option B). Its
	// .claude/.codex subpaths hold the live credential the broker-side
	// fetchers read. Empty on the flag-off path (fetchers use agentHomeDir).
	sharedCredHome string
	// sharedCredOptionA records whether sharedCredHome IS the operator's real
	// $HOME (read-through, no broker writes). Diagnostic / future use.
	sharedCredOptionA bool
	// credentialSource records which credential was used at spawn time:
	// "box" when the host login (~/.claude/.credentials.json etc.) was
	// used, "app_forwarded" when the app-pushed OAuth blob was
	// materialized. Empty when no credential is present at all. Set once
	// at spawn before the session is shared; read-only after.
	credentialSource string

	// modelCatalog returns the Manager's discovered model catalog snapshot
	// (Manager.ModelCatalog), used to pick the smallest codex model for the
	// AI-niceties (titles + quick replies) codexGen. nil → no catalog, and
	// codexGen falls back to codex's default model.
	modelCatalog func() map[string][]ModelInfo

	// codexBinary returns the codex CLI binary path (registry-resolved),
	// used so a claude session with no anthropic creds can fall back to the
	// codex AI-niceties provider. nil/"" → no codex fallback.
	codexBinary func() string

	// claudeBinary returns the claude CLI binary path (registry-resolved),
	// used by the external-resume recap one-shot (`claude --resume … --print`).
	// nil/"" → recap falls back to the deterministic note.
	claudeBinary func() string

	// aiGen is the per-session AI-niceties provider (nil when no creds).
	// Stored at startChatBackend time so push_notify.go can use it for
	// AI-rewritten notification bodies without needing a spawnRequest.
	// Guarded by mu.
	aiGen aiGenProvider
}

func New(id string, adapter agents.Adapter) (*Session, error) {
	repoRoot, conduitRoot, err := resolveConduitRoots()
	if err != nil {
		return nil, err
	}
	return newSession(id, adapter, sessionOptions{
		repoRoot:    repoRoot,
		conduitRoot: conduitRoot,
	})
}

func newSession(id string, adapter agents.Adapter, opts sessionOptions) (*Session, error) {
	var cmd *exec.Cmd
	if _, err := backendFor(adapter.Protocol); err == nil {
		// B-i: a structured protocol runs the agent headless (started
		// below as a chatBackend); the PTY hosts an interactive shell
		// for the Terminal tab.
		//
		// Back the Terminal-tab shell with a per-session tmux session
		// keyed by the session ID so the terminal — and its scrollback —
		// survives a disconnect or app-background: the PTY's shell can
		// die and re-attach, but tmux keeps the real shell alive between
		// attaches. When tmux isn't on PATH we fall back to plain bash
		// with no behaviour change (terminalShellArgv handles both).
		//
		// CONDUIT_DISABLE_TERMINAL_TMUX forces the plain-bash fallback even
		// when tmux IS on PATH. Unit tests set it (see TestMain) so they
		// never spawn real tmux sessions on the shared tmux server — those
		// would leak past the test exactly as the old `kitty-switch-chat`
		// orphan did, since a test tears its Manager down with Close() (no
		// per-session DeleteSession that would reap the tmux).
		tmuxPath, _ := exec.LookPath("tmux")
		if os.Getenv("CONDUIT_DISABLE_TERMINAL_TMUX") != "" {
			tmuxPath = ""
		}
		argv := terminalShellArgv(tmuxPath, sanitizeTmuxName(id))
		cmd = exec.Command(argv[0], argv[1:]...)
	} else {
		// Apply the optional reasoning-effort / model override after the
		// adapter's own args. Empty override → adapter.Args unchanged, so
		// the normal start path is byte-for-byte identical to before.
		ptyArgs := append(append([]string{}, adapter.Args...), opts.override.extraArgsForAdapter(adapter)...)
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
		conduitRoot:  opts.conduitRoot,
		previewPort:  opts.previewPort,
		modelCatalog: opts.modelCatalog,
		codexBinary:  opts.codexBinary,
		claudeBinary: opts.claudeBinary,
		requestedCWD: strings.TrimSpace(opts.requestedCWD),
		checkpointEvery: durationFromEnv(
			"CONDUIT_SESSION_CHECKPOINT_INTERVAL_MS",
			60*time.Second,
		),
		watchdogEvery: durationFromEnv(
			"CONDUIT_SESSION_WATCHDOG_INTERVAL_MS",
			30*time.Second,
		),
		stallAfter: durationFromEnv(
			"CONDUIT_SESSION_STALL_AFTER_MS",
			5*time.Minute,
		),
		handoffTimeout: durationFromEnv(
			"CONDUIT_SESSION_HANDOFF_TIMEOUT_MS",
			250*time.Millisecond,
		),
		hooks:      adapter.Hooks,
		phase:      "running",
		health:     "healthy",
		reasonCode: "ok",
		lastOutput: time.Now().UTC(),
		startedAt:  time.Now().UTC(),
		spawnedAt:  time.Now().UTC(),
		subagents:  newSubagentRegistry(),
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
	// Optionally run the session in its own per-session git worktree (off by
	// default; see worktree.go). Fail-safe: returns the original dir on any
	// problem, so a worktree issue never blocks a session from starting.
	s.workspaceDir = s.maybeRemapToWorktree(s.commandDir(adapter))
	cmd.Dir = s.workspaceDir
	// Capture the workspace git HEAD now so OutcomeChips diffs measure only
	// what this session changes (see outcome.go). Cheap; no-op when the cwd
	// isn't a git repo.
	s.recordStartCommit()
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
	// Use the adapter manifest's login_provider (WS-1.2). Falls back to
	// providerForAssistant(adapter.Name) via applyLegacyDefaults so
	// third-party adapters without the field behave as before.
	provider := adapter.LoginProvider
	// Keep the ephemeral HOME in the broker's per-session storage, NOT under
	// s.workspaceDir — workspaceDir is now the user's selected project folder
	// (cwd), and dropping a .conduit/agent-home dir full of copied OAuth
	// credentials into their repo would both pollute the working tree and
	// risk committing secrets.
	ephemeral := filepath.Join(s.sessionDir, "agent-home")
	if err := os.MkdirAll(ephemeral, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: agent-home mkdir: %v (agent will inherit broker $HOME)\n", s.ID, err)
	} else {
		s.agentHomeDir = ephemeral
		s.agentCredProvider = provider
		s.agentCredStore = opts.credStore
		if sharedAgentCredsEnabled() {
			// CONDUIT_SHARED_AGENT_CREDS (doc PLAN-AGENT-CREDENTIAL-LINEAGE.md):
			// do NOT fork the credential into a per-session copy. Resolve ONE
			// canonical config dir per provider (Option A = operator's real
			// ~/.claude/~/.codex when a host login exists; Option B = a
			// broker-owned dir seeded from the app blob otherwise) and point
			// the session at it via the CLI's own relocation env var. Every
			// session in the race shares one lineage head, so the agent CLIs'
			// cross-process refresh coordination — not a broker copy — governs
			// refreshes, and the operator's host login is never stranded.
			//
			// Seed BOTH providers (anthropic + openai) so the interactive
			// Terminal tab is logged into whichever CLI the user runs, matching
			// the flag-off "mirror every provider" loop below.
			res, seedErr := ensureSharedCred(s.conduitRoot, opts.credStore)
			if seedErr != nil {
				// Non-fatal (doc §8 fail-safe): the env still points at the
				// resolved dirs; the agent prompts /login if a file is absent.
				fmt.Fprintf(os.Stderr, "session %s: ensureSharedCred: %v (agent may prompt for login)\n", s.ID, seedErr)
			}
			credEnv, configDirs := sharedCredEnvFrom(res)
			s.sharedCredConfigEnv = credEnv
			s.sharedCredHome = res.home
			s.sharedCredOptionA = res.optionA
			// Seed the per-build .claude.json (theme/onboarding) into a
			// broker-owned CLAUDE_CONFIG_DIR too (NO-OP under Option A). The
			// $HOME/.claude.json seed below still runs for all builds.
			if err := seedClaudeCanonicalConfig(res); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: seedClaudeCanonicalConfig: %v\n", s.ID, err)
			}
			if err := seedClaudeConfig(ephemeral); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: seedClaudeConfig: %v (agent may show first-run theme picker)\n", s.ID, err)
			}
			// credential_source banner: derive from the session's own provider's
			// canonical resolution ("app_forwarded" when seeded from the pushed
			// blob, "box" when pointing at the host login).
			if provider != "" {
				if label := res.sourceLabel[provider]; label != "" {
					s.credentialSource = label
					log.Printf("session %s: credential_source=%s (provider=%s, shared-creds)", s.ID, label, provider)
				}
			}
			// Resume staging targets the canonical dir under the flag (doc §3.6).
			realHome := hostHomeDir()
			if er := opts.externalResume; er.ExternalID != "" {
				stageExternalTranscriptInto(configDirs, ephemeral, realHome, er.Agent, er.ExternalID)
				seedResumeRecap(s.convLog.path, er.Agent, er.ExternalID, ephemeral, s.recapBinary(er.Agent))
			}
			if ef := opts.externalFork; ef.ExternalID != "" {
				stageExternalTranscriptInto(configDirs, ephemeral, realHome, ef.Agent, ef.ExternalID)
				seedResumeRecap(s.convLog.path, ef.Agent, ef.ExternalID, ephemeral, s.recapBinary(ef.Agent))
			}
		} else {
			// ── Default (CONDUIT_SHARED_AGENT_CREDS OFF) ── today's behaviour,
			// byte-for-byte: each session gets a PRIVATE copy of the credential
			// (credStore.Materialize OR mirrorHostCredentials), the every-other-
			// provider mirror loop, and the credfresh.go watchdog re-mirror. This
			// apparatus is intentionally retained as the else-branch; its deletion
			// is a deliberate FOLLOW-UP after the flag's live items pass (doc §7).
			populated := false
			if opts.credStore != nil && provider != "" && opts.credStore.Has(provider) {
				// Stale-blob guard (credfresh.go): an app-pushed blob whose
				// token already expired can't be refreshed by the agent
				// (Anthropic rotates refresh tokens, and the host login has
				// long since consumed this lineage's) — materializing it
				// verbatim yields a session that 401s on every turn while
				// the box itself is happily logged in. Prefer the host
				// login when it's strictly fresher than an expired blob.
				useBlob := true
				if blob, err := opts.credStore.Get(provider); err == nil {
					if skip, blobExp, hostExp := useHostOverAppBlob(provider, blob); skip {
						useBlob = false
						fmt.Fprintf(os.Stderr, "session %s: stored %s OAuth blob expired (expiry %d < host %d); using host credentials\n", s.ID, provider, blobExp, hostExp)
					}
				}
				if useBlob {
					if err := opts.credStore.Materialize(provider, ephemeral); err != nil {
						fmt.Fprintf(os.Stderr, "session %s: credentials.Materialize(%s): %v (falling back to host-creds copy)\n", s.ID, provider, err)
					} else {
						populated = true
					}
				}
			}
			if !populated && provider != "" {
				if err := mirrorHostCredentials(provider, ephemeral); err != nil {
					// Non-fatal: agent will see an empty HOME and prompt
					// for login. Clean error path; no race with peers.
					fmt.Fprintf(os.Stderr, "session %s: mirrorHostCredentials(%s): %v (agent will prompt for login)\n", s.ID, provider, err)
				}
			}
			// Detect which credential was actually used so the app can show a
			// banner when it is supplying the credential as a fallback.
			if provider != "" {
				if populated {
					s.credentialSource = "app_forwarded"
					log.Printf("session %s: credential_source=app_forwarded (provider=%s)", s.ID, provider)
				} else if hf := hostCredentialFile(provider); hf != "" {
					if _, err := os.Stat(hf); err == nil {
						s.credentialSource = "box"
						log.Printf("session %s: credential_source=box (provider=%s)", s.ID, provider)
					}
				}
			}
			// The interactive Terminal tab runs under this SAME ephemeral HOME.
			// If we only materialized the session's own agent provider, the user
			// would find `claude`/`codex` LOGGED OUT in the terminal of any
			// session whose agent differs — a `shell` session (no provider at
			// all), or running `codex` inside a claude session and vice-versa —
			// even though the box itself is logged in. Mirror the host login for
			// every OTHER known provider too so the terminal is always logged in
			// for whatever CLI the user runs. Host-creds only (the app-blob path
			// stays reserved for the agent's own provider above), best-effort,
			// and quiet on the common "host isn't logged into that agent" case.
			// Each session keeps its own private copy, so this does NOT
			// reintroduce the cross-session refresh-token race.
			allProviders := opts.credentialProviders
			if len(allProviders) == 0 {
				allProviders = allCredentialProviders()
			}
			for _, p := range allProviders {
				if p == provider {
					continue // already materialized above (possibly via app blob)
				}
				_ = mirrorHostCredentials(p, ephemeral)
			}
			// Redirect .claude/projects to a stable, non-GC'd per-project store so
			// agent memory persists across sessions (Option A, docs/PLAN-AGENT-MEMORY-PERSISTENCE.md).
			// Must run BEFORE seedClaudeConfig and stageExternalTranscript so that
			// both the seeded .claude.json and staged transcripts land in the shared
			// store and are discoverable by future sessions. Best-effort: a failure
			// is logged and the session continues with today's ephemeral behaviour.
			if err := linkPersistentAgentState(ephemeral, s.conduitRoot, provider, s.workspaceDir); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: linkPersistentAgentState: %v (falling back to ephemeral projects)\n", s.ID, err)
			}
			// Seed a theme + onboarding marker so Claude Code's first-run
			// interactive theme picker doesn't block the PTY — for the agent AND
			// for an interactive `claude` the user runs in the Terminal tab of a
			// non-claude session. Harmless for codex (no equivalent prompt); the
			// file only matters to claude. Non-fatal.
			if err := seedClaudeConfig(ephemeral); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: seedClaudeConfig: %v (agent may show first-run theme picker)\n", s.ID, err)
			}
			// Stage the external conversation transcript into the isolated agent-home
			// so --resume / exec resume can find it. External sessions (Found Sessions
			// adopt-resume / adopt-fork) store their transcripts in the broker's real
			// $HOME (~/.claude/projects/…  or  ~/.codex/sessions/…), but the agent
			// runs with HOME=<ephemeral> and can't see them. Copy the file before the
			// agent launches. Best-effort: a miss is logged but never blocks the spawn.
			realHome := hostHomeDir()
			if er := opts.externalResume; er.ExternalID != "" {
				stageExternalTranscript(ephemeral, realHome, er.Agent, er.ExternalID)
				// Seed the new session's chat log with an agent-WRITTEN recap of the
				// prior transcript so the Chat tab opens showing "what we were doing"
				// rather than appearing empty. Bounded + best-effort: never blocks
				// the spawn past recapTimeout, falls back to a deterministic note.
				seedResumeRecap(s.convLog.path, er.Agent, er.ExternalID, ephemeral, s.recapBinary(er.Agent))
			}
			if ef := opts.externalFork; ef.ExternalID != "" {
				stageExternalTranscript(ephemeral, realHome, ef.Agent, ef.ExternalID)
				// Same recap for fork: the user branched the conversation and should
				// see a recap of the prior context as the starting point.
				seedResumeRecap(s.convLog.path, ef.Agent, ef.ExternalID, ephemeral, s.recapBinary(ef.Agent))
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
	// Record the per-session model/effort override the broker actually
	// applies. `--model` is passed UNVALIDATED, so a bad slug (a model the
	// backend doesn't recognise) spawns fine but fails every turn — this log
	// line is the only on-box record of which slug a session got. Logged for
	// every create so a working vs broken model is comparable.
	if extra := opts.override.extraArgsForAdapter(adapter); len(extra) > 0 {
		log.Printf("session %s: model override applied (%s): %v", id, adapter.Name, extra)
	}
	s.startChatBackend(adapter, opts.resumeChatSessionID, opts.continueLatestChat, opts.resumeCodexThreadID, opts.forkChatSessionID)
	// Render the handoff file so on_start hooks (e.g. "conduit memory
	// render") find their context at CONDUIT_HANDOFF_PATH. Mirrors what
	// switchToAdapter does before running on_swap. Non-fatal: a write
	// failure is logged but never blocks the spawn.
	if _, statErr := os.Stat(s.memoryPath); statErr == nil {
		if err := s.renderHandoffFile(); err != nil {
			fmt.Fprintf(os.Stderr, "session %s: renderHandoffFile (on_start): %v\n", s.ID, err)
		}
	}
	// Invoke the on_start hook after the PTY/backend is running but before
	// the session is exposed. Non-fatal: a hook failure is logged and a
	// Sentry breadcrumb is recorded, but the session continues normally.
	if hookErr := s.runHook(s.hooks.OnStart, map[string]string{
		"AGENT_NAME": s.Assistant,
	}); hookErr != nil {
		fmt.Fprintf(os.Stderr, "session %s: on_start hook: %v (session continues)\n", s.ID, hookErr)
	}
	go s.drain(f)
	s.startBackgroundLoops()
	return s, nil
}

// selectAIGen picks the AI-niceties provider (titles + quick replies) for
// this session: prefer the session's own agent's provider, fall back to the
// other if its creds are missing, nil when neither has creds. Resolves the
// codex binary + model catalog from the Manager-injected closures (nil in
// tests that don't wire a Manager — which then never spawn a codexGen).
func (s *Session) selectAIGen(assistant string) aiGenProvider {
	codexBin := ""
	if s.codexBinary != nil {
		codexBin = s.codexBinary()
	}
	var catalog map[string][]ModelInfo
	if s.modelCatalog != nil {
		catalog = s.modelCatalog()
	}
	return selectAIGenProvider(assistant, s.credLookupHome(), codexBin, nil, catalog)
}

// credLookupHome is the directory under which the broker-side fetchers
// (account usage, AI niceties) find the live credential at the
// provider-native subpath `<home>/.claude/.credentials.json` resp
// `<home>/.codex/auth.json`.
//
//   - Flag OFF (default): the per-session ephemeral HOME, where the private
//     copy was materialized/mirrored. Unchanged behaviour.
//   - Flag ON: the shared credential lookup home (Option A = the operator's
//     real $HOME; Option B = <conduitRoot>/agent-cred), so the fetchers read
//     the SAME canonical lineage the agent refreshes — never a stale
//     per-session copy. Falls back to agentHomeDir if the shared home was
//     not resolved (defensive).
func (s *Session) credLookupHome() string {
	if sharedAgentCredsEnabled() && strings.TrimSpace(s.sharedCredHome) != "" {
		return s.sharedCredHome
	}
	return s.agentHomeDir
}

// startChatBackend builds the structured chat backend for `adapter` and
// installs it on the session (s.chat / s.chatRespawn / generators). Used
// at session create AND by switchToAdapter — the chat channel must follow
// the agent (pre-#399 a switch left the Chat tab driven by the OLD
// agent's binary). The resume seeds carry each backend's persisted
// conversation, so switching BACK to a previously-used agent resumes its
// own earlier thread.
func (s *Session) startChatBackend(
	adapter agents.Adapter,
	resumeChatSessionID string,
	continueLatestChat bool,
	resumeCodexThreadID string,
	forkChatSessionID string,
) {
	// AI niceties (titles + quick replies) provider, selected per session:
	// prefer the session's own agent's provider (anthropicGen for claude,
	// codexGen for codex), fall back to the other if its creds are missing,
	// and nil — no generators — when neither agent has creds (the graceful
	// skip that matches today's claude-no-creds behavior). Routing here is
	// what gives CODEX sessions AI titles + quick replies (task WS-0.1); each
	// backend wires them the way its protocol natively expects.
	aiGen := s.selectAIGen(adapter.Name)

	// Resolve the protocol backend from the registry (Phase 2). An empty
	// protocol — or one with no registered backend — falls through to the
	// legacy TUI-scrape path. The big claude/codex switch this replaced is now
	// the per-protocol Spawn moved into backend_streamjson.go / backend_codex.go.
	backend, err := backendFor(adapter.Protocol)
	if err != nil {
		// Legacy TUI-scrape path (no shipped adapter uses it). If a future
		// adapter does, restart-continuity needs a per-agent resume command
		// (swe-swe's ShellRestartCmd pattern).
		if s.scraper == nil {
			s.scraper = newChatScraper(s.PublishText)
			go s.scraper.run(s.closed)
		}
		return
	}

	// Part A (harness bootstrap): codex has no clean --append-system-prompt
	// flag, so the conduit-awareness addendum is injected as a managed section
	// in the workspace's AGENTS.md (codex reads AGENTS.md from cwd natively —
	// this covers both the app-server and exec backends). claude takes the
	// merged --append-system-prompt path inside claudeStreamCommand instead.
	// Idempotent + flag-gated; a write failure never blocks the spawn.
	if conduitAwarenessEnabled() && isCodexProtocol(adapter.Protocol) {
		if err := s.injectConduitAwarenessAgentsMD(); err != nil {
			fmt.Fprintf(os.Stderr, "session %s: conduit-awareness AGENTS.md: %v (session continues)\n", s.ID, err)
		} else {
			mechanism := "codex:AGENTS.md"
			_, hasKB := kbSection(s.workspaceDir)
			if hasKB {
				mechanism = "codex:AGENTS.md+kb"
			}
			logConduitAwarenessInjected(s.ID, adapter.Name, mechanism)
		}
	}

	res, serr := backend.Spawn(s, adapter, spawnRequest{
		aiGen:               aiGen,
		resumeChatSessionID: resumeChatSessionID,
		continueLatestChat:  continueLatestChat,
		resumeCodexThreadID: resumeCodexThreadID,
		forkChatSessionID:   forkChatSessionID,
	})
	if serr != nil {
		// Spawn already logged + surfaced the failure to chat; chat is
		// disabled for this session but the PTY/Terminal tab is unaffected.
		return
	}

	// Store aiGen on the session so push_notify.go can rewrite notification bodies.
	s.mu.Lock()
	s.aiGen = aiGen
	s.mu.Unlock()

	// Generic, backend-agnostic hook wiring (push notifications). A backend
	// opts in by satisfying the optional interface; absent ones are skipped.
	// The session has the notifier by the time startChatBackend runs.
	if h, ok := res.backend.(turnIdleHooker); ok {
		h.setTurnIdleHook(s.maybeNotifyTurnEnd)
	}
	if h, ok := res.backend.(pendingInputHooker); ok {
		h.setPendingInputHook(s.maybeNotifyPendingInput)
	}
	if h, ok := res.backend.(turnStartHooker); ok {
		h.setTurnStartHook(s.notifyLATurnStart)
	}

	s.mu.Lock()
	s.chat = res.backend
	if res.respawn != nil {
		// Wrap the backend's self-heal respawn so the re-spawned process keeps
		// the same push-notify wiring as the original.
		base := res.respawn
		s.chatRespawn = func() (chatBackend, error) {
			fresh, ferr := base()
			if ferr == nil && fresh != nil {
				if h, ok := fresh.(turnIdleHooker); ok {
					h.setTurnIdleHook(s.maybeNotifyTurnEnd)
				}
				if h, ok := fresh.(pendingInputHooker); ok {
					h.setPendingInputHook(s.maybeNotifyPendingInput)
				}
				if h, ok := fresh.(turnStartHooker); ok {
					h.setTurnStartHook(s.notifyLATurnStart)
				}
			}
			return fresh, ferr
		}
	}
	s.mu.Unlock()
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

// OwnerDeviceID returns the stable per-install UUID of the device that created
// this session. Empty for sessions created by old clients (no device_id param).
func (s *Session) OwnerDeviceID() string {
	s.pushState.mu.Lock()
	defer s.pushState.mu.Unlock()
	return s.pushState.ownerDeviceID
}

// OwnerDeviceConnected reports whether at least one WS client whose device_id
// matches this session's OwnerDeviceID is currently connected. Used by the
// push gate (push_notify.go) to suppress alert pushes only when the owner's
// device is actively watching.
func (s *Session) OwnerDeviceConnected() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.connectedOwnerCount > 0
}

// IncOwnerConnected increments the connected-owner counter. Called by the WS
// handler on connect when the connecting device_id matches OwnerDeviceID.
func (s *Session) IncOwnerConnected() {
	s.mu.Lock()
	s.connectedOwnerCount++
	s.mu.Unlock()
}

// DecOwnerConnected decrements the connected-owner counter. Called by the WS
// handler's cleanup defer when an owner-device client disconnects.
func (s *Session) DecOwnerConnected() {
	s.mu.Lock()
	if s.connectedOwnerCount > 0 {
		s.connectedOwnerCount--
	}
	s.mu.Unlock()
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
	// without re-decoding conduit's WS shape).
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

// structuredTurnActive reports whether a turn is in flight, AND whether the
// session even has a structured chat backend to answer authoritatively.
// present is false for the legacy TUI-scrape path (s.chat == nil): the
// status frame then OMITS turn_active entirely so clients keep inferring
// the working state from the conversation log's trailing role (a flat
// turn_active:false would otherwise pin those sessions' indicator OFF
// forever). We read s.chat under s.mu but call TurnActive() OUTSIDE the
// lock so we never nest s.mu → backend-mu (StatusPayload's accessors
// re-acquire s.mu; see accumulateUsage).
func (s *Session) structuredTurnActive() (active, present bool) {
	s.mu.Lock()
	chat := s.chat
	s.mu.Unlock()
	if chat == nil {
		return false, false
	}
	return chat.TurnActive(), true
}

// TurnActive reports whether the session's structured chat backend has a
// turn in flight right now (false when there is no structured backend).
// Folded into the status frame as `turn_active` (only for structured-chat
// sessions; see structuredTurnActive) so a (re)connecting client drives its
// "agent is working" indicator from authoritative backend truth instead of
// inferring it from the conversation log's trailing role — the
// stuck-indicator bug after the app is backgrounded mid-turn.
func (s *Session) TurnActive() bool {
	active, _ := s.structuredTurnActive()
	return active
}

// structuredTurnPhase returns the current turn phase and whether this
// session has a structured chat backend (present=false for TUI-scrape).
// When present is true, phase is "writing" | "working" | "thinking" | "".
func (s *Session) structuredTurnPhase() (phase string, present bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.chat == nil {
		return "", false
	}
	return s.turnPhase, true
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
	// Rewrite relative upload refs to the absolute durable path for the
	// AGENT only (persistence above keeps the relative form for the client).
	agentMsg := s.RewriteUploadRefs(msg)
	// If the agent is blocked on an AskUserQuestion control request
	// (--permission-prompt-tool stdio, see askcontrol.go), this message
	// IS the answer — a card tap or typed free text both count. Respond
	// on the control channel so the agent's turn RESUMES with the real
	// answer, instead of queueing a new user turn behind a blocked one.
	if ask := s.takePendingAsk(); ask != nil {
		if line, encErr := encodeAskAnswer(ask.requestID, ask.input, agentMsg); encErr == nil {
			if err := ask.cp.SendRaw(line); err == nil {
				// Persist + re-publish the resolved card so the
				// answered/selected state survives close+reopen and rides
				// across devices (the answer was delivered to the agent, but
				// until now the answered state lived only in client @State).
				// Record the user-facing `msg` (the tapped option / typed
				// text), not the upload-rewritten agentMsg.
				s.recordPendingResolution(ask, msg, true)
				return true
			}
			// stdin gone (agent died holding the question) — fall
			// through to the normal send path, whose self-heal respawns
			// a fresh agent and delivers the text as a plain user turn.
		}
	}
	// The codex twin of the AskUserQuestion bridge: if the codex app-server
	// backend is blocked on a command/file-change approval (a server→client
	// request, see codexappserver.go), this message IS the user's tapped
	// decision. Route it as the JSON-RPC approval response so the turn RESUMES
	// (accept) or ends (deny) — not as a new prompt queued behind a blocked one.
	if ar, ok := s.chat.(approvalAnswerer); ok {
		if ar.AnswerApproval(agentMsg) {
			return true
		}
	}
	// KB Phase 2 per-turn relevance hook (kbrelevance.go): on a NORMAL user
	// turn (NOT an AskUserQuestion answer or approval decision — those
	// returned above; mangling them would corrupt the answer), scan the
	// workspace KB for entries topically matching this prompt and PREPEND a
	// small, clearly-delineated "possibly relevant" hint block so the right
	// footgun surfaces exactly when the agent is about to need it. Self-gated
	// on knowledge/INDEX.md (no KB => no-op); per-session dedup avoids
	// repeating a hint; never blocks/fails the turn. Applies to BOTH backends
	// (claude + codex) since both forward agentMsg through s.chat.Send below.
	s.mu.Lock()
	seenSnapshot := make(map[string]bool, len(s.kbSurfaced))
	for slug := range s.kbSurfaced {
		seenSnapshot[slug] = true
	}
	s.mu.Unlock()
	hintBlock, surfaced := s.kbTurnHint(agentMsg, seenSnapshot)
	if hintBlock != "" {
		s.mu.Lock()
		if s.kbSurfaced == nil {
			s.kbSurfaced = make(map[string]bool)
		}
		for _, slug := range surfaced {
			s.kbSurfaced[slug] = true
		}
		s.mu.Unlock()
		agentMsg = hintBlock + "\n\n" + agentMsg
	}
	err := s.chat.Send(agentMsg)
	if err != nil && s.chatRespawn != nil {
		// The long-lived stream-json agent died underneath us (any send
		// error means its stdin is gone — crash, OOM, kill). Self-heal:
		// spawn a fresh agent and retry once, rather than dropping the
		// message. Skip when the session itself is tearing down.
		s.mu.Lock()
		closing := s.closing
		s.mu.Unlock()
		if !closing {
			if fresh, rerr := s.chatRespawn(); rerr == nil {
				s.mu.Lock()
				old := s.chat
				s.chat = fresh
				s.mu.Unlock()
				if old != nil {
					_ = old.Close()
				}
				log.Printf("session %s: chat agent respawned after send error: %v", s.ID, err)
				err = fresh.Send(agentMsg)
			} else {
				fmt.Fprintf(os.Stderr, "session %s: chat respawn: %v\n", s.ID, rerr)
			}
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "session %s: chat send: %v\n", s.ID, err)
		// Surface the failure in the Chat tab — stderr-only here is the
		// "says connected but never replies" bug: the user's message
		// silently vanishes and the typing dots spin forever.
		if errors.Is(err, errCodexTurnInFlight) {
			// Not a delivery failure — the previous turn is still running
			// (common after a background→reconnect: the client thinks the
			// turn ended and the user re-sends). Give accurate guidance
			// instead of the scary "start a new session". The status
			// frame's turn_active already shows the agent as working, so
			// the composer's Stop button is the right next action.
			publishChatSystem(s.PublishText, "The agent is still working on your previous message — tap Stop to interrupt it, or wait for it to finish, then resend.")
		} else {
			publishChatSystem(s.PublishText, "⚠️ Couldn't deliver your message to the agent ("+err.Error()+"). Try again, or start a new session.")
		}
	}
	return true
}

// InterruptTurn stops the agent's current turn (the composer Stop button)
// without ending the session: claude gets a stream-json interrupt
// control_request, codex app-server a turn/interrupt, codex-exec a process
// kill. A no-op when there's no structured chat backend or no turn in flight.
// Returns false only when there's no backend to talk to.
func (s *Session) InterruptTurn() bool {
	s.mu.Lock()
	chat := s.chat
	s.mu.Unlock()
	if chat == nil {
		return false
	}
	if err := chat.Interrupt(); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: chat interrupt: %v\n", s.ID, err)
	}
	// Publish a terminal system line so the client's typing indicator — and the
	// composer Stop button it drives — clear. The apps infer "agent working"
	// from the conversation's shape, and stopping while the agent was still
	// thinking (before any assistant message) leaves the user's prompt as the
	// last item (lastRole == "user" → "working" forever). Both terminuses are
	// otherwise SILENT to the client: claude's interrupt yields a `result`
	// envelope the broker consumes, and codex's interrupted `turn/completed`
	// goes through endTurnQuiet. This note (persisted via PublishText →
	// convLog) flips the last item to role:"system", clearing the indicator on
	// the live session AND on reopen — and works on already-shipped apps.
	publishChatSystem(s.PublishText, "Stopped.")
	return true
}

// ResolveApproval resolves a pending approval from outside the chat (e.g.
// from the POST /api/session/approval endpoint hit via a push notification
// action, without the app being open). decision must be "approve" or "deny".
//
// For codex app-server approvals it routes to AnswerApproval using the
// standard label mapping (approve→"Approve", deny→"Deny") so the same
// codexApprovalDecisionFor logic determines the JSON-RPC decision string.
// For claude AskUserQuestion pending asks it delivers the answer through the
// same encodeAskAnswer path as SendChat.
//
// Returns true when a pending approval was found and resolved; false when
// nothing is pending (the approval was already answered, timed out, or the
// session has no structured backend). A false return means the endpoint
// should return 404 "no pending approval" — idempotent by construction.
func (s *Session) ResolveApproval(decision string) bool {
	// Determine the label to pass through the standard answer path.
	var label string
	switch decision {
	case "approve":
		label = codexApprovalApproveLabel
	default:
		label = codexApprovalDenyLabel
	}

	// Codex app-server path: try AnswerApproval first. It returns true only
	// when a pending approval was found and consumed.
	s.mu.Lock()
	chat := s.chat
	ask := s.pendingAsk
	s.mu.Unlock()

	if ar, ok := chat.(approvalAnswerer); ok {
		if ar.AnswerApproval(label) {
			return true
		}
	}

	// Claude AskUserQuestion path: deliver the answer through the same
	// encodeAskAnswer path that SendChat uses.
	if ask != nil {
		s.mu.Lock()
		cur := s.pendingAsk
		s.pendingAsk = nil
		s.mu.Unlock()
		if cur != nil {
			if cur.timer != nil {
				cur.timer.Stop()
			}
			if line, encErr := encodeAskAnswer(cur.requestID, cur.input, label); encErr == nil {
				_ = cur.cp.SendRaw(line)
			}
			// Persist + re-publish the resolved card (out-of-band answer:
			// ConduitApprovalsView / lock-screen intent) so the answered
			// state survives close+reopen, same as the SendChat path.
			s.recordPendingResolution(cur, label, true)
			return true
		}
	}
	return false
}

// AnswerPendingAsk delivers answer to the stashed AskUserQuestion, callable
// from HTTP without a WS connection (same encodeAskAnswer path as SendChat).
func (s *Session) AnswerPendingAsk(answer string) bool {
	s.mu.Lock()
	ask := s.pendingAsk
	if ask == nil {
		s.mu.Unlock()
		return false
	}
	s.pendingAsk = nil
	s.mu.Unlock()
	if ask.timer != nil {
		ask.timer.Stop()
	}
	if line, err := encodeAskAnswer(ask.requestID, ask.input, answer); err == nil {
		_ = ask.cp.SendRaw(line)
	}
	s.recordPendingResolution(ask, answer, true)
	return true
}

func (s *Session) Close() {
	s.closeOnce.Do(func() {
		// Flag the teardown FIRST: killing the PTY below wakes drain()
		// with an EOF, and its recordAgentExit must see this is an
		// intentional close, not an agent crash (restartbudget.go).
		s.mu.Lock()
		s.closing = true
		s.mu.Unlock()
		// Cancel any pending genuine-stop timer so it can't fire after teardown.
		s.cancelPendingTurnEndPush()
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
		// Best-effort cleanup of the per-session ephemeral $HOME's
		// CREDENTIALS so rotated OAuth refresh tokens don't linger on
		// disk after the agent exits. The home itself — including
		// .claude/projects and .codex/sessions, the CLIs' RESUMABLE
		// conversation files — is deliberately PRESERVED: a broker
		// shutdown Closes every live session, and the previous
		// RemoveAll(agentHomeDir) here destroyed the conversations that
		// recovery's --resume / exec-resume depend on before they could
		// ever be used (the "agent lost where it was" bug — the resume
		// id survived in meta.json but its backing file was wiped on
		// every redeploy). Recovery re-materializes credentials into the
		// home; session GC sweeps the directory after retention.
		cleanupAgentHomeCredentials(s.agentHomeDir, s.ID)
		close(s.closed)
	})
}

// cleanupAgentHomeCredentials removes the materialized OAuth credential
// files from a session's agent-home while leaving everything else (most
// importantly the CLIs' conversation/rollout files) in place. Missing
// files are fine; other failures are logged and ignored.
func cleanupAgentHomeCredentials(homeDir, sessionID string) {
	if homeDir == "" {
		return
	}
	for _, rel := range []string{
		filepath.Join(".claude", ".credentials.json"),
		filepath.Join(".codex", "auth.json"),
	} {
		if err := os.Remove(filepath.Join(homeDir, rel)); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "session %s: remove agent credential %s: %v\n", sessionID, rel, err)
		}
	}
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
	return s.override.effectiveEffortForAdapter(s.adapter)
}

// CredentialSource returns the credential source recorded at spawn time:
// "box" when the host login credentials were used, "app_forwarded" when
// the app-pushed OAuth blob was materialized, or "" when no credential
// was present. Read-only after spawn; mu held for consistency with other
// accessors.
func (s *Session) CredentialSource() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.credentialSource
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
	// tf is drain-local: it carries a report sequence that fragmented across
	// read boundaries into the next chunk. A fresh PTY (adapter swap) starts
	// with a clean filter, which is exactly what we want.
	var tf terminalFilter
	for {
		n, err := f.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			// Drop spurious terminal capability-query replies (DA1/DA2/OSC
			// color) and echoed mouse reports before any consumer sees them —
			// nothing on the broker side answers these, so they'd otherwise
			// echo into the pane and ship to every client as visible garbage.
			// Stateful so a report split across two reads is still removed.
			// See terminal_filter.go.
			chunk = tf.filter(chunk)
			if len(chunk) > 0 {
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
		}
		if err != nil {
			s.mu.Lock()
			stillCurrent := s.pty == f && !s.swapping
			s.mu.Unlock()
			if !stillCurrent {
				return
			}
			// The agent died on its own (EOF on the PTY) — charge the
			// restart budget before Close persists metadata.
			s.recordAgentExit()
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
	conduitRoot    string

	// discCacheMu guards the Found Sessions raw-scan cache below.
	// Held only while reading or refreshing the cache; per-call
	// filtering (dedup/floor/sort) happens outside the lock on a copy.
	discCacheMu sync.Mutex
	discCache   []ExternalSession // raw scan, nil ownIDs (no dedup baked in)
	discCacheAt time.Time         // zero → cache empty

	// termgrid is the optional headless xterm.js sidecar. nil when node
	// isn't installed at startup. Shared by all sessions.
	termgrid *termgrid.Manager

	// replayBaseDir, when non-empty, is propagated to every session's
	// recorder so PTY bytes + view_events are persisted under
	// `<replayBaseDir>/<id>/replay.json`. Set via SetReplayBaseDir
	// from cmd/conduit-broker — empty in unit tests by default.
	replayBaseDir string

	// stopGC closes when Manager.Close is called; the background GC
	// goroutine watches it to exit cleanly.
	stopGC chan struct{}

	// credStore is the per-identity OAuth credential store wired in
	// from cmd/conduit-broker (see docs/PLAN-AGENT-OAUTH.md §G).
	// nil-safe: when nil, every session spawn falls back to the
	// legacy global host-mirror behaviour and no agent-home dir is
	// created. Manager owns the pointer because the WS layer wires
	// it in at startup; sessions read it through commandEnv.
	credStore *credentials.Store

	// catalog caches the per-assistant model+effort catalogs discovered
	// from the agent CLIs (modelcatalog.go). Has its own lock; never
	// touched under mu.
	catalog modelCatalogCache

	// pushNotifier and pushIdentity are wired from cmd/conduit-broker via
	// SetPushNotifier. When set, every new session is handed the notifier so
	// it can fire turn-end / pending-input pushes. nil = push disabled (unit
	// tests, brokers without a relay or UnifiedPush client).
	pushNotifier push.Notifier
	pushIdentity string
	// pushRegistry and pushDispatcher are wired via SetPushDispatcher so that
	// sessions with an ownerDeviceID can call NotifyDevice for targeted pushes.
	// nil = per-device targeting disabled (falls back to broadcast via pushNotifier).
	pushRegistry   *push.Registry
	pushDispatcher *push.Dispatcher
	// laTokens and laSender are wired from cmd/conduit-broker via SetLASender
	// for Live Activity push support. nil = LA disabled.
	laTokens *push.LARegistry
	laSender push.Sender
	// laPushAlertReg is the persisted alert Registry that also holds the
	// push-to-start token (PlatformAPNsLiveActivityStart). Wired via
	// SetLAAlertRegistry so emitLAStart can call StartTokenFor.
	laPushAlertReg *push.Registry
	// presenceTracker is the process-level foreground-heartbeat tracker wired
	// via SetPresenceTracker. Shared across all sessions; each session reads its
	// own ownerDeviceID to check presence. nil = heartbeat gate disabled.
	presenceTracker *push.PresenceTracker
}

// SetCredentialStore wires the per-identity OAuth credential store into
// the manager. Called from cmd/conduit-broker once the store is
// constructed. nil clears it (mostly useful for tests).
// codexBinary returns the registered codex adapter's CLI binary path, or ""
// when codex isn't registered. Used as the fallback AI-niceties provider
// binary for a claude session that lacks anthropic creds (and to detect the
// codex binary at all). Resolves on every call so it tracks registry edits.
func (m *Manager) codexBinary() string {
	adapter, err := m.registry.Get("codex")
	if err != nil || len(adapter.Command) == 0 {
		return ""
	}
	return adapter.Command[0]
}

// claudeBinary returns the registered claude adapter's CLI binary path, or ""
// when claude isn't registered. Used by the external-resume recap one-shot.
// Resolves on every call so it tracks registry edits.
func (m *Manager) claudeBinary() string {
	adapter, err := m.registry.Get("claude")
	if err != nil || len(adapter.Command) == 0 {
		return ""
	}
	return adapter.Command[0]
}

func (m *Manager) SetCredentialStore(s *credentials.Store) {
	m.mu.Lock()
	m.credStore = s
	m.mu.Unlock()
}

// RefreshAllSessionCredentials immediately re-materializes the just-stored
// credential blob (for provider) into every live session that needs it.
// Called synchronously after credentials.Store.Set succeeds — both from the
// HTTP endpoint (serveAgentCredentials) and the WS control message
// (handleSetAgentCredentials) — so the credential is available before the
// next agent turn, without waiting for the 60-second watchdog tick.
//
// The per-session refreshStaleAgentCredentials logic handles both cases:
//   - session has no credential file (app blob arrived after spawn): materialize it
//   - session has an expired credential file: re-mirror from the host login
//
// Only sessions matching provider are touched; other sessions are skipped.
func (m *Manager) RefreshAllSessionCredentials(provider string) {
	m.mu.RLock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		sessions = append(sessions, s)
	}
	m.mu.RUnlock()

	for _, s := range sessions {
		if s.agentCredProvider != provider {
			continue
		}
		log.Printf("session %s: immediate credential re-materialization triggered for provider %s", s.ID, provider)
		s.refreshStaleAgentCredentials()
	}
}

// SetPushNotifier wires the push Notifier (and single-operator identity
// bucket) into the Manager so every NEW session receives it. Existing
// sessions are NOT retroactively updated — the manager creates sessions
// before the WS server finishes startup wiring. Called from ws.Server
// via WithNotifier after WithDispatcher. nil notifier disables push for
// sessions spawned after the call (useful in tests).
func (m *Manager) SetPushNotifier(n push.Notifier, identity string) {
	m.mu.Lock()
	m.pushNotifier = n
	m.pushIdentity = identity
	m.mu.Unlock()
}

// SetPushDispatcher wires the push Registry and Dispatcher into the Manager
// to enable per-device targeting on new sessions. When ownerDeviceID is set
// on a CreateOptions the session's push notify path calls NotifyDevice
// instead of Notify, falling back to broadcast when no token is found.
// Must be called after SetPushNotifier so the notifier is already wired.
func (m *Manager) SetPushDispatcher(reg *push.Registry, d *push.Dispatcher) {
	m.mu.Lock()
	m.pushRegistry = reg
	m.pushDispatcher = d
	m.mu.Unlock()
}

// SetLASender wires the Live Activity token registry and sender into the
// Manager so every NEW session can emit LA push updates. nil reg or sender
// disables LA updates (useful in tests / brokers without LA configured).
func (m *Manager) SetLASender(reg *push.LARegistry, sender push.Sender, identity string) {
	m.mu.Lock()
	m.laTokens = reg
	m.laSender = sender
	m.pushIdentity = identity // shared with alert push identity
	m.mu.Unlock()
}

// SetLAAlertRegistry wires the persisted alert Registry into the Manager so
// sessions can look up the push-to-start token (PlatformAPNsLiveActivityStart)
// via StartTokenFor for the G1 push-to-start feature. Must be called after
// SetLASender. nil reg disables push-to-start (emitLAStart no-ops).
func (m *Manager) SetLAAlertRegistry(reg *push.Registry) {
	m.mu.Lock()
	m.laPushAlertReg = reg
	m.mu.Unlock()
}

// SetPresenceTracker wires the process-level foreground-heartbeat tracker into
// the Manager so new sessions can check it from ownerPresenceGate. The tracker
// is shared across all sessions (it is keyed by deviceID). nil disables the
// heartbeat path (no behavioral change from before).
func (m *Manager) SetPresenceTracker(pt *push.PresenceTracker) {
	m.mu.Lock()
	m.presenceTracker = pt
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

// ExternalResumeOptions seeds a new Conduit session from an external
// (non-Conduit) Claude or Codex conversation so the agent backend resumes it.
// Zero value = no external resume (ordinary new session).
type ExternalResumeOptions struct {
	Agent      string // "claude" | "codex"
	ExternalID string // claude session uuid / codex thread id
}

// ExternalForkOptions configures a Found Sessions fork: a new Conduit session
// branching the external conversation onto an isolated git worktree without
// touching the user's running terminal session.
type ExternalForkOptions struct {
	Agent      string // "claude" | "codex"
	ExternalID string // claude session uuid / codex thread id
	// WorktreeDir is the pre-created git worktree path that the new session
	// runs in. Created by serveAdoptSession before calling GetOrCreateWithOptions.
	WorktreeDir string
}

type CreateOptions struct {
	CWD string
	// Override carries the optional reasoning-effort / model override
	// applied when this session is created (fork-onto-different-model).
	// Zero value = adapter defaults unchanged. Honored only on create.
	Override SpawnOverride
	// ExternalResume seeds the session from an external CLI conversation
	// (Found Sessions adopt-resume path). Pre-seeds ClaudeChatSessionID or
	// CodexThreadID so the backend resumes via --resume / thread/resume.
	// Zero value = ordinary new session (no external resume).
	ExternalResume ExternalResumeOptions
	// ExternalFork seeds a fork of an external CLI conversation onto a fresh
	// git worktree (Found Sessions adopt-fork path). Claude gets
	// --resume <id> --fork-session; codex falls back to plain resume into the
	// new worktree for isolation. Zero value = no fork.
	ExternalFork ExternalForkOptions
	// OwnerDeviceID is the stable per-install UUID of the device that
	// created this session (from the WS connect device_id query param).
	// When non-empty, turn-done and pending-input push notifications are
	// directed to this device's token(s) instead of broadcasting to all
	// paired devices. Empty for sessions created by old clients or without
	// a device_id param — those fall back to broadcast (no regression).
	OwnerDeviceID string
}

func NewManager(registry *agents.Registry) *Manager {
	repoRoot, conduitRoot, _ := resolveConduitRoots()
	m := &Manager{
		sessions:    make(map[string]*Session),
		registry:    registry,
		repoRoot:    repoRoot,
		conduitRoot: conduitRoot,
		stopGC:      make(chan struct{}),
	}
	if strings.TrimSpace(os.Getenv("CONDUIT_DISABLE_SIDECAR")) == "" {
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

// ConduitRoot returns the broker's conduit root directory (~/.conduit by default).
// Used by API handlers that need to create per-session directories.
func (m *Manager) ConduitRoot() string {
	return m.conduitRoot
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

// LiveSessionInfo is the authoritative per-session liveness snapshot the
// broker reports over GET /api/sessions. It is the source of truth a
// reconnecting client uses to decide which sessions are still ACTIVE
// (process genuinely running) vs which have died and belong in History.
type LiveSessionInfo struct {
	ID        string `json:"id"`
	Assistant string `json:"assistant"`
	Phase     string `json:"phase"`
	Health    string `json:"health"`
	Running   bool   `json:"running"`
	// Recoverable is true when opening the session yields an interactive
	// agent — either it is already live (LiveSessions) or it is a cold
	// on-disk session that would respawn cleanly on the next /ws/<id> open
	// (RecoverableSessions). It is the "dead now, resumable" signal the app
	// needs to offer Resume instead of failing closed to a read-only
	// transcript. A session that can NEVER come back (missing scrollback,
	// exhausted restart budget) is omitted from the recoverable list, so
	// this is never true for an unrecoverable row.
	Recoverable    bool   `json:"recoverable,omitempty"`
	Rows           uint16 `json:"rows"`
	Cols           uint16 `json:"cols"`
	Viewers        int    `json:"viewers"`
	Title          string `json:"title,omitempty"`
	CWD            string `json:"cwd,omitempty"`
	StartedAt      string `json:"started_at,omitempty"`
	LastActivityAt string `json:"last_activity_at,omitempty"`
}

// LiveSessions returns a snapshot of the sessions CURRENTLY HELD IN MEMORY —
// the keep-alive-model "what is genuinely alive right now" set. It deliberately
// does NOT touch disk or trigger recovery: a session that exited (or whose
// agent died with a broker restart) and is only recoverable-from-disk is NOT
// alive and must not be resurrected merely by listing. `Running` reflects
// whether the OS process is still answering, so a client can drop a session
// whose process died but hasn't yet been reaped from the map.
func (m *Manager) LiveSessions() []LiveSessionInfo {
	m.mu.RLock()
	live := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		live = append(live, s)
	}
	m.mu.RUnlock()

	out := make([]LiveSessionInfo, 0, len(live))
	for _, s := range live {
		st := s.Status()
		rows, cols := s.Dimensions()
		info := LiveSessionInfo{
			ID:        s.ID,
			Assistant: s.Assistant,
			Phase:     st.Phase,
			Health:    st.Health,
			Running:   s.processAlive(),
			// A held-in-memory session is trivially resumable: it already
			// has (or re-spawns on open) a live agent.
			Recoverable: true,
			Rows:        rows,
			Cols:        cols,
			Viewers:     s.SubscriberCount(),
			Title:       s.DisplayName(),
			CWD:         s.WorkspaceDir(),
		}
		if !st.StartedAt.IsZero() {
			info.StartedAt = st.StartedAt.UTC().Format(time.RFC3339Nano)
		}
		if !st.LastOutput.IsZero() {
			info.LastActivityAt = st.LastOutput.UTC().Format(time.RFC3339Nano)
		}
		out = append(out, info)
	}
	return out
}

func (m *Manager) AssistantNames() []string {
	return m.registry.Names()
}

// Registry returns the underlying adapter registry. Exposed for the ws
// package's readiness block (CLI presence + login-provider resolution).
func (m *Manager) Registry() *agents.Registry {
	return m.registry
}

// HasAssistant reports whether an adapter exists under this name —
// including hidden ones (e.g. "shell") that Names() deliberately omits.
func (m *Manager) HasAssistant(name string) bool {
	_, err := m.registry.Get(name)
	return err == nil
}

// AgentDescriptors returns the per-assistant capability descriptors served in
// /api/capabilities `agents` (WS-2.3). One entry per non-hidden assistant
// (Names() order). The supports flags fold the protocol backend's
// BackendCapabilities with the manifest's plan-mode rule; the model slice
// reuses the discovered catalog. An assistant with no registered backend
// (legacy TUI-scrape adapter) is skipped — it has no structured capabilities
// to declare. Returns nil when nothing qualifies (capabilities then omits the
// "agents" key and the apps fall back to their built-in agent list).
func (m *Manager) AgentDescriptors() map[string]AgentDescriptor {
	catalog := m.ModelCatalog()
	out := map[string]AgentDescriptor{}
	for _, name := range m.registry.Names() {
		adapter, err := m.registry.Get(name)
		if err != nil {
			continue
		}
		backend, err := backendFor(adapter.Protocol)
		if err != nil {
			continue // legacy TUI-scrape adapter: no structured descriptor
		}
		caps := backend.Capabilities()
		_, planMode := adapter.PermissionModes["plan"]
		out[name] = AgentDescriptor{
			DisplayName:   agentDisplayName(name),
			LoginProvider: adapter.LoginProvider,
			Supports: AgentSupports{
				Compact:         caps.Compact,
				AskUserQuestion: caps.AskUserQuestion,
				Effort:          caps.Effort,
				PlanMode:        planMode,
				Usage:           caps.Usage,
				Steer:           caps.Steer,
			},
			Models: catalog[name],
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// agentDisplayName derives a human display name from an assistant key. The
// shipped agents have no display_name manifest field, so we Title-case the key
// ("claude" → "Claude", "codex" → "Codex"); an unknown agent gets the same
// treatment, which is the generic fallback the apps render.
func agentDisplayName(name string) string {
	if name == "" {
		return name
	}
	return strings.ToUpper(name[:1]) + name[1:]
}

// ConversationLog returns the persisted conversation transcript for a
// session id, read from `<conduitRoot>/sessions/<id>/conversation.jsonl`.
// Works for both live and exited sessions — both append to the same
// on-disk log, which survives reap — so the app can reopen a past
// session read-only. Returns an error only when no log exists for the id.
//
// Falls back to `<conduitRoot>/archived-sessions/<id>/conversation.jsonl`
// when the active dir has none, so a session deleted (archived) via
// DeleteSession stays reachable read-only — the delete preserves the
// transcript, it just takes the session out of the active set.
func (m *Manager) ConversationLog(id string) ([]ConvEntry, error) {
	if id == "" {
		return nil, os.ErrNotExist
	}
	entries, err := readConvLog(filepath.Join(m.conduitRoot, "sessions", id, "conversation.jsonl"))
	if err == nil {
		return entries, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return readConvLog(filepath.Join(m.conduitRoot, archivedSessionsDirName, id, "conversation.jsonl"))
}

// GetOrCreate returns the existing session for id, or starts a new one
// with the given assistant. assistant is honored only on creation.
func (m *Manager) GetOrCreate(id, assistant string) (*Session, bool, error) {
	return m.GetOrCreateWithOptions(id, assistant, CreateOptions{})
}

// GetOrCreateWithOptions is like GetOrCreate but accepts creation options.
// Options are honored only when a new session is created.
// Preview dev-server port pool. Each live session gets one port in
// [previewPortBase, previewPortBase+previewPortCount) exported as $PORT; the
// agent's dev server binds it and the broker reverse-proxies `/preview/<id>/`
// to 127.0.0.1:<port>. Mirrors sweswe's preview surface (AGENT-ADAPTERS.md §2.3).
const (
	previewPortBase  = 3000
	previewPortCount = 20
)

// allocatePreviewPortLocked returns the lowest preview port not currently held
// by a live session, or 0 if the pool is exhausted. Caller must hold m.mu.
// Ports free themselves: a closed session is removed from m.sessions, so its
// port stops counting as used on the next allocation.
func (m *Manager) allocatePreviewPortLocked() int {
	used := make(map[int]bool, len(m.sessions))
	for _, s := range m.sessions {
		if s.previewPort > 0 {
			used[s.previewPort] = true
		}
	}
	for p := previewPortBase; p < previewPortBase+previewPortCount; p++ {
		if !used[p] {
			return p
		}
	}
	return 0
}

// PreviewPort returns the session's allocated preview port (0 if none).
func (s *Session) PreviewPort() int { return s.previewPort }

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
		if errors.Is(err, errSessionGaveUp) {
			// End it for good: move the directory out of the active set
			// so the session stops resurrecting on every reconnect (the
			// transcript stays readable from the archive), and refuse
			// the open instead of falling through to a blank re-create
			// under the same id.
			killTmuxSession(id)
			if aerr := m.archiveSessionDir(id); aerr != nil {
				fmt.Fprintf(os.Stderr, "session %s: archive after give-up: %v\n", id, aerr)
			}
			return nil, false, err
		}
	}
	// Tombstone check: refuse to resurrect an id whose directory was
	// previously archived by DeleteSession. The app's reconnect/resume
	// path calls GetOrCreate with the same id it held; without this guard
	// the fall-through below would create a blank new session reusing the
	// archived id. Genuinely new sessions and Found-Sessions adopt/fork
	// paths both use fresh UUIDs, so they never hit this check.
	if m.sessionArchived(id) {
		log.Printf("session %s: refusing reopen — archived", id)
		return nil, false, errSessionArchived
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
	// Allocate the preview $PORT up front so newSession can hand it to the
	// agent's chat backend env (the claude stream backend spawns INSIDE
	// newSession — allocating after would mean the agent never sees $PORT and
	// binds a framework default the broker can't predict).
	previewPort := m.allocatePreviewPortLocked()
	// Wire external resume IDs (Found Sessions adopt-resume path). When
	// ExternalResume is set, pre-seed the appropriate backend resume field so
	// the agent launches with --resume / thread/resume pointing at the
	// external conversation. Uses the same sessionOptions fields that the
	// recovery path uses, so the backend picks it up identically.
	var resumeChatID, resumeCodexID, forkChatID string
	if er := opts.ExternalResume; er.ExternalID != "" {
		switch er.Agent {
		case "claude":
			resumeChatID = er.ExternalID
		case "codex":
			resumeCodexID = er.ExternalID
		}
	}
	// Wire external fork IDs (Found Sessions adopt-fork path). Claude gets
	// --fork-session via forkChatID; codex has no wire-level fork so it falls
	// back to resumeCodexID (plain resume into the isolated worktree).
	if ef := opts.ExternalFork; ef.ExternalID != "" {
		switch ef.Agent {
		case "claude":
			forkChatID = ef.ExternalID
		case "codex":
			resumeCodexID = ef.ExternalID
		}
		// If the caller pre-created a worktree, use it as the workspace.
		if ef.WorktreeDir != "" && requestedCWD == "" {
			requestedCWD = ef.WorktreeDir
		}
	}
	s, err := newSession(id, adapter, sessionOptions{
		repoRoot:            m.repoRoot,
		conduitRoot:         m.conduitRoot,
		requestedCWD:        requestedCWD,
		termgrid:            m.termgrid,
		replayBaseDir:       m.replayBaseDir,
		credStore:           m.credStore,
		override:            opts.Override,
		previewPort:         previewPort,
		modelCatalog:        m.ModelCatalog,
		codexBinary:         m.codexBinary,
		claudeBinary:        m.claudeBinary,
		credentialProviders: credentialProvidersFromRegistry(m.registry),
		resumeChatSessionID: resumeChatID,
		resumeCodexThreadID: resumeCodexID,
		forkChatSessionID:   forkChatID,
		externalResume:      opts.ExternalResume,
		externalFork:        opts.ExternalFork,
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
	// Wire the push notifier so turn-end / pending-input events can fire
	// notifications when no client is attached. nil notifier is a no-op.
	if m.pushNotifier != nil {
		s.SetPushNotifier(m.pushNotifier, m.pushIdentity)
	}
	// Wire per-device targeting when a device_id was supplied on connect.
	// SetPushOwner is a no-op when ownerDeviceID is empty (old clients).
	if opts.OwnerDeviceID != "" && m.pushRegistry != nil && m.pushDispatcher != nil {
		s.SetPushOwner(opts.OwnerDeviceID, m.pushRegistry, m.pushDispatcher)
	}
	// Wire the foreground-heartbeat tracker so ownerPresenceGate can suppress
	// pushes when the app is foregrounded but the session WS is closed.
	if m.presenceTracker != nil {
		s.SetPresenceTracker(m.presenceTracker)
	}
	// Wire the Live Activity sender so the session can emit content-state
	// updates to the iOS lock-screen turn card. nil reg/sender = no-op.
	if m.laTokens != nil && m.laSender != nil {
		s.SetLAState(m.laTokens, m.laSender, m.pushIdentity)
		if m.laPushAlertReg != nil {
			s.SetLAAlertRegistry(m.laPushAlertReg)
		}
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
	entries, err := os.ReadDir(filepath.Join(m.conduitRoot, "sessions"))
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
		// LAZY recovery: enumerate recoverable sessions but do NOT spawn
		// their agents here. Eagerly calling recoverSessionLocked for
		// every persisted session used to start one PTY + agent process
		// (plus a per-session watchdog/checkpoint timer) per session at
		// boot; with dozens of accumulated sessions that was a process
		// storm that pinned the host (~98% sys, load > 100) and made the
		// whole box — including unrelated interactive shells — hang. The
		// session is recovered + spawned on demand in
		// GetOrCreateWithOptions the first time a client actually opens
		// it; the home/session list is served from recent-projects.json
		// on disk, so it is unaffected by not pre-warming here.
		if m.sessionOnDisk(id) {
			recovered = append(recovered, id)
		}
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
	conduitRoot    string
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
	// credentialProviders is the set of login_provider keys to mirror
	// into the session's ephemeral HOME (for the "interactive Terminal
	// is logged into all agents" guarantee). Derived from the registry
	// via credentialProvidersFromRegistry (WS-1.2). nil → falls back
	// to allCredentialProviders(). Manager fills this in; tests leave
	// it nil to keep the hardcoded fallback.
	credentialProviders []string
	// override carries the optional reasoning-effort / model override
	// applied to the spawned agent's argv. Zero value = adapter
	// defaults unchanged (the normal start path).
	override SpawnOverride
	// previewPort is the pooled dev-server port ($PORT) for this session,
	// allocated by the Manager BEFORE newSession so the agent's chat backend
	// — spawned inside newSession — actually receives $PORT in its env. 0 when
	// the pool was exhausted (or in tests that don't allocate one).
	previewPort int
	// resumeChatSessionID, when non-empty (recovery path), makes the
	// claude chat agent `--resume` this CLI conversation id so a broker
	// restart doesn't reset the agent's memory of the session.
	resumeChatSessionID string
	// continueLatestChat (recovery of a PRE-latch session: conversation
	// files exist in agent-home but no id was ever persisted) makes the
	// claude chat agent start with `--continue` — resolving this
	// session's own most recent conversation.
	continueLatestChat bool
	// resumeCodexThreadID seeds the codex chat backend's thread id on
	// recovery so its first post-restart turn runs `exec resume <id>`.
	resumeCodexThreadID string
	// forkChatSessionID, when non-empty, resumes + forks the named claude
	// conversation via --resume <id> --fork-session. This branches the
	// conversation into a fresh claude session id without touching the
	// original. Passed through to the streamjson backend's spawnRequest.
	forkChatSessionID string
	// modelCatalog returns the Manager's discovered model catalog snapshot,
	// used to pick the smallest codex model for the AI-niceties codexGen.
	// Manager fills this in from its own ModelCatalog; tests typically leave
	// it nil (codexGen then omits --model).
	modelCatalog func() map[string][]ModelInfo
	// codexBinary returns the codex CLI binary path (registry-resolved),
	// needed so a claude session can FALL BACK to the codex AI-niceties
	// provider when it has no anthropic creds (and vice-versa). "" when codex
	// isn't a registered adapter. Manager fills this in; tests leave it nil.
	codexBinary func() string
	// claudeBinary returns the claude CLI binary path (registry-resolved),
	// used by the external-resume recap one-shot. "" when claude isn't a
	// registered adapter. Manager fills this in; tests leave it nil.
	claudeBinary func() string
	// externalResume, when set, triggers transcript staging before the agent
	// is spawned: the external conversation file is copied from the broker's
	// real $HOME into the per-session agent-home so --resume / exec-resume
	// finds it in the isolated home. Zero value = no staging (ordinary session).
	externalResume ExternalResumeOptions
	// externalFork mirrors externalResume for the fork path: the source
	// transcript is staged so --resume --fork-session finds it in the
	// isolated agent-home. Zero value = no staging.
	externalFork ExternalForkOptions
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
	// WorkspaceDir is the resolved CWD for both the agent and the
	// terminal shell. Persisted so that on broker restart the recovered
	// session's agent spawns back in the same directory the user
	// originally chose, rather than falling back to the empty
	// per-session work/ dir. omitempty: pre-feature sessions without
	// this field recover with the legacy adapter-workdir / worktreeDir
	// fallback behaviour.
	WorkspaceDir string `json:"workspace_dir,omitempty"`
	// StartedAt / LastActivityAt are the session's real wall-clock
	// timestamps (RFC3339Nano), persisted so a recovered session keeps
	// its ORIGINAL creation + last-activity time instead of resetting to
	// "now" on recovery — otherwise every reattached/historic session
	// shows the recovery moment ("2m ago") rather than when it was really
	// created/last active. omitempty: pre-feature sessions fall back to
	// the recovery-time defaults newSession assigns.
	StartedAt      string `json:"started_at,omitempty"`
	LastActivityAt string `json:"last_activity_at,omitempty"`
	// ConsecutiveFastExits is the restart budget spent so far (agent
	// deaths within fastExitWindow of spawn, in a row). Persisted so a
	// crash-looping session gives up across recoveries instead of
	// resurrecting forever — see restartbudget.go. omitempty: healthy
	// sessions never carry the field.
	ConsecutiveFastExits int `json:"consecutive_fast_exits,omitempty"`
	// Usage totals + the context gauge (see usage.go). Persisted so a
	// broker restart doesn't blank the Session Info usage card — the
	// totals/cost are lifetime sums and the context gauge is the latest
	// turn's snapshot, both of which remain true after a recovery (the
	// next turn's usage event simply overwrites the gauge). omitempty:
	// sessions that never reported usage carry none of these.
	TotalInputTokens    uint64  `json:"total_input_tokens,omitempty"`
	TotalOutputTokens   uint64  `json:"total_output_tokens,omitempty"`
	TotalCachedTokens   uint64  `json:"total_cached_tokens,omitempty"`
	TotalCostUSD        float64 `json:"total_cost_usd,omitempty"`
	ContextUsedTokens   uint64  `json:"context_used_tokens,omitempty"`
	ContextWindowTokens uint64  `json:"context_window_tokens,omitempty"`
	// ClaudeChatSessionID is the claude CLI's own conversation id —
	// persisted so post-restart recovery resumes the agent's memory.
	ClaudeChatSessionID string `json:"claude_chat_session_id,omitempty"`
	// CodexThreadID is codex's equivalent (thread.started id).
	CodexThreadID string `json:"codex_thread_id,omitempty"`
}

// UploadBaseDir is the durable root under which chat file-uploads are
// stored (`<base>/uploads/<sid>/<file>`). It is the per-session state dir,
// which lives OUTSIDE the agent's git working tree.
//
// Uploads were historically written into the workspace (`<cwd>/uploads/`),
// but that dir is untracked-and-not-ignored: a routine `git reset --hard`
// / `git clean` (which agents and CI run constantly) wipes it out from
// under the agent before it can read the file — the "uploaded image can't
// be read / always cleared" bug. Rooting uploads at the session state dir
// ties their lifecycle to the session (GC / archive move them along) and
// keeps any git hygiene in the workspace from touching them.
//
// Falls back to the workspace for sessions with no state dir (shouldn't
// happen for live sessions, but keeps the upload path total).
func (s *Session) UploadBaseDir() string {
	if s.sessionDir != "" {
		return s.sessionDir
	}
	return s.WorkspaceDir()
}

// RewriteUploadRefs rewrites a composer message's relative upload
// references (`uploads/<id>/<name>`) to the absolute on-disk path the
// broker actually persisted the bytes to (`<UploadBaseDir>/uploads/<id>/
// <name>`). The mobile composer only knows the protocol-relative form and
// the agent's cwd is the git worktree — without this rewrite a relative
// `uploads/...` resolves into the worktree, where the bytes are
// deliberately NOT written (see UploadBaseDir).
//
// Only the copy handed to the AGENT is rewritten; the persisted transcript
// keeps the relative form so the mobile client can still parse it back into
// an attachment chip/thumbnail.
func (s *Session) RewriteUploadRefs(msg string) string {
	base := s.UploadBaseDir()
	if base == "" {
		return msg
	}
	rel := "uploads/" + s.ID + "/"
	abs := filepath.Join(base, "uploads", s.ID) + "/"
	return strings.ReplaceAll(msg, rel, abs)
}

func (s *Session) applyPaths() {
	s.sessionDir = filepath.Join(s.conduitRoot, "sessions", s.ID)
	s.convLog = newConvLogger(filepath.Join(s.sessionDir, "conversation.jsonl"))
	s.worktreeDir = filepath.Join(s.sessionDir, "work")
	s.scrollbackPath = filepath.Join(s.sessionDir, "scrollback.bin")
	s.metaPath = filepath.Join(s.sessionDir, "meta.json")
	s.memoryPath = filepath.Join(s.conduitRoot, "memory", "sessions", s.ID+".html")
	s.handoffPath = filepath.Join(s.worktreeDir, ".conduit", "HANDOFF.html")
	s.handoffOutPath = filepath.Join(s.worktreeDir, ".conduit", "HANDOFF-OUT.html")
}

func (s *Session) persistMetadata() error {
	s.mu.Lock()
	meta := sessionMetadata{
		ID:           s.ID,
		Assistant:    s.Assistant,
		Rows:         s.rows,
		Cols:         s.cols,
		Phase:        s.phase,
		Health:       s.health,
		ReasonCode:   s.reasonCode,
		ExitCode:     s.exitCode,
		AITitle:      s.aiTitle,
		WorkspaceDir: s.workspaceDir,

		ConsecutiveFastExits: s.consecutiveFastExits,

		TotalInputTokens:    s.totalInputTokens,
		TotalOutputTokens:   s.totalOutputTokens,
		TotalCachedTokens:   s.totalCachedTokens,
		TotalCostUSD:        s.totalCostUSD,
		ContextUsedTokens:   s.contextUsedTokens,
		ContextWindowTokens: s.contextWindowTokens,
		ClaudeChatSessionID: s.chatSessionID,
		CodexThreadID:       s.codexThreadID,
	}
	if !s.lastCheckpoint.IsZero() {
		meta.LastCheckpoint = s.lastCheckpoint.UTC().Format(time.RFC3339Nano)
	}
	if !s.startedAt.IsZero() {
		meta.StartedAt = s.startedAt.UTC().Format(time.RFC3339Nano)
	}
	if !s.lastOutput.IsZero() {
		meta.LastActivityAt = s.lastOutput.UTC().Format(time.RFC3339Nano)
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

func resolveConduitRoots() (string, string, error) {
	if root := strings.TrimSpace(os.Getenv("CONDUIT_ROOT")); root != "" {
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
		if dirExists(filepath.Join(cur, ".git")) || dirExists(filepath.Join(cur, ".conduit")) {
			return cur, filepath.Join(cur, ".conduit"), nil
		}
		next := filepath.Dir(cur)
		if next == cur {
			return wd, filepath.Join(wd, ".conduit"), nil
		}
		cur = next
	}
}
