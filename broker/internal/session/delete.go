package session

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// archivedSessionsDirName is the sibling directory (under kittyRoot) that
// holds session directories taken out of the active set by DeleteSession.
// It is deliberately NOT under `sessions/` so neither Recover() nor
// RunGC() — both of which scan only `sessions/` — ever re-list or prune
// an archived session. The conversation.jsonl + work/ tree is preserved
// here verbatim; only the *active* listing loses the session.
const archivedSessionsDirName = "archived-sessions"

// DeleteSession terminates a session app-side delete should actually
// kill: it stops the agent process + PTY, kills the per-session tmux
// session, drops the session from the live Manager map, and archives the
// on-disk session directory out of the active `sessions/` set into
// `archived-sessions/<id>` (preserving conversation.jsonl + work/).
//
// Idempotent: deleting an already-gone session (not in the map and not on
// disk) is a no-op that returns nil, so the HTTP handler can answer 200
// for repeat deletes / races with the watchdog reaper.
//
// The conversation transcript stays reachable: ConversationLog() falls
// back to the archived path, so GET /api/session/conversation/<id> keeps
// working after a delete.
func (m *Manager) DeleteSession(id string) error {
	if id == "" {
		return errors.New("delete: empty session id")
	}

	// 1. Stop the live session if present: Close() flushes a checkpoint,
	//    closes the PTY, kills the agent process, and tears down the
	//    termgrid sidecar + ephemeral $HOME. The Done()-watcher goroutine
	//    started in GetOrCreate / recover deletes it from m.sessions, but
	//    we also delete it under lock below so the active list is correct
	//    the instant DeleteSession returns (no reliance on the async
	//    reaper for the user-visible "it's gone" guarantee).
	m.mu.Lock()
	sess := m.sessions[id]
	delete(m.sessions, id)
	m.mu.Unlock()
	if sess != nil {
		sess.Close()
	}

	// 2. Kill the per-session tmux session that backs the Terminal-tab
	//    shell. Close() kills the broker's PTY child (the `bash -lc tmux
	//    attach` process), but tmux is a daemon: the detached session —
	//    and its shell — survives the attaching process exiting. Without
	//    an explicit kill-session the tmux session lingers indefinitely
	//    and a recreated session with the same id would re-attach to stale
	//    scrollback. Best-effort: tmux missing / session-already-gone both
	//    exit non-zero and are ignored.
	killTmuxSession(id)

	// 3. Archive the on-disk session directory out of the active set.
	//    Rename is atomic on the same filesystem and preserves
	//    conversation.jsonl + work/ verbatim. A missing source dir (never
	//    persisted, or already archived) is a no-op so the call stays
	//    idempotent.
	if err := m.archiveSessionDir(id); err != nil {
		return err
	}
	return nil
}

// killTmuxSession runs `tmux kill-session -t kitty-<id>` best-effort. tmux
// not being on PATH, or the session not existing, both return non-zero;
// we ignore that — the goal is "ensure it's gone", not "assert it was
// there".
func killTmuxSession(id string) {
	tmuxPath, err := exec.LookPath("tmux")
	if err != nil {
		return
	}
	cmd := exec.Command(tmuxPath, "kill-session", "-t", sanitizeTmuxName(id))
	_ = cmd.Run()
}

// archiveSessionDir moves `sessions/<id>` to `archived-sessions/<id>`.
// Returns nil when the active dir doesn't exist (idempotent). When an
// archive with the same id already exists (a prior delete), the new dir
// is parked under a timestamped suffix so we never clobber a preserved
// transcript and never fail the delete.
func (m *Manager) archiveSessionDir(id string) error {
	src := filepath.Join(m.kittyRoot, "sessions", id)
	info, err := os.Stat(src)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if !info.IsDir() {
		return nil
	}
	archiveRoot := filepath.Join(m.kittyRoot, archivedSessionsDirName)
	if err := os.MkdirAll(archiveRoot, 0o755); err != nil {
		return err
	}
	dst := filepath.Join(archiveRoot, id)
	if _, err := os.Stat(dst); err == nil {
		// An archive already exists for this id — keep both rather than
		// losing the older transcript. ConversationLog reads the canonical
		// `<id>` path, so the suffixed one is cold storage only.
		dst = fmt.Sprintf("%s.%d", dst, time.Now().UTC().UnixNano())
	}
	return os.Rename(src, dst)
}
