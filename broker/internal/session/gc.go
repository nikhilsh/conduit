package session

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// RunGC prunes session directories under `<kittyRoot>/sessions/` and
// their paired `<kittyRoot>/memory/sessions/<id>.html` snapshots when
// they haven't been touched in `maxAge`. Live sessions (anything in
// `m.sessions`) are always preserved.
//
// Eligibility is decided by the more recent of `meta.json`'s mtime and
// the session directory's mtime — `atomicWriteFile` renames into place
// on every Checkpoint(), so a session that's actively checkpointing
// shows fresh mtime even if it's been recovered+abandoned mid-flight.
//
// Returns the IDs that were pruned. A non-nil error means at least one
// directory could not be removed; pruning continues for the rest.
// `maxAge <= 0` is a no-op (the on-by-default-disabled escape hatch).
func (m *Manager) RunGC(maxAge time.Duration, now time.Time) ([]string, error) {
	if maxAge <= 0 {
		return nil, nil
	}
	cutoff := now.Add(-maxAge)
	root := filepath.Join(m.kittyRoot, "sessions")
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	m.mu.RLock()
	live := make(map[string]struct{}, len(m.sessions))
	for id := range m.sessions {
		live[id] = struct{}{}
	}
	m.mu.RUnlock()

	pruned := make([]string, 0, len(entries))
	var firstErr error
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		if _, alive := live[id]; alive {
			continue
		}
		sessionDir := filepath.Join(root, id)
		mtime := mostRecentTouch(sessionDir)
		if mtime.IsZero() || mtime.After(cutoff) {
			continue
		}
		if err := os.RemoveAll(sessionDir); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		memoryFile := filepath.Join(m.kittyRoot, "memory", "sessions", id+".html")
		if err := os.Remove(memoryFile); err != nil && !errors.Is(err, os.ErrNotExist) {
			if firstErr == nil {
				firstErr = err
			}
			// Don't undo the prune — the orphan HTML is harmless.
		}
		pruned = append(pruned, id)
	}
	return pruned, firstErr
}

// mostRecentTouch returns the later of meta.json's mtime and the
// session dir's own mtime. Zero time means we couldn't stat the dir
// at all (treat as "don't touch").
func mostRecentTouch(sessionDir string) time.Time {
	dirInfo, err := os.Stat(sessionDir)
	if err != nil {
		return time.Time{}
	}
	mtime := dirInfo.ModTime()
	if metaInfo, err := os.Stat(filepath.Join(sessionDir, "meta.json")); err == nil {
		if metaInfo.ModTime().After(mtime) {
			mtime = metaInfo.ModTime()
		}
	}
	return mtime
}

// startGCLoop runs an initial GC pass and then keeps pruning every
// `interval`. Reads tuning from the environment once at startup:
//   - KITTY_SESSION_GC_AGE_DAYS    (default 7,  set 0 to disable)
//   - KITTY_SESSION_GC_INTERVAL_HOURS (default 24)
//
// Diagnostic output goes to stderr so it shows up in journalctl.
func (m *Manager) startGCLoop(stop <-chan struct{}) {
	ageDays := envIntDefault("KITTY_SESSION_GC_AGE_DAYS", 7)
	if ageDays <= 0 {
		return
	}
	intervalHours := envIntDefault("KITTY_SESSION_GC_INTERVAL_HOURS", 24)
	if intervalHours <= 0 {
		intervalHours = 24
	}
	maxAge := time.Duration(ageDays) * 24 * time.Hour
	interval := time.Duration(intervalHours) * time.Hour

	go func() {
		// Run once at boot, then on the interval. A short initial
		// delay lets Recover() repopulate `m.sessions` so we don't
		// race against a session that's about to be re-attached.
		select {
		case <-time.After(30 * time.Second):
		case <-stop:
			return
		}
		m.runGCAndLog(maxAge)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				m.runGCAndLog(maxAge)
			case <-stop:
				return
			}
		}
	}()
}

func (m *Manager) runGCAndLog(maxAge time.Duration) {
	pruned, err := m.RunGC(maxAge, time.Now().UTC())
	if err != nil {
		fmt.Fprintf(os.Stderr, "session GC: %v\n", err)
	}
	if len(pruned) > 0 {
		fmt.Fprintf(os.Stderr, "session GC: pruned %d session(s) older than %s: %s\n",
			len(pruned), maxAge, strings.Join(pruned, ", "))
	}
}

func envIntDefault(name string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return n
}
