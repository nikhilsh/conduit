package session

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/creack/pty"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

var handoffSectionPattern = regexp.MustCompile(`(?is)<section[^>]*data-section=["']handoff["'][^>]*>(.*?)</section>`)

func (s *Session) prepareFilesystem() error {
	dirs := []string{
		s.sessionDir,
		s.worktreeDir,
		filepath.Dir(s.memoryPath),
		filepath.Dir(s.handoffPath),
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.scrollbackPath); errors.Is(err, os.ErrNotExist) {
		if err := atomicWriteFile(s.scrollbackPath, nil); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.memoryPath); errors.Is(err, os.ErrNotExist) {
		if err := s.writeMemoryHTML(nil); err != nil {
			return err
		}
	}
	return nil
}

func userHomeDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		return home
	}
	if home := os.Getenv("HOME"); home != "" {
		return home
	}
	return "/"
}

func (s *Session) commandDir(adapter agents.Adapter) string {
	if s.requestedCWD != "" && dirExists(s.requestedCWD) {
		return s.requestedCWD
	}
	if adapter.Workdir != "" {
		resolved := os.ExpandEnv(adapter.Workdir)
		if filepath.IsAbs(resolved) {
			if dirExists(resolved) {
				return resolved
			}
		} else {
			if dirExists(resolved) {
				return resolved
			}
			if dirExists(filepath.Join(s.repoRoot, resolved)) {
				return filepath.Join(s.repoRoot, resolved)
			}
		}
	}
	if home := userHomeDir(); dirExists(home) {
		return home
	}
	return s.worktreeDir
}

func (s *Session) commandEnv(extra map[string]string) []string {
	// Drop ANTHROPIC_API_KEY / OPENAI_API_KEY from the inherited env
	// when they are present but empty. systemd EnvironmentFile= lines
	// like `ANTHROPIC_API_KEY=` (shipped in the install template as a
	// placeholder) export the variable with an empty value, and the
	// Claude / Codex CLIs treat an explicit empty key as "use API-key
	// auth with no key" — short-circuiting the OAuth file lookup at
	// ~/.claude/.credentials.json and reporting the session as logged
	// out. A user who deliberately sets a real key is unaffected.
	inherited := os.Environ()
	env := make([]string, 0, len(inherited)+8)
	for _, kv := range inherited {
		if eq := strings.IndexByte(kv, '='); eq > 0 {
			k := kv[:eq]
			v := kv[eq+1:]
			if v == "" && (k == "ANTHROPIC_API_KEY" || k == "OPENAI_API_KEY") {
				continue
			}
			// Strip CLI config-dir relocation vars (CLAUDE_CONFIG_DIR /
			// CODEX_HOME) unconditionally: they are re-injected below via
			// pairs exactly as the flag-on or flag-off path requires. A
			// stale value from a previous broker deployment (e.g. a systemd
			// unit that has CLAUDE_CONFIG_DIR= in its EnvironmentFile) would
			// otherwise leak into sessions that use the per-session HOME path,
			// routing the agent at the wrong credential directory.
			if k == "CLAUDE_CONFIG_DIR" || k == "CODEX_HOME" {
				continue
			}
		}
		env = append(env, kv)
	}
	env = append(env, "TERM=xterm-256color", "PS1=$ ")
	pairs := map[string]string{
		"SESSION_UUID": s.ID,
		"AGENT_NAME":   s.Assistant,
		// Handoff path exported under the new CONDUIT_ name; the legacy
		// KITTY_ aliases are kept (set below) so any agent hook that still
		// reads the old spelling keeps working post-rebrand.
		"CONDUIT_HANDOFF_PATH":     s.handoffPath,
		"CONDUIT_HANDOFF_OUT_PATH": s.handoffOutPath,
		"KITTY_HANDOFF_PATH":       s.handoffPath,
		"KITTY_HANDOFF_OUT_PATH":   s.handoffOutPath,
		// Claude Code refuses `--dangerously-skip-permissions` (the
		// claude adapter's only arg) under root/sudo "for security
		// reasons", which kills every claude session in a respawn loop
		// when the broker runs as root (the common bare-VPS deploy, vs.
		// the Docker image's non-root `app` uid). IS_SANDBOX=1 is Claude
		// Code's documented escape hatch: it asserts the agent runs in a
		// constrained sandbox, which holds here — each session gets an
		// ephemeral per-session $HOME and a dedicated PTY. Harmless for
		// codex (its --dangerously-bypass-approvals-and-sandbox flag has
		// no root guard). Verified: `IS_SANDBOX=1 claude
		// --dangerously-skip-permissions` runs as root; without it, it
		// refuses.
		"IS_SANDBOX": "1",
	}
	// docs/PLAN-AGENT-OAUTH.md §G.2: when a per-session ephemeral
	// agent home was materialized, point the agent process at it via
	// HOME. Codex additionally honours $CODEX_HOME for its auth.json
	// path, so we set both to make the lookup explicit and
	// host-cwd-independent. When agentHomeDir is empty, we leave HOME
	// alone — the agent inherits the broker process's HOME, exactly
	// the legacy host-mirror behaviour.
	if s.agentHomeDir != "" {
		pairs["HOME"] = s.agentHomeDir
		if s.Assistant == "codex" {
			pairs["CODEX_HOME"] = filepath.Join(s.agentHomeDir, ".codex")
		}
	}
	// CONDUIT_SHARED_AGENT_CREDS (doc PLAN-AGENT-CREDENTIAL-LINEAGE.md):
	// when the flag is on, retarget the CLI config-dir env vars
	// (CLAUDE_CONFIG_DIR / CODEX_HOME) at the shared canonical dirs so every
	// session reads ONE credential lineage head instead of a private copy.
	// These intentionally OVERRIDE the per-session CODEX_HOME set above (and
	// add CLAUDE_CONFIG_DIR) — both providers are set so the interactive
	// Terminal tab is logged in for whichever CLI the user runs. The map is
	// nil/empty on the default flag-off path, so this loop is a no-op there
	// and commandEnv stays byte-for-byte unchanged.
	for k, v := range s.sharedCredConfigEnv {
		pairs[k] = v
	}
	// Preview dev-server port (AGENT-ADAPTERS.md §2.3): the agent binds $PORT
	// and the broker reverse-proxies `/preview/<id>/` to it; $AGENT_CHAT_PORT
	// (=PORT+1000) is the optional MCP view_event bridge. Only set when a port
	// was successfully allocated. CONDUIT_PREVIEW_PORT is an explicit alias of
	// $PORT — the nudge: bind it and the Browser tab gets a stable proxied URL.
	// (If the agent binds something else, the broker auto-detects it anyway by
	// scanning the session's own process tree; see preview.go.)
	if s.previewPort > 0 {
		pairs["PORT"] = strconv.Itoa(s.previewPort)
		pairs["CONDUIT_PREVIEW_PORT"] = strconv.Itoa(s.previewPort)
		pairs["AGENT_CHAT_PORT"] = strconv.Itoa(s.previewPort + 1000)
	}
	for k, v := range extra {
		pairs[k] = v
	}
	for k, v := range pairs {
		env = append(env, k+"="+v)
	}
	return env
}

// providerForAssistant maps the broker's adapter name to the OAuth
// provider key used by the credential store. Adapters that don't have
// a per-user OAuth flow return "" so the spawn path skips
// materialization (and falls back to the host-mirror behaviour).
// Keep this in lockstep with credentials.ValidProvider.
func providerForAssistant(assistant string) string {
	switch assistant {
	case "claude":
		return "anthropic"
	case "codex":
		return "openai"
	default:
		return ""
	}
}

// allCredentialProviders is every agent-credential provider the broker
// knows how to materialize into a session's ephemeral HOME. Used to log
// the interactive Terminal tab into BOTH agents regardless of which one
// (if any) the session's own agent is. Keep in sync with
// providerForAssistant / mirrorHostCredentials.
func allCredentialProviders() []string {
	return []string{"anthropic", "openai", "opencode"}
}

// credentialProvidersFromRegistry derives the set of distinct non-empty
// login_provider values from all registered adapters. Used by the manager
// spawn path (WS-1.2) so a new adapter TOML with a new login_provider is
// automatically included in the "mirror into every session HOME" walk
// without a code change. The result has no duplicates and is in registry
// order (sorted by adapter name via Names()). Falls back to
// allCredentialProviders() when the registry yields no providers (e.g. in
// tests with stub adapters).
func credentialProvidersFromRegistry(reg *agents.Registry) []string {
	seen := map[string]bool{}
	var out []string
	for _, name := range reg.Names() {
		a, err := reg.Get(name)
		if err != nil {
			continue
		}
		p := strings.TrimSpace(a.LoginProvider)
		if p != "" && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	if len(out) == 0 {
		return allCredentialProviders()
	}
	return out
}

// hostHomeDir returns the broker's real $HOME — the place where claude
// / codex stash their per-user credentials when the operator runs them
// interactively for the first login. Honours $CONDUIT_HOST_HOME for
// tests; otherwise mirrors `os.UserHomeDir()`. Returns "" when the home
// can't be resolved; callers must treat that as "no host creds, skip
// the mirror and let the agent prompt for /login".
func hostHomeDir() string {
	if v := strings.TrimSpace(os.Getenv("CONDUIT_HOST_HOME")); v != "" {
		return v
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return h
}

// mirrorHostCredentials copies the broker's own per-user agent
// credential files into the per-session ephemeral HOME so each spawned
// agent gets its own private copy. This is the fallback used when the
// in-app credStore doesn't have a stored OAuth blob yet (i.e. before
// OAuth Stage 2 is wired up on the iOS/Android client). Without it,
// every concurrent claude/codex would share the broker's real
// `.credentials.json` and race each other on refresh-token rotation —
// only the last writer keeps a valid token, and all peers get bounced
// to "Please run /login".
//
// Per provider, the mirror copies:
//
//   - anthropic → ~/.claude/.credentials.json + ~/.claude.json
//   - openai    → ~/.codex/auth.json + ~/.codex/config.toml
//
// Missing source files are silently skipped (the agent will prompt for
// /login on first use — a clean error rather than a race). Returns the
// first hard error (mkdir / read / atomic-write); callers should log
// and continue so a broken mirror doesn't refuse the session.
func mirrorHostCredentials(provider, ephemeralHome string) error {
	host := hostHomeDir()
	if host == "" {
		return errors.New("host home unresolved")
	}
	var sources []hostCredSource
	switch provider {
	case "anthropic":
		sources = []hostCredSource{
			{src: filepath.Join(host, ".claude", ".credentials.json"), dst: filepath.Join(ephemeralHome, ".claude", ".credentials.json"), mode: 0o600},
			{src: filepath.Join(host, ".claude.json"), dst: filepath.Join(ephemeralHome, ".claude.json"), mode: 0o600},
		}
	case "openai":
		sources = []hostCredSource{
			{src: filepath.Join(host, ".codex", "auth.json"), dst: filepath.Join(ephemeralHome, ".codex", "auth.json"), mode: 0o600},
			{src: filepath.Join(host, ".codex", "config.toml"), dst: filepath.Join(ephemeralHome, ".codex", "config.toml"), mode: 0o644},
		}
	case "opencode":
		// opencode stores auth credentials at ~/.local/share/opencode/auth.json
		// (its XDG data dir, resolved relative to HOME) and its per-user config
		// at ~/.config/opencode/opencode.jsonc (XDG config dir). Both must be
		// mirrored into the ephemeral HOME so the spawned `opencode serve`
		// process picks up any provider credentials the operator configured via
		// `opencode providers login`. Without the mirror, the session HOME is
		// empty and opencode falls back to the built-in "OpenCode Zen" free
		// provider regardless of what is configured on the host.
		sources = []hostCredSource{
			{src: filepath.Join(host, ".local", "share", "opencode", "auth.json"), dst: filepath.Join(ephemeralHome, ".local", "share", "opencode", "auth.json"), mode: 0o600},
			{src: filepath.Join(host, ".config", "opencode", "opencode.jsonc"), dst: filepath.Join(ephemeralHome, ".config", "opencode", "opencode.jsonc"), mode: 0o644},
		}
	default:
		return fmt.Errorf("unknown provider %q", provider)
	}
	anyCopied := false
	for _, s := range sources {
		data, err := os.ReadFile(s.src)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				// Missing source — skip; agent will prompt for /login.
				continue
			}
			return fmt.Errorf("read %s: %w", s.src, err)
		}
		if err := os.MkdirAll(filepath.Dir(s.dst), 0o700); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(s.dst), err)
		}
		if err := atomicWriteFileMode(s.dst, data, s.mode); err != nil {
			return fmt.Errorf("write %s: %w", s.dst, err)
		}
		anyCopied = true
	}
	if !anyCopied {
		return errors.New("no host credential files found")
	}
	return nil
}

type hostCredSource struct {
	src  string
	dst  string
	mode os.FileMode
}

// atomicWriteFileMode is atomicWriteFile but lets the caller pin the
// final file mode (credentials want 0o600, not the default 0o644).
// Race-safe: concurrent spawns each write to a unique temp file and
// rename into place, so no reader ever sees a torn credential file.
func atomicWriteFileMode(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".swk-home-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpPath) }
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

// defaultClaudeTheme is the theme seeded into a fresh ephemeral
// ~/.claude.json. Matches the app's default dark surface.
const defaultClaudeTheme = "dark"

// seedClaudeConfig ensures the per-session ephemeral ~/.claude.json
// carries a `theme` and a completed-onboarding marker so Claude Code's
// first-run interactive theme picker never blocks the non-interactive
// PTY session. credStore.Materialize only writes
// `.claude/.credentials.json`, and mirrorHostCredentials may copy a
// `.claude.json` that predates the theme being set — either way the
// fresh agent can land on the "Choose the text style that looks best"
// prompt and hang waiting for arrow-key input that never comes.
//
// It MERGES into any existing config rather than overwriting it: an
// operator's real theme choice (copied from the host) is preserved; we
// only fill in keys that are missing. A `.claude.json` that fails to
// parse is left untouched (returns an error the caller logs) so we
// never clobber a config we don't understand.
func seedClaudeConfig(ephemeralHome string) error {
	path := filepath.Join(ephemeralHome, ".claude.json")
	cfg := map[string]any{}
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if len(bytes.TrimSpace(data)) > 0 {
			if err := json.Unmarshal(data, &cfg); err != nil {
				return fmt.Errorf("parse %s: %w", path, err)
			}
		}
	case errors.Is(err, os.ErrNotExist):
		// No config yet — start from an empty object.
	default:
		return fmt.Errorf("read %s: %w", path, err)
	}

	changed := false
	if _, ok := cfg["theme"]; !ok {
		cfg["theme"] = defaultClaudeTheme
		changed = true
	}
	if done, _ := cfg["hasCompletedOnboarding"].(bool); !done {
		cfg["hasCompletedOnboarding"] = true
		changed = true
	}
	if !changed {
		return nil
	}

	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal %s: %w", path, err)
	}
	return atomicWriteFileMode(path, out, 0o600)
}

func (s *Session) startBackgroundLoops() {
	go s.checkpointLoop()
	go s.watchdogLoop()
	// Seed the OutcomeChips stats once up front (async) so the first status
	// frame on connect carries them, rather than waiting for the first
	// watchdog tick. See outcome.go.
	go s.refreshOutcomeStats()
}

func (s *Session) checkpointLoop() {
	ticker := time.NewTicker(s.checkpointEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			_ = s.Checkpoint("ticker")
		case <-s.closed:
			return
		}
	}
}

func (s *Session) watchdogLoop() {
	ticker := time.NewTicker(s.watchdogEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			s.runWatchdogChecks()
			// Recompute OutcomeChips stats on the same cadence (TTL-gated
			// inside, so the gh PR lookup runs at a slower interval). See
			// outcome.go.
			s.refreshOutcomeStats()
		case <-s.closed:
			return
		}
	}
}

func (s *Session) Checkpoint(reason string) error {
	s.checkpointMu.Lock()
	defer s.checkpointMu.Unlock()

	snapshot := s.Snapshot()
	// A failed checkpoint write is a disk hiccup, not a dead agent — keep the
	// phase "running" (health "warning") so a transient write error doesn't
	// flip the live session read-only on the app. See watchdog.setHealth*.
	if err := atomicWriteFile(s.scrollbackPath, snapshot); err != nil {
		s.setHealth("warning", "running")
		return err
	}
	if err := s.writeMemoryHTML(snapshot); err != nil {
		s.setHealth("warning", "running")
		return err
	}
	s.maybeAutoWIP()
	s.mu.Lock()
	s.lastCheckpoint = time.Now().UTC()
	s.phase = "running"
	s.mu.Unlock()
	return s.persistMetadata()
}

func (s *Session) writeMemoryHTML(snapshot []byte) error {
	if info, err := os.Stat(s.memoryPath); err == nil {
		s.lastMemoryModTime = info.ModTime()
	}
	if current := s.loadHandoffHTML(); current != "" {
		s.handoffHTML = current
	}
	var tail []byte
	if len(snapshot) > 4096 {
		tail = snapshot[len(snapshot)-4096:]
	} else {
		tail = snapshot
	}
	lastCheckpoint := ""
	s.mu.Lock()
	if !s.lastCheckpoint.IsZero() {
		lastCheckpoint = s.lastCheckpoint.UTC().Format(time.RFC3339Nano)
	}
	assistant := s.Assistant
	s.mu.Unlock()
	var buf bytes.Buffer
	buf.WriteString("<!doctype html>\n<html><body>\n")
	buf.WriteString(`<section data-section="meta">`)
	buf.WriteString("<p>session: " + html.EscapeString(s.ID) + "</p>")
	buf.WriteString("<p>assistant: " + html.EscapeString(assistant) + "</p>")
	if lastCheckpoint != "" {
		buf.WriteString("<p>last-checkpoint: " + html.EscapeString(lastCheckpoint) + "</p>")
	}
	buf.WriteString("</section>\n")
	buf.WriteString(`<section data-section="handoff">`)
	if strings.TrimSpace(s.handoffHTML) != "" {
		buf.WriteString(s.handoffHTML)
	}
	buf.WriteString("</section>\n")
	buf.WriteString(`<section data-section="env-snapshot"><pre>`)
	buf.WriteString(html.EscapeString(string(tail)))
	buf.WriteString("</pre></section>\n")
	buf.WriteString("</body></html>\n")
	if err := atomicWriteFile(s.memoryPath, buf.Bytes()); err != nil {
		return err
	}
	if info, err := os.Stat(s.memoryPath); err == nil {
		s.lastMemoryModTime = info.ModTime()
	}
	return nil
}

// wipCheckpointRefPrefix namespaces the per-session WIP snapshot ref. One
// ref per session, overwritten in place each checkpoint — so snapshots never
// accumulate (the old stash approach piled up one entry per checkpoint, none
// ever read). Custom ref namespace so it never shows in branch/tag listings.
const wipCheckpointRefPrefix = "refs/conduit/checkpoints/"

// maybeAutoWIP records a snapshot of the session's workspace (tracked changes
// + untracked files) when it is dirty — WITHOUT mutating the working tree.
//
// The previous implementation ran `git stash push --include-untracked`, whose
// internal `git reset --hard` reverts the working tree. On the 60s checkpoint
// loop that silently wiped a live agent's in-progress edits off disk every
// minute (recoverable only by hand from the stash stack) and grew an unbounded
// pile of checkpoint stashes that nothing ever restored. We now capture the
// snapshot into a commit object via a throwaway index and store it under a
// per-session ref, leaving the developer's working tree exactly as it was.
// Best-effort throughout: any git step failing just skips this snapshot.
func (s *Session) maybeAutoWIP() {
	gitDir := filepath.Join(s.workspaceDir, ".git")
	if _, err := os.Stat(gitDir); err != nil {
		return
	}
	statusCmd := exec.Command("git", "-C", s.workspaceDir, "status", "--porcelain")
	out, err := statusCmd.Output()
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return
	}
	commit, ok := s.snapshotWorkspaceTree()
	if !ok {
		return
	}
	_ = exec.Command("git", "-C", s.workspaceDir,
		"update-ref", wipCheckpointRefPrefix+s.ID, commit).Run()
}

// snapshotWorkspaceTree builds a commit object capturing the current working
// tree — tracked modifications plus untracked, non-ignored files — without
// touching the working tree, the real index, or any existing ref. Returns the
// commit SHA and true on success. It stages into a throwaway GIT_INDEX_FILE
// (so the real index is untouched; `git add` never writes the working tree),
// writes that tree, and commit-trees it with a deterministic identity (the box
// may have no git user configured).
func (s *Session) snapshotWorkspaceTree() (string, bool) {
	tmp, err := os.CreateTemp("", "conduit-wip-index-*")
	if err != nil {
		return "", false
	}
	tmpIndex := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpIndex)

	env := append(os.Environ(),
		"GIT_INDEX_FILE="+tmpIndex,
		"GIT_AUTHOR_NAME=conduit", "GIT_AUTHOR_EMAIL=conduit@localhost",
		"GIT_COMMITTER_NAME=conduit", "GIT_COMMITTER_EMAIL=conduit@localhost",
	)
	run := func(args ...string) ([]byte, error) {
		cmd := exec.Command("git", append([]string{"-C", s.workspaceDir}, args...)...)
		cmd.Env = env
		return cmd.Output()
	}

	// Seed the temp index from HEAD so `add -A` records a diff against it.
	// Ignore the error: a repo with no commits yet has no HEAD, and an empty
	// index is the correct base there (every file reads as added).
	_, _ = run("read-tree", "HEAD")
	if _, err := run("add", "-A"); err != nil {
		return "", false
	}
	treeOut, err := run("write-tree")
	if err != nil {
		return "", false
	}
	tree := strings.TrimSpace(string(treeOut))
	if tree == "" {
		return "", false
	}

	args := []string{"commit-tree", tree, "-m",
		"checkpoint:" + time.Now().UTC().Format(time.RFC3339Nano)}
	if head, err := run("rev-parse", "--verify", "-q", "HEAD"); err == nil {
		if h := strings.TrimSpace(string(head)); h != "" {
			args = append(args, "-p", h)
		}
	}
	commitOut, err := run(args...)
	if err != nil {
		return "", false
	}
	commit := strings.TrimSpace(string(commitOut))
	if commit == "" {
		return "", false
	}
	return commit, true
}

func (s *Session) switchToAdapter(adapter agents.Adapter) error {
	s.interactionMu.Lock()
	defer s.interactionMu.Unlock()

	s.mu.Lock()
	fromAgent := s.Assistant
	oldChat := s.chat
	pendingAsk := s.pendingAsk != nil
	alreadySwapping := s.swapping
	s.mu.Unlock()
	if adapter.Name == fromAgent {
		return nil
	}
	if alreadySwapping {
		return errors.New("agent switch already in progress")
	}
	if pendingAsk {
		return errors.New("cannot switch agents while AskUserQuestion is awaiting an answer")
	}
	if oldChat != nil {
		if oldChat.TurnActive() {
			return errors.New("cannot switch agents while a turn is active")
		}
		if pending, ok := oldChat.(approvalCardResurfacer); ok {
			if _, active := pending.PendingApprovalCard(); active {
				return errors.New("cannot switch agents while an approval or input request is active")
			}
		}
	}

	if err := s.Checkpoint("switch"); err != nil {
		return err
	}
	s.mu.Lock()
	s.swapping = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.swapping = false
		s.mu.Unlock()
	}()

	handoff, handoffHTML := s.brokerHandoff(fromAgent, adapter.Name)

	// Prepare the target structured backend while the old one remains alive.
	// startChatBackend installs into s.chat, so snapshot every affected field
	// and restore it if either backend or PTY startup fails.
	s.mu.Lock()
	oldRespawn := s.chatRespawn
	oldAIGen := s.aiGen
	oldTitleGen := s.titleGen
	oldClaudeID := s.chatSessionID
	oldCodexID := s.codexThreadID
	s.chat = nil
	s.chatRespawn = nil
	resumeClaude := s.chatSessionID
	resumeCodex := s.codexThreadID
	s.mu.Unlock()
	if err := s.startChatBackend(adapter, resumeClaude, false, resumeCodex, ""); err != nil {
		s.mu.Lock()
		s.chat = oldChat
		s.chatRespawn = oldRespawn
		s.aiGen = oldAIGen
		s.titleGen = oldTitleGen
		s.chatSessionID = oldClaudeID
		s.codexThreadID = oldCodexID
		s.mu.Unlock()
		_ = s.persistMetadata()
		return fmt.Errorf("start %s chat backend: %w", adapter.Name, err)
	}
	s.mu.Lock()
	newChat := s.chat
	newRespawn := s.chatRespawn
	newAIGen := s.aiGen
	newTitleGen := s.titleGen
	s.mu.Unlock()

	_, oldStructuredErr := backendFor(s.adapter.Protocol)
	_, newStructuredErr := backendFor(adapter.Protocol)
	oldStructured := oldStructuredErr == nil
	newStructured := newStructuredErr == nil
	var f *os.File
	var cmd *exec.Cmd
	// Structured Claude↔Codex switches leave the Terminal tab's shell alone;
	// only the headless chat backend changes. Crossing the legacy/structured
	// boundary must replace the PTY with the target's correct surface.
	if oldStructured != newStructured || !newStructured {
		if newStructured {
			tmuxPath, _ := exec.LookPath("tmux")
			if os.Getenv("CONDUIT_DISABLE_TERMINAL_TMUX") != "" {
				tmuxPath = ""
			}
			argv := terminalShellArgv(tmuxPath, sanitizeTmuxName(s.ID))
			cmd = exec.Command(argv[0], argv[1:]...)
		} else {
			cmd = exec.Command(adapter.Command[0], append(adapter.Command[1:], adapter.Args...)...)
		}
		cmd.Dir = s.workspaceDir
		cmd.Env = s.commandEnv(map[string]string{
			"AGENT_NAME": adapter.Name,
			"FROM_AGENT": fromAgent,
			"TO_AGENT":   adapter.Name,
		})
		var err error
		f, err = pty.Start(cmd)
		if err != nil {
			if newChat != nil {
				_ = newChat.Close()
			}
			s.mu.Lock()
			s.chat = oldChat
			s.chatRespawn = oldRespawn
			s.aiGen = oldAIGen
			s.titleGen = oldTitleGen
			s.chatSessionID = oldClaudeID
			s.codexThreadID = oldCodexID
			s.mu.Unlock()
			_ = s.persistMetadata()
			return fmt.Errorf("start %s terminal backend: %w", adapter.Name, err)
		}
		_ = pty.Setsize(f, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	}

	// External adapters may still use on_swap, but production continuity is
	// broker-owned. A hook failure is diagnostic only and cannot veto a live
	// target backend.
	if err := s.runHookBestEffort(s.hooks.OnSwap, map[string]string{
		"FROM_AGENT": fromAgent,
		"TO_AGENT":   adapter.Name,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: on_swap hook: %v (switch continues)\n", s.ID, err)
	}

	s.mu.Lock()
	oldPTY := s.pty
	oldCmd := s.cmd
	s.Assistant = adapter.Name
	s.adapter = adapter
	s.hooks = adapter.Hooks
	if f != nil {
		s.pty = f
		s.cmd = cmd
	}
	s.chat = newChat
	s.chatRespawn = newRespawn
	s.aiGen = newAIGen
	s.titleGen = newTitleGen
	s.handoffHTML = handoffHTML
	s.pendingHandoff = handoff
	s.pendingHandoffAgent = adapter.Name
	s.phase = "running"
	s.health = "healthy"
	s.reasonCode = "agent_switched"
	s.mu.Unlock()

	if err := s.persistHandoffSection(handoffHTML); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: persist switch handoff: %v\n", s.ID, err)
	}
	if err := s.renderHandoffFile(); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: render switch handoff: %v\n", s.ID, err)
	}
	if err := s.persistMetadata(); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: persist switched metadata: %v\n", s.ID, err)
	}

	if f != nil && oldPTY != nil {
		_ = oldPTY.Close()
	}
	if f != nil && oldCmd != nil && oldCmd.Process != nil {
		_ = oldCmd.Process.Kill()
		_, _ = oldCmd.Process.Wait()
	}
	if oldChat != nil {
		_ = oldChat.Close()
	}
	if err := s.runHookBestEffort(adapter.Hooks.OnStart, map[string]string{
		"AGENT_NAME": adapter.Name,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: switched on_start hook: %v (session continues)\n", s.ID, err)
	}
	if f != nil {
		go s.drain(f)
	}
	return nil
}

func (s *Session) persistHandoffSection(section string) error {
	data, err := os.ReadFile(s.memoryPath)
	if err != nil {
		return err
	}
	idx := handoffSectionPattern.FindSubmatchIndex(data)
	if len(idx) < 4 {
		return fmt.Errorf("handoff section missing")
	}
	out := make([]byte, 0, len(data)+len(section))
	out = append(out, data[:idx[2]]...)
	out = append(out, section...)
	out = append(out, data[idx[3]:]...)
	if err := atomicWriteFile(s.memoryPath, out); err != nil {
		return err
	}
	if info, err := os.Stat(s.memoryPath); err == nil {
		s.lastMemoryModTime = info.ModTime()
	}
	return nil
}

func (s *Session) renderHandoffFile() error {
	return atomicWriteFile(s.handoffPath, []byte("<!doctype html><html><body><section data-section=\"handoff\">"+s.handoffHTML+"</section></body></html>\n"))
}

func (s *Session) runHook(script string, extraEnv map[string]string) error {
	if strings.TrimSpace(script) == "" {
		return nil
	}
	cmd := exec.Command("sh", "-lc", script)
	cmd.Dir = s.workspaceDir
	cmd.Env = s.commandEnv(extraEnv)
	return cmd.Run()
}

func (s *Session) runHookBestEffort(script string, extraEnv map[string]string) error {
	if strings.TrimSpace(script) == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-lc", script)
	cmd.Dir = s.workspaceDir
	cmd.Env = s.commandEnv(extraEnv)
	if err := cmd.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("hook timed out after 5s")
		}
		return err
	}
	return nil
}

func (s *Session) loadHandoffHTML() string {
	data, err := os.ReadFile(s.memoryPath)
	if err != nil {
		return ""
	}
	section, err := extractHandoffSection(data)
	if err != nil {
		return ""
	}
	return section
}

func extractHandoffSection(data []byte) (string, error) {
	matches := handoffSectionPattern.FindSubmatch(data)
	if len(matches) != 2 {
		return "", fmt.Errorf("handoff section missing")
	}
	return strings.TrimSpace(string(matches[1])), nil
}

func (s *Session) restoreSnapshot(snapshot []byte) {
	if len(snapshot) > ringSize {
		snapshot = snapshot[len(snapshot)-ringSize:]
	}
	copy(s.ring, snapshot)
	s.ringPos = len(snapshot)
	if len(snapshot) == ringSize {
		s.ringPos = 0
		s.ringFull = true
	}
}
