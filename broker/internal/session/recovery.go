package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func (m *Manager) sessionOnDisk(id string) bool {
	_, err := os.Stat(filepath.Join(m.conduitRoot, "sessions", id, "meta.json"))
	return err == nil
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
	hasClaudeConversation := chatConversationOnDisk(sessionDir, ".claude")
	resumeID := meta.ClaudeChatSessionID
	if !hasClaudeConversation {
		resumeID = ""
	}
	codexThreadID := meta.CodexThreadID
	if !chatConversationOnDisk(sessionDir, ".codex") {
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
		continueLatestChat:  resumeID == "" && hasClaudeConversation,
		resumeCodexThreadID: codexThreadID,
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
