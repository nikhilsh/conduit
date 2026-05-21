package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type RecentProject struct {
	Path      string    `json:"path"`
	Assistant string    `json:"assistant"`
	SessionID string    `json:"session_id"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (m *Manager) RecentProjects(limit int) []RecentProject {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := append([]RecentProject{}, m.recentProjects...)
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func (m *Manager) RecordRecentProject(path, assistant, sessionID string) {
	path = strings.TrimSpace(path)
	if path == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.recordRecentProjectLocked(path, assistant, sessionID)
}

func (m *Manager) recordRecentProjectLocked(path, assistant, sessionID string) {
	path = strings.TrimSpace(path)
	if path == "" {
		return
	}
	now := time.Now().UTC()
	next := make([]RecentProject, 0, len(m.recentProjects)+1)
	next = append(next, RecentProject{
		Path:      path,
		Assistant: strings.TrimSpace(assistant),
		SessionID: strings.TrimSpace(sessionID),
		UpdatedAt: now,
	})
	for _, p := range m.recentProjects {
		if p.Path == path {
			continue
		}
		next = append(next, p)
		if len(next) >= 50 {
			break
		}
	}
	m.recentProjects = next
	_ = m.persistRecentProjectsLocked()
}

func (m *Manager) recentProjectsPath() string {
	return filepath.Join(m.kittyRoot, "recent-projects.json")
}

func (m *Manager) loadRecentProjects() {
	data, err := os.ReadFile(m.recentProjectsPath())
	if err != nil {
		return
	}
	var decoded []RecentProject
	if err := json.Unmarshal(data, &decoded); err != nil {
		return
	}
	filtered := make([]RecentProject, 0, len(decoded))
	for _, p := range decoded {
		if strings.TrimSpace(p.Path) == "" {
			continue
		}
		filtered = append(filtered, p)
	}
	slices.SortFunc(filtered, func(a, b RecentProject) int {
		if a.UpdatedAt.Equal(b.UpdatedAt) {
			return 0
		}
		if a.UpdatedAt.After(b.UpdatedAt) {
			return -1
		}
		return 1
	})
	if len(filtered) > 50 {
		filtered = filtered[:50]
	}
	m.recentProjects = filtered
}

func (m *Manager) persistRecentProjectsLocked() error {
	data, err := json.MarshalIndent(m.recentProjects, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(m.recentProjectsPath(), append(data, '\n'))
}
