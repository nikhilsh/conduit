package session

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// ExternalSession is a single discovered session from an external agent CLI
// (Claude or Codex) that Conduit did NOT start. Returned by DiscoverExternal.
type ExternalSession struct {
	Agent          string `json:"agent"`       // "claude" | "codex"
	ExternalID     string `json:"external_id"` // raw claude session uuid / codex thread id
	Title          string `json:"title"`       // first user prompt preview, ≤120 chars
	CWD            string `json:"cwd"`
	GitBranch      string `json:"git_branch"`
	TurnCount      int    `json:"turn_count"`
	LastActivityAt int64  `json:"last_activity_at"` // unix millis
	IsRunning      bool   `json:"is_running"`
	PID            int    `json:"pid"`
}

// DiscoveredResponse is the full response body for GET /api/sessions/discovered.
type DiscoveredResponse struct {
	Sessions    []ExternalSession `json:"sessions"`
	NextCursor  string            `json:"next_cursor"`
	TotalOnDisk int               `json:"total_on_disk"`
}

// discoveryCacheTTL is how long the raw Found Sessions scan is cached before
// the next call triggers a fresh file-system scan. New sessions started
// outside Conduit appear within one TTL window; 45 s is well within the
// practical "just started a session, now opening Found Sessions" latency.
const discoveryCacheTTL = 45 * time.Second

// minMeaningfulTurns is the discovery quality floor: sessions with fewer than
// this many turns (Claude exchange pairs / Codex turns) are treated as trivial
// one-shots and excluded from discovery so the list and count stay meaningful.
const minMeaningfulTurns = 2

// DiscoverExternalSessions returns sessions started outside Conduit, sorted
// recent-first.
//
// Filter parameters:
//   - q: case-insensitive substring over title/cwd/git_branch (empty = no filter)
//   - agents: which agents to scan ("claude", "codex", or both)
//
// Sessions whose external_id matches a Conduit-own session's
// claude_chat_session_id or codex_thread_id are excluded (dedupe).
//
// The raw file-system scan is cached for discoveryCacheTTL so repeat calls
// (e.g. polling from the app) are served from memory. Dedup, quality floor,
// agent filter, q filter, and sort are applied per-call on a copy so an
// adopted / forked session disappears immediately without waiting for the TTL.
func (m *Manager) DiscoverExternalSessions(q string, agents []string) DiscoveredResponse {
	wantClaude := len(agents) == 0
	wantCodex := len(agents) == 0
	for _, a := range agents {
		switch strings.ToLower(strings.TrimSpace(a)) {
		case "claude":
			wantClaude = true
		case "codex":
			wantCodex = true
		}
	}

	// --- cache layer: raw scan (no dedup baked in) ---------------------------
	// Hold the mutex for the whole read-or-refresh so only one goroutine
	// does the expensive scan at a time. The scan itself is fast enough
	// (hundreds of files, no network) that blocking callers briefly is
	// simpler and safer than a double-checked-lock pattern.
	m.discCacheMu.Lock()
	if m.discCacheAt.IsZero() || time.Since(m.discCacheAt) >= discoveryCacheTTL {
		// Cache miss or expired — re-scan both agents unconditionally so the
		// cached slice always covers the full universe. Per-call agent
		// filtering happens below after we release the lock.
		var raw []ExternalSession
		if claudeSessions, err := scanClaudeSessions(nil); err != nil {
			log.Printf("found-sessions: claude scan error: %v", err)
		} else {
			raw = append(raw, claudeSessions...)
		}
		if codexSessions, err := scanCodexSessions(nil); err != nil {
			log.Printf("found-sessions: codex scan error: %v", err)
		} else {
			raw = append(raw, codexSessions...)
		}
		m.discCache = raw
		m.discCacheAt = time.Now()
	}
	// Copy the cached slice so per-call filtering never mutates the cache.
	cached := make([]ExternalSession, len(m.discCache))
	copy(cached, m.discCache)
	m.discCacheMu.Unlock()
	// -------------------------------------------------------------------------

	// Per-call dedup: collect Conduit-own IDs fresh on every call so an
	// adopted/forked session disappears immediately (not after the TTL).
	ownIDs := m.ownExternalIDs()

	var all []ExternalSession
	for _, s := range cached {
		// Agent filter.
		if s.Agent == "claude" && !wantClaude {
			continue
		}
		if s.Agent == "codex" && !wantCodex {
			continue
		}
		// Dedup: skip sessions Conduit already owns.
		if _, own := ownIDs[s.ExternalID]; own {
			continue
		}
		all = append(all, s)
	}

	// Quality floor: drop trivial single-turn one-shots (quick Qs / tests /
	// aborted starts) from discovery. On a real box roughly half the on-disk
	// sessions are a single exchange and aren't worth resuming; surfacing them
	// just inflates the count and clutters the list. They remain on disk and
	// resumable from the CLI — we only avoid advertising them in the app.
	// (Claude TurnCount is exchange PAIRS, Codex is raw turns; <=1 = trivial
	// for both.)
	kept := all[:0]
	for _, s := range all {
		if s.TurnCount >= minMeaningfulTurns {
			kept = append(kept, s)
		}
	}
	all = kept

	total := len(all)

	// Apply q filter.
	if q = strings.TrimSpace(q); q != "" {
		ql := strings.ToLower(q)
		filtered := all[:0]
		for _, s := range all {
			if strings.Contains(strings.ToLower(s.Title), ql) ||
				strings.Contains(strings.ToLower(s.CWD), ql) ||
				strings.Contains(strings.ToLower(s.GitBranch), ql) {
				filtered = append(filtered, s)
			}
		}
		all = filtered
	}

	// Sort recent-first.
	sort.Slice(all, func(i, j int) bool {
		return all[i].LastActivityAt > all[j].LastActivityAt
	})

	log.Printf("found-sessions: discovered %d total (%d after filter), claude=%v codex=%v q=%q",
		total, len(all), wantClaude, wantCodex, q)

	return DiscoveredResponse{
		Sessions:    all,
		NextCursor:  "",
		TotalOnDisk: total,
	}
}

// ownExternalIDs returns the set of claude_chat_session_id / codex_thread_id
// values from Conduit's own sessions — for deduplication in discovery.
func (m *Manager) ownExternalIDs() map[string]struct{} {
	// From live sessions (in memory).
	m.mu.RLock()
	live := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		live = append(live, s)
	}
	m.mu.RUnlock()

	ids := make(map[string]struct{})
	for _, s := range live {
		s.mu.Lock()
		chatID := s.chatSessionID
		codexID := s.codexThreadID
		s.mu.Unlock()
		if chatID != "" {
			ids[chatID] = struct{}{}
		}
		if codexID != "" {
			ids[codexID] = struct{}{}
		}
	}

	// From on-disk sessions (meta.json).
	sessDir := filepath.Join(m.conduitRoot, "sessions")
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return ids
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		metaPath := filepath.Join(sessDir, e.Name(), "meta.json")
		data, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var meta sessionMetadata
		if json.Unmarshal(data, &meta) != nil {
			continue
		}
		if meta.ClaudeChatSessionID != "" {
			ids[meta.ClaudeChatSessionID] = struct{}{}
		}
		if meta.CodexThreadID != "" {
			ids[meta.CodexThreadID] = struct{}{}
		}
	}
	return ids
}

// ---------------------------------------------------------------------------
// Claude scanner
// ---------------------------------------------------------------------------

// claudeRunningPIDs reads ~/.claude/sessions/<pid>.json and returns {sessionId → pid}
// for processes that are still alive.
func claudeRunningPIDs() map[string]int {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	sessDir := filepath.Join(home, ".claude", "sessions")
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return nil
	}
	pidMap := make(map[string]int)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		pidStr := strings.TrimSuffix(e.Name(), ".json")
		pid, err := strconv.Atoi(pidStr)
		if err != nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join(sessDir, e.Name()))
		if err != nil {
			continue
		}
		var rec struct {
			SessionID string `json:"sessionId"`
		}
		if json.Unmarshal(data, &rec) != nil || rec.SessionID == "" {
			continue
		}
		if pidAlive(pid) {
			pidMap[rec.SessionID] = pid
		}
	}
	return pidMap
}

// pidAlive checks whether a process with the given PID exists (Linux /proc).
func pidAlive(pid int) bool {
	_, err := os.Stat(fmt.Sprintf("/proc/%d", pid))
	return err == nil
}

// ParseClaudeJSONL parses a claude .jsonl file and returns an ExternalSession.
// ownIDs is the set of external IDs Conduit already owns (for dedup).
// runningPIDs maps sessionId → pid for currently alive claude processes.
// Returns (session, true) on success; (_, false) when the file should be skipped.
func ParseClaudeJSONL(path string, ownIDs map[string]struct{}, runningPIDs map[string]int) (ExternalSession, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return ExternalSession{}, false
	}

	// Derive cwd from project dir name: slug = abs path with '/' → '-'.
	dirName := filepath.Base(filepath.Dir(path))
	cwdFromDir := claudeSlugToCWD(dirName)

	var sessionID, cwd, gitBranch, firstUserMsg, title string
	var turnCount int
	var lastAt time.Time

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var r struct {
			Type      string `json:"type"`
			SessionID string `json:"sessionId"`
			Timestamp string `json:"timestamp"`
			GitBranch string `json:"gitBranch"`
			CWD       string `json:"cwd"`
			AITitle   string `json:"aiTitle"`
			Message   struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &r) != nil {
			continue
		}
		if r.SessionID != "" && sessionID == "" {
			sessionID = r.SessionID
		}
		if r.CWD != "" && cwd == "" {
			cwd = r.CWD
		}
		if r.GitBranch != "" && gitBranch == "" {
			gitBranch = r.GitBranch
		}
		if ts := parseTimestamp(r.Timestamp); !ts.IsZero() && ts.After(lastAt) {
			lastAt = ts
		}
		switch r.Type {
		case "user":
			turnCount++
			if firstUserMsg == "" {
				firstUserMsg = extractClaudeUserText(r.Message.Content)
			}
		case "assistant":
			turnCount++
		case "ai-title":
			if r.AITitle != "" {
				title = r.AITitle
			}
		}
	}

	if sessionID == "" {
		return ExternalSession{}, false
	}
	if _, own := ownIDs[sessionID]; own {
		return ExternalSession{}, false
	}

	if cwd == "" {
		cwd = cwdFromDir
	}
	if title == "" {
		title = truncate(firstUserMsg, 120)
	}
	if lastAt.IsZero() {
		if info, err := os.Stat(path); err == nil {
			lastAt = info.ModTime()
		}
	}

	pairs := turnCount / 2
	if pairs < 0 {
		pairs = 0
	}
	pid := 0
	if runningPIDs != nil {
		pid = runningPIDs[sessionID]
	}
	return ExternalSession{
		Agent:          "claude",
		ExternalID:     sessionID,
		Title:          title,
		CWD:            cwd,
		GitBranch:      gitBranch,
		TurnCount:      pairs,
		LastActivityAt: lastAt.UnixMilli(),
		IsRunning:      pid != 0,
		PID:            pid,
	}, true
}

// scanClaudeSessions scans ~/.claude/projects/ for external claude sessions.
func scanClaudeSessions(ownIDs map[string]struct{}) ([]ExternalSession, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	projDir := filepath.Join(home, ".claude", "projects")
	if _, err := os.Stat(projDir); os.IsNotExist(err) {
		return nil, nil
	}
	runningPIDs := claudeRunningPIDs()

	slugDirs, err := os.ReadDir(projDir)
	if err != nil {
		return nil, err
	}

	var out []ExternalSession
	for _, slugEntry := range slugDirs {
		if !slugEntry.IsDir() {
			continue
		}
		slugPath := filepath.Join(projDir, slugEntry.Name())
		files, err := os.ReadDir(slugPath)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
				continue
			}
			fpath := filepath.Join(slugPath, f.Name())
			if s, ok := ParseClaudeJSONL(fpath, ownIDs, runningPIDs); ok {
				out = append(out, s)
			}
		}
	}
	return out, nil
}

// claudeSlugToCWD reverses claude's project directory slug to an absolute path.
// Claude's rule: slug = abs path with leading '/' removed, remaining '/' → '-'.
// e.g. "-root-developer-projects-conduit" → "/root/developer/projects/conduit"
// Best-effort: indistinguishable from path components containing '-'.
func claudeSlugToCWD(slug string) string {
	if !strings.HasPrefix(slug, "-") {
		return slug
	}
	return "/" + strings.ReplaceAll(slug[1:], "-", "/")
}

// extractClaudeUserText extracts plain text from a claude user message content.
// Content can be a string or array of {type, text} blocks.
func extractClaudeUserText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s)
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		for _, b := range blocks {
			if b.Type == "text" && strings.TrimSpace(b.Text) != "" {
				return strings.TrimSpace(b.Text)
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Codex scanner
// ---------------------------------------------------------------------------

// ParseCodexRollout parses a codex rollout JSONL file.
// Returns (session, true) on success; (_, false) when the file should be skipped.
func ParseCodexRollout(path string, ownIDs map[string]struct{}) (ExternalSession, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return ExternalSession{}, false
	}

	var sessionID, cwd, firstUserMsg string
	var turnCount int
	var lastAt time.Time

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var outer struct {
			Timestamp string          `json:"timestamp"`
			Type      string          `json:"type"`
			Payload   json.RawMessage `json:"payload"`
		}
		if json.Unmarshal([]byte(line), &outer) != nil {
			continue
		}
		if ts := parseTimestamp(outer.Timestamp); !ts.IsZero() && ts.After(lastAt) {
			lastAt = ts
		}

		switch outer.Type {
		case "session_meta":
			var meta struct {
				ID  string `json:"id"`
				CWD string `json:"cwd"`
			}
			if json.Unmarshal(outer.Payload, &meta) == nil {
				sessionID = meta.ID
				cwd = meta.CWD
			}
		case "response_item":
			var item struct {
				Type    string `json:"type"`
				Role    string `json:"role"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			}
			if json.Unmarshal(outer.Payload, &item) != nil || item.Type != "message" {
				continue
			}
			if item.Role == "assistant" {
				turnCount++
			}
			if item.Role == "user" && firstUserMsg == "" {
				for _, c := range item.Content {
					if (c.Type == "input_text") && !strings.HasPrefix(c.Text, "<") {
						if t := strings.TrimSpace(c.Text); t != "" {
							firstUserMsg = t
							break
						}
					}
				}
			}
		}
	}

	if sessionID == "" {
		return ExternalSession{}, false
	}
	if _, own := ownIDs[sessionID]; own {
		return ExternalSession{}, false
	}
	if lastAt.IsZero() {
		if info, err := os.Stat(path); err == nil {
			lastAt = info.ModTime()
		}
	}

	return ExternalSession{
		Agent:          "codex",
		ExternalID:     sessionID,
		Title:          truncate(firstUserMsg, 120),
		CWD:            cwd,
		GitBranch:      "",
		TurnCount:      turnCount,
		LastActivityAt: lastAt.UnixMilli(),
		IsRunning:      false,
		PID:            0,
	}, true
}

// scanCodexSessions scans ~/.codex/sessions/YYYY/MM/DD/ for rollout files.
func scanCodexSessions(ownIDs map[string]struct{}) ([]ExternalSession, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	baseDir := filepath.Join(home, ".codex", "sessions")
	if _, err := os.Stat(baseDir); os.IsNotExist(err) {
		return nil, nil
	}

	var out []ExternalSession
	years, err := os.ReadDir(baseDir)
	if err != nil {
		return nil, err
	}
	for _, yEntry := range years {
		if !yEntry.IsDir() {
			continue
		}
		months, _ := os.ReadDir(filepath.Join(baseDir, yEntry.Name()))
		for _, mEntry := range months {
			if !mEntry.IsDir() {
				continue
			}
			days, _ := os.ReadDir(filepath.Join(baseDir, yEntry.Name(), mEntry.Name()))
			for _, dEntry := range days {
				if !dEntry.IsDir() {
					continue
				}
				dayDir := filepath.Join(baseDir, yEntry.Name(), mEntry.Name(), dEntry.Name())
				files, _ := os.ReadDir(dayDir)
				for _, f := range files {
					if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
						continue
					}
					fpath := filepath.Join(dayDir, f.Name())
					if s, ok := ParseCodexRollout(fpath, ownIDs); ok {
						out = append(out, s)
					}
				}
			}
		}
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Transcript reader
// ---------------------------------------------------------------------------

// ExternalTranscript returns the conversation transcript for an external session
// in the same ConvEntry shape used by Conduit's own sessions.
func ExternalTranscript(agent, externalID string) ([]ConvEntry, error) {
	switch strings.ToLower(agent) {
	case "claude":
		return claudeTranscript(externalID)
	case "codex":
		return codexTranscript(externalID)
	default:
		return nil, fmt.Errorf("unknown agent %q", agent)
	}
}

// TranscriptResult is returned by ExternalTranscriptSince: the filtered items
// and the maximum timestamp seen across ALL items (not just the filtered ones)
// so polling clients can advance their cursor even when no new items arrived.
type TranscriptResult struct {
	Items    []ConvEntry
	LatestTs int64 // unix millis of the newest item; 0 if the transcript is empty
}

// ExternalTranscriptSince returns the transcript for an external session with
// optional incremental filtering for Flow-B "Watch live" polling.
//
//   - sinceMs == 0: full transcript (same as ExternalTranscript)
//   - sinceMs  > 0: only items whose timestamp is STRICTLY greater than sinceMs
//
// LatestTs is always the maximum ts in the full file, even when filtering
// removes all items, so the client can advance its cursor on each poll.
func ExternalTranscriptSince(agent, externalID string, sinceMs int64) (TranscriptResult, error) {
	all, err := ExternalTranscript(agent, externalID)
	if err != nil {
		all = nil // return what we have (partial parse)
	}

	var latestTs int64
	for _, e := range all {
		if ts := parseTimestamp(e.Ts); !ts.IsZero() {
			if ms := ts.UnixMilli(); ms > latestTs {
				latestTs = ms
			}
		}
	}

	if sinceMs <= 0 {
		return TranscriptResult{Items: all, LatestTs: latestTs}, err
	}

	filtered := all[:0:0]
	for _, e := range all {
		ts := parseTimestamp(e.Ts)
		if ts.IsZero() {
			continue // item with no parseable ts: always include in full mode, skip in since mode
		}
		if ts.UnixMilli() > sinceMs {
			filtered = append(filtered, e)
		}
	}
	return TranscriptResult{Items: filtered, LatestTs: latestTs}, err
}

func claudeTranscript(sessionID string) ([]ConvEntry, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	projDir := filepath.Join(home, ".claude", "projects")
	slugDirs, err := os.ReadDir(projDir)
	if err != nil {
		return nil, err
	}
	for _, slugEntry := range slugDirs {
		if !slugEntry.IsDir() {
			continue
		}
		fpath := filepath.Join(projDir, slugEntry.Name(), sessionID+".jsonl")
		if _, err := os.Stat(fpath); err != nil {
			continue
		}
		return parseClaudeTranscript(fpath)
	}
	return nil, fmt.Errorf("claude session %s not found", sessionID)
}

func parseClaudeTranscript(path string) ([]ConvEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []ConvEntry
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var r struct {
			Type      string `json:"type"`
			Timestamp string `json:"timestamp"`
			Message   struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &r) != nil {
			continue
		}
		ts := r.Timestamp
		if ts == "" {
			ts = time.Now().UTC().Format(time.RFC3339)
		}
		switch r.Type {
		case "user":
			text := extractClaudeUserText(r.Message.Content)
			if text == "" {
				continue
			}
			out = append(out, ConvEntry{Role: "user", Content: text, Ts: ts})
		case "assistant":
			// Extract text content blocks from the assistant message.
			var msg struct {
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			}
			if json.Unmarshal([]byte(line), &struct {
				Message *struct {
					Content []struct {
						Type string `json:"type"`
						Text string `json:"text"`
					} `json:"content"`
				} `json:"message"`
			}{Message: &msg}) != nil {
				continue
			}
			var sb strings.Builder
			for _, c := range msg.Content {
				if c.Type == "text" {
					sb.WriteString(c.Text)
				}
			}
			if sb.Len() == 0 {
				continue
			}
			out = append(out, ConvEntry{Role: "assistant", Content: sb.String(), Ts: ts})
		}
	}
	return out, nil
}

func codexTranscript(sessionID string) ([]ConvEntry, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	baseDir := filepath.Join(home, ".codex", "sessions")
	years, err := os.ReadDir(baseDir)
	if err != nil {
		return nil, err
	}
	for _, yEntry := range years {
		if !yEntry.IsDir() {
			continue
		}
		months, _ := os.ReadDir(filepath.Join(baseDir, yEntry.Name()))
		for _, mEntry := range months {
			if !mEntry.IsDir() {
				continue
			}
			days, _ := os.ReadDir(filepath.Join(baseDir, yEntry.Name(), mEntry.Name()))
			for _, dEntry := range days {
				if !dEntry.IsDir() {
					continue
				}
				dayDir := filepath.Join(baseDir, yEntry.Name(), mEntry.Name(), dEntry.Name())
				files, _ := os.ReadDir(dayDir)
				for _, f := range files {
					if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
						continue
					}
					if !strings.Contains(f.Name(), sessionID) {
						continue
					}
					return parseCodexTranscript(filepath.Join(dayDir, f.Name()))
				}
			}
		}
	}
	return nil, fmt.Errorf("codex session %s not found", sessionID)
}

func parseCodexTranscript(path string) ([]ConvEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []ConvEntry
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var outer struct {
			Timestamp string          `json:"timestamp"`
			Type      string          `json:"type"`
			Payload   json.RawMessage `json:"payload"`
		}
		if json.Unmarshal([]byte(line), &outer) != nil {
			continue
		}
		if outer.Type != "response_item" {
			continue
		}
		var item struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		}
		if json.Unmarshal(outer.Payload, &item) != nil || item.Type != "message" {
			continue
		}
		role := item.Role
		if role != "user" && role != "assistant" {
			continue
		}
		var sb strings.Builder
		for _, c := range item.Content {
			if c.Type == "input_text" || c.Type == "output_text" {
				if !strings.HasPrefix(c.Text, "<") {
					sb.WriteString(c.Text)
				}
			}
		}
		if sb.Len() == 0 {
			continue
		}
		ts := outer.Timestamp
		if ts == "" {
			ts = time.Now().UTC().Format(time.RFC3339)
		}
		out = append(out, ConvEntry{Role: role, Content: sb.String(), Ts: ts})
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Fork worktree helpers
// ---------------------------------------------------------------------------

// FindGitRepoRoot walks up from dir until it finds a git repo root, or returns
// "", false when dir is not inside a git working tree.
func FindGitRepoRoot(dir string) (string, bool) {
	if dir == "" {
		return "", false
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", false
	}
	root := strings.TrimSpace(string(out))
	return root, root != ""
}

// CreateForkWorktree creates a git worktree at worktreePath branched off the
// HEAD of repoRoot. The branch is named conduit/fork-<short> where <short> is
// the first 8 chars of sessionID. Returns the branch name and any error.
//
// On error the caller should fall back to using the original cwd directly
// (if the session isn't running) or return fork_failed to the client.
func CreateForkWorktree(repoRoot, worktreePath, sessionID string) (branchName string, err error) {
	short := sessionID
	if len(short) > 8 {
		short = short[:8]
	}
	branchName = "conduit/fork-" + short
	// git worktree add -b <branch> <path> HEAD
	cmd := exec.Command("git", "-C", repoRoot, "worktree", "add", "-b", branchName, worktreePath, "HEAD")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git worktree add: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return branchName, nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// parseTimestamp parses an RFC3339 / ISO8601 timestamp string.
func parseTimestamp(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.999Z07:00", time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// truncate limits s to maxRunes runes, appending "…" when trimmed.
func truncate(s string, maxRunes int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	runes := []rune(s)
	return string(runes[:maxRunes-1]) + "…"
}
