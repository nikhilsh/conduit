package session

import (
	"errors"
	"time"
)

// Bounded restart budget for crash-looping sessions.
//
// A session whose agent dies right after spawn (revoked credentials,
// deleted workspace, broken adapter binary) used to resurrect forever:
// every client reconnect hits GetOrCreateWithOptions, which recovers
// the on-disk session and spawns a fresh agent, which dies again — an
// infinite zombie the user can never get rid of short of deleting it.
// Instead we count consecutive fast exits in meta.json and, once the
// budget is spent, refuse recovery and archive the session out of the
// active set — the app sees a session that has genuinely ended.

const (
	// fastExitWindow: an agent that dies sooner than this after spawn
	// counts as a failed start rather than a real run. A real run that
	// outlives the window resets the budget.
	fastExitWindow = 60 * time.Second
	// maxConsecutiveFastExits: failed starts in a row before the
	// session gives up and is archived.
	maxConsecutiveFastExits = 3
)

// errSessionGaveUp marks a recovery refused because the restart budget
// is spent. GetOrCreateWithOptions turns it into archive-and-refuse;
// the ws/api layer maps it to a "session_gave_up" error.
var errSessionGaveUp = errors.New("session gave up after repeated agent failures")

// recordAgentExit updates the consecutive-fast-exit budget when the
// agent's PTY drains to EOF. Called by drain() right before Close(), so
// the new count lands in the meta.json that Close persists. Intentional
// teardown (delete / broker shutdown / adapter swap) must not count:
// Close() sets s.closing before killing the PTY, and drain's EOF wakeup
// then sees it here and leaves the budget untouched.
func (s *Session) recordAgentExit() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return
	}
	if time.Since(s.spawnedAt) < fastExitWindow {
		s.consecutiveFastExits++
	} else {
		s.consecutiveFastExits = 0
	}
}
