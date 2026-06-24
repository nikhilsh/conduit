package session

import (
	"log"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Status struct {
	Health         string
	Phase          string
	ReasonCode     string
	ExitCode       int
	LastOutput     time.Time
	LastCheckpoint time.Time
	StartedAt      time.Time
}

func (s *Session) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{
		Health:         s.health,
		Phase:          s.phase,
		ReasonCode:     s.reasonCode,
		ExitCode:       s.exitCode,
		LastOutput:     s.lastOutput,
		LastCheckpoint: s.lastCheckpoint,
		StartedAt:      s.startedAt,
	}
}

func (s *Session) runWatchdogChecks() {
	if !s.processAlive() {
		s.setHealthWithReason("dead", "stalled", "process_exited")
		return
	}

	s.mu.Lock()
	lastOutput := s.lastOutput
	lastCheckpoint := s.lastCheckpoint
	s.mu.Unlock()

	// A quiet or checkpoint-lagging agent is still a LIVE process — keep the
	// phase "running" (the app reads ANY non-live phase as read-only and tears
	// down the chat composer, dropping the keyboard + the unsent draft) and
	// carry the concern in health/reasonCode so the UI can warn without
	// locking the user out. Only an actually-dead process (above) goes
	// non-live.
	if time.Since(lastOutput) > s.stallAfter {
		s.setHealthWithReason("warning", "running", "no_output")
	} else if !lastCheckpoint.IsZero() && time.Since(lastCheckpoint) > s.checkpointEvery+(s.checkpointEvery/2) {
		s.setHealthWithReason("warning", "running", "checkpoint_lagging")
	} else {
		s.setHealthWithReason("healthy", "running", "ok")
	}

	probe := filepath.Join(s.conduitRoot, "memory", ".probe-"+s.ID)
	if err := atomicWriteFile(probe, []byte(time.Now().UTC().Format(time.RFC3339Nano))); err != nil {
		s.setHealthWithReason("warning", "running", "probe_write_failed")
	}

	// Heal an expired private credential copy from the host login so the
	// per-call OAuth fetchers (account usage, quick replies, titles) and
	// the next agent spawn don't 401 (credfresh.go). Under
	// CONDUIT_SHARED_AGENT_CREDS there is NO per-session copy to heal — the
	// session points at one shared canonical lineage the CLI itself
	// refreshes — so the watchdog re-mirror is skipped entirely (doc §7).
	if !sharedAgentCredsEnabled() {
		s.refreshStaleAgentCredentials()
	}
}

func (s *Session) processAlive() bool {
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return false
	}
	return cmd.Process.Signal(syscall.Signal(0)) == nil
}

func (s *Session) setHealth(health, phase string) {
	s.setHealthWithReason(health, phase, s.reasonCode)
}

func (s *Session) setHealthWithReason(health, phase, reason string) {
	s.mu.Lock()
	prevPhase := s.phase
	changed := s.health != health || s.phase != phase || s.reasonCode != reason
	s.health = health
	s.phase = phase
	s.reasonCode = reason
	s.mu.Unlock()
	if !changed {
		return
	}
	_ = s.persistMetadata()
	if prevPhase != phase {
		log.Printf("session %s: phase %s -> %s (health=%s reason=%s)", s.ID, prevPhase, phase, health, reason)
	}
	// Push the new health/phase to every subscribed client. Without this a
	// watchdog transition — most importantly the flip BACK to "running" once a
	// quiet or recovered agent resumes — only reached the app on its NEXT
	// reconnect, so a session that briefly went non-live stayed read-only
	// ("keeps going to starting and never back to running"). The connect path
	// still sends the first frame; this covers changes while a client is
	// subscribed. Must run AFTER releasing s.mu: broadcastStatus re-acquires
	// it via StatusPayload + PublishText.
	s.broadcastStatus()
}

// isLivePhase mirrors the apps' classifier (SessionStore.isLivePhase): a phase
// names an actively-running agent. Anything not affirmatively running (empty,
// exited/failed/dead, or the process-died "stalled") is NOT live, so the app
// opens the session read-only. Keep in sync with apps/ios + apps/android.
func isLivePhase(phase string) bool {
	switch strings.ToLower(strings.TrimSpace(phase)) {
	case "running", "ready", "idle", "thinking", "working", "starting", "booting", "swapping":
		return true
	default:
		return false
	}
}
