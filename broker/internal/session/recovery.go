package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

func (m *Manager) sessionOnDisk(id string) bool {
	_, err := os.Stat(filepath.Join(m.conduitRoot, "sessions", id, "meta.json"))
	return err == nil
}

// sessionArchived reports whether id has a canonical archived-sessions
// directory (i.e. was deleted via DeleteSession). It checks only the
// canonical `archived-sessions/<id>` path; timestamped cold-storage
// copies (`archived-sessions/<id>.<ts>`) are not considered here — only
// the canonical path is written by the first DeleteSession, so its
// presence is the reliable tombstone. Caller must hold m.mu.
func (m *Manager) sessionArchived(id string) bool {
	info, err := os.Stat(filepath.Join(m.conduitRoot, archivedSessionsDirName, id))
	return err == nil && info.IsDir()
}

func (m *Manager) recoverSessionLocked(id string) (*Session, error) {
	metaPath := filepath.Join(m.conduitRoot, "sessions", id, "meta.json")
	data, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, err
	}
	var meta sessionMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil, err
	}
	if meta.Assistant == "" {
		return nil, fmt.Errorf("session %s missing assistant metadata", id)
	}
	// Restart budget spent? Refuse to respawn — the caller archives the
	// session so it reads as ended instead of crash-looping forever
	// (restartbudget.go).
	if meta.ConsecutiveFastExits >= maxConsecutiveFastExits {
		return nil, fmt.Errorf("session %s: agent died %d times in a row within %s of spawn: %w",
			id, meta.ConsecutiveFastExits, fastExitWindow, errSessionGaveUp)
	}
	adapter, err := m.registry.Get(meta.Assistant)
	if err != nil {
		return nil, err
	}
	scrollbackPath := filepath.Join(m.conduitRoot, "sessions", id, "scrollback.bin")
	snapshot, err := os.ReadFile(scrollbackPath)
	if err != nil {
		return nil, err
	}
	memoryPath := filepath.Join(m.conduitRoot, "memory", "sessions", id+".html")
	if _, err := os.Stat(memoryPath); err != nil {
		return nil, err
	}
	lastCheckpoint := time.Time{}
	if meta.LastCheckpoint != "" {
		lastCheckpoint, _ = time.Parse(time.RFC3339Nano, meta.LastCheckpoint)
	}
	// Allocate the preview $PORT up front (same as the create path) so
	// newSession hands it to the recovered agent's chat backend env — a
	// recovered session has a freshly-spawned, live agent, and allocating
	// after newSession would both deny it $PORT and race the watchdog
	// goroutine's lock-free read of s.previewPort.
	previewPort := m.allocatePreviewPortLocked()
	sessionDir := filepath.Join(m.conduitRoot, "sessions", id)
	// KillMode=process means the previous broker's agent process survives a
	// broker restart. Reap it (exact recorded PID + start-time check, never by
	// name) BEFORE spawning the replacement, or both processes interleave
	// writes into the same conversation store.
	reapOrphanAgent(sessionDir, procStartTime)
	// Use the adapter's manifest config_dir for conversation discovery so
	// a third-party adapter with a non-standard config directory is found.
	// Falls back gracefully: if ConfigDir is empty (shouldn't happen after
	// applyLegacyDefaults) chatConversationOnDisk returns false, which just
	// means resume IDs are cleared — safe, if conservative.
	hasAgentConversation := chatConversationOnDisk(sessionDir, adapter.ConfigDir)
	// Conversations land in the shared canonical config dir (pointed at by
	// CLAUDE_CONFIG_DIR / CODEX_HOME — credseed.go) rather than the
	// per-session agent-home, so chatConversationOnDisk (which only looks
	// under agent-home) always returns false for the Option-B broker-owned
	// dir. Check that dir directly for the specific latched session id.
	// (Option A — the operator's real ~/.claude/~/.codex — isn't checked
	// here; those transcripts predate this session and aren't under
	// conduitRoot, so this glob only recovers the Option-B, login-less-box
	// case. That mirrors today's behaviour.)
	if !hasAgentConversation && meta.ClaudeChatSessionID != "" {
		if subdir := configSubdir(adapter.LoginProvider); subdir != "" {
			pat := filepath.Join(m.conduitRoot, "agent-cred", subdir, "projects", "*", meta.ClaudeChatSessionID+".jsonl")
			if ms, _ := filepath.Glob(pat); len(ms) > 0 {
				hasAgentConversation = true
			}
		}
	}
	resumeID := meta.ClaudeChatSessionID
	if !hasAgentConversation {
		resumeID = ""
	}
	// The CodexThreadID meta slot doubles as the generic "agent's own
	// conversation id" for protocol backends that resume by id (codex's
	// thread, opencode's ses_). Gate it on the backing store still existing so
	// a wiped home with a stale id doesn't make every respawn fast-exit.
	// Server-backed agents (opencode) persist conversations in a data store
	// (a single global SQLite DB under DataDir) rather than per-session
	// conversation files, so gate those on the store; the rest gate on the
	// codex conversation files as before.
	codexThreadID := meta.CodexThreadID
	if !agentResumeStoreOnDisk(sessionDir, adapter) {
		codexThreadID = ""
	}
	s, err := newSession(id, adapter, sessionOptions{
		repoRoot:       m.repoRoot,
		conduitRoot:    m.conduitRoot,
		snapshot:       snapshot,
		lastCheckpoint: lastCheckpoint,
		termgrid:       m.termgrid,
		replayBaseDir:  m.replayBaseDir,
		previewPort:    previewPort,
		// Restore the user-chosen workspace dir so the recovered agent
		// spawns back in the directory the user picked, not the empty
		// per-session work/ dir. Falls back to adapter/worktreeDir
		// for pre-feature sessions that have no workspace_dir field.
		requestedCWD: meta.WorkspaceDir,
		// Resume the agent's own conversation so the recovered session
		// keeps its memory (the conversation files live in the
		// persistent per-session agent-home). Guarded on the files
		// actually existing — a wiped home with a stale id would make
		// every respawn fast-exit on "No conversation found".
		resumeChatSessionID: resumeID,
		// Pre-latch sessions (conversation on disk, no persisted id —
		// created before the resume fix) fall back to --continue, which
		// resolves this session's own newest conversation.
		continueLatestChat:  resumeID == "" && hasAgentConversation,
		resumeCodexThreadID: codexThreadID,
		modelCatalog:        m.ModelCatalog,
		codexBinary:         m.codexBinary,
		// Derive credential providers from the registry so new adapters
		// with a login_provider are automatically mirrored into the
		// session's ephemeral HOME (WS-1.2).
		credentialProviders: credentialProvidersFromRegistry(m.registry),
		// Pass the credential store so recovered sessions can use the
		// app-pushed OAuth blob (Option B / shared-creds) — without this,
		// ensureSharedCred sees a nil store, picks Option A (host $HOME),
		// and recovered sessions ignore any app-pushed credential entirely.
		credStore:           m.credStore,
		pendingHandoff:      meta.PendingHandoff,
		pendingHandoffAgent: meta.PendingHandoffAgent,
	})
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.rows = meta.Rows
	s.cols = meta.Cols
	if meta.Phase != "" {
		s.phase = meta.Phase
	}
	if meta.Health != "" {
		s.health = meta.Health
	}
	if meta.ReasonCode != "" {
		s.reasonCode = meta.ReasonCode
	}
	// A recovered session has a freshly-spawned, LIVE agent process. If the
	// persisted phase was a non-live state (the "stalled" the watchdog records
	// when the prior process died, or "exited"), don't resurrect it: that
	// opens the recovered session read-only on the app until the next watchdog
	// tick — the "stuck not-running after a reconnect" report. Normalize to a
	// live running phase; the watchdog refines health from here.
	if !isLivePhase(s.phase) {
		s.phase = "running"
		s.health = "healthy"
		s.reasonCode = "recovered"
	}
	s.exitCode = meta.ExitCode
	// Restore the spent restart budget so a crash-looper keeps counting
	// up across recoveries rather than starting fresh each time.
	s.consecutiveFastExits = meta.ConsecutiveFastExits
	// Restore usage totals + the context gauge so a broker restart
	// doesn't blank the Session Info usage card. The totals are lifetime
	// sums and the gauge is the latest turn's snapshot — both still true
	// after recovery; the next turn accumulates / overwrites as usual.
	s.totalInputTokens = meta.TotalInputTokens
	s.totalOutputTokens = meta.TotalOutputTokens
	s.totalCachedTokens = meta.TotalCachedTokens
	s.totalCostUSD = meta.TotalCostUSD
	s.contextUsedTokens = meta.ContextUsedTokens
	s.contextWindowTokens = meta.ContextWindowTokens
	s.hasUsage = meta.TotalInputTokens > 0 || meta.TotalOutputTokens > 0 ||
		meta.ContextUsedTokens > 0
	// Restore the AI title (task: ai-session-titles) so a recovered
	// session keeps its name without re-generating.
	s.aiTitle = meta.AITitle
	// Restore the ORIGINAL wall-clock timestamps so a recovered session
	// reports when it was really created / last active, not the recovery
	// moment. newSession() seeds these to time.Now(); override with the
	// persisted values when present (pre-feature sessions have none and
	// keep the recovery-time fallback).
	if meta.StartedAt != "" {
		if t, err := time.Parse(time.RFC3339Nano, meta.StartedAt); err == nil {
			s.startedAt = t
		}
	}
	if meta.LastActivityAt != "" {
		if t, err := time.Parse(time.RFC3339Nano, meta.LastActivityAt); err == nil {
			s.lastOutput = t
		}
	}
	s.mu.Unlock()
	s.switchFn = func(next string) error {
		nextAdapter, err := m.registry.Get(next)
		if err != nil {
			return err
		}
		return s.Switch(nextAdapter)
	}
	if m.pushNotifier != nil {
		s.SetPushNotifier(m.pushNotifier, m.pushIdentity)
	}
	m.sessions[id] = s
	m.recordRecentProjectLocked(s.WorkspaceDir(), s.Assistant, s.ID)
	go func() {
		<-s.Done()
		m.mu.Lock()
		delete(m.sessions, id)
		m.mu.Unlock()
	}()
	return s, nil
}

// agentResumeStoreOnDisk reports whether the resume id's backing store still
// lives in the session's persistent agent-home. For a server-backed agent
// with a DataDir (opencode), resume hangs off a single global session store
// (opencode.db) under that dir, so any file under agent-home/<DataDir>
// counts. For the rest (codex), it falls back to the codex conversation-file
// gate. Used by recovery to avoid seeding a stale resume id whose store is
// gone (wiped home → the agent can't find the conversation).
func agentResumeStoreOnDisk(sessionDir string, adapter agents.Adapter) bool {
	if dir := strings.TrimSpace(adapter.DataDir); dir != "" {
		matches, _ := filepath.Glob(filepath.Join(sessionDir, "agent-home", dir, "*"))
		return len(matches) > 0
	}
	return chatConversationOnDisk(sessionDir, ".codex")
}

// chatConversationOnDisk reports whether the session's persistent
// agent-home still holds any conversation/rollout files for the given
// agent config dir (".claude" / ".codex"). Recovery uses it to avoid
// seeding a resume id whose backing files are gone (wiped home → the
// CLI fast-exits with "No conversation found" on every respawn).
func chatConversationOnDisk(sessionDir, configDir string) bool {
	patterns := []string{
		filepath.Join(sessionDir, "agent-home", configDir, "projects", "*", "*.jsonl"),
		filepath.Join(sessionDir, "agent-home", configDir, "sessions", "*", "*", "*", "*", "*.jsonl"),
	}
	for _, pat := range patterns {
		if matches, _ := filepath.Glob(pat); len(matches) > 0 {
			return true
		}
	}
	return false
}
