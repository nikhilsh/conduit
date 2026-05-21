package session

import (
	"path/filepath"
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

	if time.Since(lastOutput) > s.stallAfter {
		s.setHealthWithReason("warning", "stalled", "no_output")
	} else if !lastCheckpoint.IsZero() && time.Since(lastCheckpoint) > s.checkpointEvery+(s.checkpointEvery/2) {
		s.setHealthWithReason("warning", "stalled", "checkpoint_lagging")
	} else {
		s.setHealthWithReason("healthy", "running", "ok")
	}

	probe := filepath.Join(s.kittyRoot, "memory", ".probe-"+s.ID)
	if err := atomicWriteFile(probe, []byte(time.Now().UTC().Format(time.RFC3339Nano))); err != nil {
		s.setHealthWithReason("warning", "stalled", "probe_write_failed")
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
	changed := s.health != health || s.phase != phase || s.reasonCode != reason
	s.health = health
	s.phase = phase
	s.reasonCode = reason
	s.mu.Unlock()
	if changed {
		_ = s.persistMetadata()
	}
}
