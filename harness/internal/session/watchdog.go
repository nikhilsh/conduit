package session

import (
	"path/filepath"
	"syscall"
	"time"
)

type Status struct {
	Health         string
	Phase          string
	LastOutput     time.Time
	LastCheckpoint time.Time
}

func (s *Session) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{
		Health:         s.health,
		Phase:          s.phase,
		LastOutput:     s.lastOutput,
		LastCheckpoint: s.lastCheckpoint,
	}
}

func (s *Session) runWatchdogChecks() {
	if !s.processAlive() {
		s.setHealth("dead", "stalled")
		return
	}

	s.mu.Lock()
	lastOutput := s.lastOutput
	lastCheckpoint := s.lastCheckpoint
	s.mu.Unlock()

	if time.Since(lastOutput) > s.stallAfter {
		s.setHealth("warning", "stalled")
	} else if !lastCheckpoint.IsZero() && time.Since(lastCheckpoint) > s.checkpointEvery+(s.checkpointEvery/2) {
		s.setHealth("warning", "stalled")
	} else {
		s.setHealth("healthy", "running")
	}

	probe := filepath.Join(s.kittyRoot, "memory", ".probe-"+s.ID)
	if err := atomicWriteFile(probe, []byte(time.Now().UTC().Format(time.RFC3339Nano))); err != nil {
		s.setHealth("warning", "stalled")
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
	s.mu.Lock()
	changed := s.health != health || s.phase != phase
	s.health = health
	s.phase = phase
	s.mu.Unlock()
	if changed {
		_ = s.persistMetadata()
	}
}
