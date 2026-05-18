package ws

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type fsListEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	IsDir bool   `json:"is_dir"`
}

type fsListResponse struct {
	Path    string        `json:"path"`
	Parent  string        `json:"parent"`
	Entries []fsListEntry `json:"entries"`
}

func (s *Server) serveFSList(w http.ResponseWriter, r *http.Request) {
	if !s.Auth.Check(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	target := normalizeFSPath(r.URL.Query().Get("path"))
	entries, err := os.ReadDir(target)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	resp := fsListResponse{
		Path:    target,
		Parent:  filepath.Dir(target),
		Entries: make([]fsListEntry, 0, len(entries)),
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		resp.Entries = append(resp.Entries, fsListEntry{
			Name:  name,
			Path:  filepath.Join(target, name),
			IsDir: true,
		})
	}
	sort.Slice(resp.Entries, func(i, j int) bool {
		return strings.ToLower(resp.Entries[i].Name) < strings.ToLower(resp.Entries[j].Name)
	})

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func normalizeFSPath(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "~" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return home
		}
		return "."
	}
	if strings.HasPrefix(trimmed, "~/") {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return filepath.Join(home, strings.TrimPrefix(trimmed, "~/"))
		}
	}
	return trimmed
}
