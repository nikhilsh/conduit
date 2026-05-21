package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func (m *Manager) sessionOnDisk(id string) bool {
	_, err := os.Stat(filepath.Join(m.kittyRoot, "sessions", id, "meta.json"))
	return err == nil
}

func (m *Manager) recoverSessionLocked(id string) (*Session, error) {
	metaPath := filepath.Join(m.kittyRoot, "sessions", id, "meta.json")
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
	adapter, err := m.registry.Get(meta.Assistant)
	if err != nil {
		return nil, err
	}
	scrollbackPath := filepath.Join(m.kittyRoot, "sessions", id, "scrollback.bin")
	snapshot, err := os.ReadFile(scrollbackPath)
	if err != nil {
		return nil, err
	}
	memoryPath := filepath.Join(m.kittyRoot, "memory", "sessions", id+".html")
	if _, err := os.Stat(memoryPath); err != nil {
		return nil, err
	}
	lastCheckpoint := time.Time{}
	if meta.LastCheckpoint != "" {
		lastCheckpoint, _ = time.Parse(time.RFC3339Nano, meta.LastCheckpoint)
	}
	s, err := newSession(id, adapter, sessionOptions{
		repoRoot:       m.repoRoot,
		kittyRoot:      m.kittyRoot,
		snapshot:       snapshot,
		lastCheckpoint: lastCheckpoint,
		termgrid:       m.termgrid,
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
	s.exitCode = meta.ExitCode
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
