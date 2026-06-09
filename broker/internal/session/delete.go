package session

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// archivedSessionsDirName is the sibling directory (under conduitRoot) that
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
	workspaceDir := ""
	if sess != nil {
		// Capture the workspace before Close() so we can drop the WIP
		// checkpoint ref below; a cold (never-live) delete falls back to the
		// persisted workspace_dir.
		workspaceDir = sess.WorkspaceDir()
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

	// 2.5 Drop the per-session WIP checkpoint ref (maybeAutoWIP) so snapshot
	//     refs don't outlive their sessions and accumulate. Best-effort; falls
	//     back to the persisted workspace_dir for a cold delete.
	if workspaceDir == "" {
		if meta, err := m.readSessionMeta(id); err == nil {
			workspaceDir = meta.WorkspaceDir
		}
	}
	deleteWIPCheckpointRef(workspaceDir, id)

	// 2.6 Tear down the per-session git worktree (if this session ran in one)
	//     BEFORE archiving — otherwise the rename orphans the worktree
	//     registration in the parent repo. Existence-gated, so a no-op for
	//     sessions that ran in the shared checkout.
	removeSessionWorktree(filepath.Join(m.conduitRoot, "sessions", id, "worktree"))

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

// deleteWIPCheckpointRef removes the session's WIP snapshot ref (written by
// maybeAutoWIP) from its workspace repo. Best-effort: no workspace, not a git
// repo, or no such ref all just no-op so a delete never fails on this.
func deleteWIPCheckpointRef(workspaceDir, id string) {
	if workspaceDir == "" {
		return
	}
	if _, err := os.Stat(filepath.Join(workspaceDir, ".git")); err != nil {
		return
	}
	_ = exec.Command("git", "-C", workspaceDir,
		"update-ref", "-d", wipCheckpointRefPrefix+id).Run()
}

// killTmuxSession runs `tmux kill-session` for a session's Terminal-tab
// backing tmux session, best-effort. tmux not being on PATH, or the
// session not existing, both return non-zero; we ignore that — the goal
// is "ensure it's gone", not "assert it was there". We kill both the
// current (`conduit-<id>`) and legacy (`kitty-<id>`) names so a delete of
// a session that predates the rebrand still tears its terminal down.
func killTmuxSession(id string) {
	tmuxPath, err := exec.LookPath("tmux")
	if err != nil {
		return
	}
	for _, name := range []string{sanitizeTmuxName(id), legacyTmuxName(id)} {
		_ = exec.Command(tmuxPath, "kill-session", "-t", name).Run()
	}
}

// ReapOrphanTmuxSessions tears down per-session Terminal-tab tmux sessions
// that no longer back a live or recoverable Conduit session. The terminal
// is a DETACHED tmux session (terminalShellArgv) deliberately kept alive
// across a client disconnect so a reconnect re-attaches with its
// scrollback intact — but nothing reaps it once the owning session is
// archived (DeleteSession handles that), GC-pruned, or lost to a broker
// crash, so they accumulate on the tmux server across broker lifetimes.
//
// Run once at startup (after Recover). For each tmux session in the
// broker's namespace we kill it when EITHER it carries the legacy
// pre-rebrand prefix (the new code attaches under `conduit-<id>` and will
// never re-attach to a `kitty-<id>` name, so it is dead weight) OR its id
// has no session directory on disk (archived / pruned / never persisted).
// ATTACHED sessions are never touched — an attached session means a client
// is viewing it right now. Best-effort throughout: tmux missing, no server
// running, or any individual kill failing is ignored.
//
// IMPORTANT: this enumerates the *global* tmux server, so it must only run
// from the real broker entrypoint, never from a unit test — a test's
// Manager has a throwaway conduitRoot and would see every real user
// session as an orphan and kill it. Tests disable Terminal-tab tmux
// backing entirely (CONDUIT_DISABLE_TERMINAL_TMUX), so they neither create
// nor reap these sessions.
func (m *Manager) ReapOrphanTmuxSessions() {
	tmuxPath, err := exec.LookPath("tmux")
	if err != nil {
		return
	}
	out, err := exec.Command(tmuxPath, "list-sessions",
		"-F", "#{session_name}\t#{session_attached}").Output()
	if err != nil {
		return // no server / no sessions / tmux error — nothing to reap
	}
	reaped := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		name, attached, ok := strings.Cut(line, "\t")
		if !ok {
			continue
		}
		id, legacy, ours := tmuxSessionID(name)
		if !ours || id == "" {
			continue // a tmux session the user started by hand
		}
		if attached != "0" {
			continue // someone is viewing it right now; leave it alone
		}
		if !legacy && m.sessionOnDisk(id) {
			continue // still live/recoverable under the current prefix
		}
		if exec.Command(tmuxPath, "kill-session", "-t", name).Run() == nil {
			reaped++
		}
	}
	if reaped > 0 {
		fmt.Fprintf(os.Stderr, "session: reaped %d orphan Terminal-tab tmux session(s)\n", reaped)
	}
}

// archiveSessionDir moves `sessions/<id>` to `archived-sessions/<id>`.
// Returns nil when the active dir doesn't exist (idempotent). When an
// archive with the same id already exists (a prior delete), the new dir
// is parked under a timestamped suffix so we never clobber a preserved
// transcript and never fail the delete.
func (m *Manager) archiveSessionDir(id string) error {
	src := filepath.Join(m.conduitRoot, "sessions", id)
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
	archiveRoot := filepath.Join(m.conduitRoot, archivedSessionsDirName)
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
