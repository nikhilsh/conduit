package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// RecoverableSessions enumerates on-disk sessions that are NOT currently
// live in memory but WOULD recover cleanly the next time a client opens
// them — the "dead now, resumable" set the app previously had no word for.
//
// It is the read-only, non-spawning sibling of recoverSessionLocked: it
// runs the same recovery preconditions WITHOUT starting an agent process,
// so listing never resurrects anything (preserving the lazy-recovery boot
// guarantee that kept the host from a process storm). Sessions that would
// FAIL recovery — missing scrollback, missing memory snapshot, exhausted
// restart budget, unknown adapter — are omitted, so every advertised row
// is one the broker can genuinely bring back. The app consumes this to
// offer Resume; the conservative "fail closed to read-only" path then only
// catches sessions that truly cannot come back.
func (m *Manager) RecoverableSessions() []LiveSessionInfo {
	entries, err := os.ReadDir(filepath.Join(m.conduitRoot, "sessions"))
	if err != nil {
		return nil
	}
	// Snapshot the live set under lock, then do the (potentially dozens of)
	// disk reads unlocked — never hold m.mu across per-session file I/O.
	m.mu.RLock()
	liveIDs := make(map[string]struct{}, len(m.sessions))
	for id := range m.sessions {
		liveIDs[id] = struct{}{}
	}
	m.mu.RUnlock()

	out := make([]LiveSessionInfo, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		if _, ok := liveIDs[id]; ok {
			continue // already surfaced by LiveSessions()
		}
		meta, err := m.readSessionMeta(id)
		if err != nil {
			continue
		}
		if m.recoverabilityError(id, meta) != nil {
			continue
		}
		out = append(out, LiveSessionInfo{
			ID:             id,
			Assistant:      meta.Assistant,
			Phase:          meta.Phase,
			Health:         meta.Health,
			Running:        false,
			Recoverable:    true,
			Rows:           meta.Rows,
			Cols:           meta.Cols,
			Title:          meta.AITitle,
			CWD:            meta.WorkspaceDir,
			StartedAt:      meta.StartedAt,
			LastActivityAt: meta.LastActivityAt,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// readSessionMeta loads and decodes sessions/<id>/meta.json.
func (m *Manager) readSessionMeta(id string) (sessionMetadata, error) {
	var meta sessionMetadata
	data, err := os.ReadFile(filepath.Join(m.conduitRoot, "sessions", id, "meta.json"))
	if err != nil {
		return meta, err
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return meta, err
	}
	return meta, nil
}

// recoverabilityError reports why session id would FAIL recoverSessionLocked,
// or nil if it would recover. It MUST stay in lockstep with the preconditions
// in recoverSessionLocked (recovery.go) — every check there that can reject a
// session before its agent is spawned is mirrored here so RecoverableSessions
// never advertises a row that recovery would then refuse:
//
//   - assistant metadata present and a known adapter,
//   - restart budget not exhausted (maxConsecutiveFastExits),
//   - scrollback snapshot present,
//   - memory snapshot present.
func (m *Manager) recoverabilityError(id string, meta sessionMetadata) error {
	if meta.Assistant == "" {
		return fmt.Errorf("session %s missing assistant metadata", id)
	}
	if meta.ConsecutiveFastExits >= maxConsecutiveFastExits {
		return fmt.Errorf("session %s: restart budget exhausted (%d fast exits within %s)",
			id, meta.ConsecutiveFastExits, fastExitWindow)
	}
	if _, err := m.registry.Get(meta.Assistant); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(m.conduitRoot, "sessions", id, "scrollback.bin")); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(m.conduitRoot, "memory", "sessions", id+".html")); err != nil {
		return err
	}
	return nil
}
