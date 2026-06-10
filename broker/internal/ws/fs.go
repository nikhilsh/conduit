package ws

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type fsListEntry struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	IsDir   bool   `json:"is_dir"`
	Hidden  bool   `json:"hidden"`
	ModTime string `json:"mod_time"`
}

type fsListResponse struct {
	Path       string        `json:"path"`
	Parent     string        `json:"parent"`
	Limit      int           `json:"limit"`
	Offset     int           `json:"offset"`
	Count      int           `json:"count"`
	Total      int           `json:"total"`
	HasMore    bool          `json:"has_more"`
	NextOffset int           `json:"next_offset"`
	Entries    []fsListEntry `json:"entries"`
}

func (s *Server) serveFSList(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	limit, offset, includeHidden, err := parseFSListQuery(r)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	target := normalizeFSPath(r.URL.Query().Get("path"))
	entries, err := os.ReadDir(target)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	collected := make([]fsListEntry, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		hidden := strings.HasPrefix(name, ".")
		if hidden && !includeHidden {
			continue
		}
		info, infoErr := entry.Info()
		modTime := ""
		if infoErr == nil {
			modTime = info.ModTime().UTC().Format(time.RFC3339Nano)
		}
		collected = append(collected, fsListEntry{
			Name:    name,
			Path:    filepath.Join(target, name),
			IsDir:   true,
			Hidden:  hidden,
			ModTime: modTime,
		})
	}
	sort.Slice(collected, func(i, j int) bool {
		return strings.ToLower(collected[i].Name) < strings.ToLower(collected[j].Name)
	})
	total := len(collected)
	start := min(offset, total)
	end := min(start+limit, total)
	paged := collected[start:end]

	resp := fsListResponse{
		Path:       target,
		Parent:     filepath.Dir(target),
		Limit:      limit,
		Offset:     offset,
		Count:      len(paged),
		Total:      total,
		HasMore:    end < total,
		NextOffset: end,
		Entries:    paged,
	}

	writeJSON(w, http.StatusOK, resp)
}

// fsHarnessStatusResponse reports whether a directory already carries the two
// agent-harness files the "Set up agent harness" chip keys off. The chip shows
// only when BOTH are absent (has_harness=false); see Part B of the harness
// bootstrap feature.
type fsHarnessStatusResponse struct {
	Path        string `json:"path"`
	HasClaudeMD bool   `json:"has_claude_md"`
	HasAgentsMD bool   `json:"has_agents_md"`
	// HasHarness is true when EITHER file exists — i.e. the project already
	// has some agent harness, so the chip should NOT nag. The app keys the
	// suggestion off !has_harness.
	HasHarness bool `json:"has_harness"`
}

// serveFSHarnessStatus reports the presence of CLAUDE.md / AGENTS.md at a path.
// fs/list intentionally returns directories only, so the app cannot detect
// these files from a listing — this is the lightweight file check Part B needs.
func (s *Server) serveFSHarnessStatus(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	target := normalizeFSPath(r.URL.Query().Get("path"))
	info, err := os.Stat(target)
	if err != nil || !info.IsDir() {
		writeAPIError(w, http.StatusBadRequest, "invalid_path", "path must be an existing directory")
		return
	}
	hasClaude := fileExists(filepath.Join(target, "CLAUDE.md"))
	hasAgents := fileExists(filepath.Join(target, "AGENTS.md"))
	writeJSON(w, http.StatusOK, fsHarnessStatusResponse{
		Path:        target,
		HasClaudeMD: hasClaude,
		HasAgentsMD: hasAgents,
		HasHarness:  hasClaude || hasAgents,
	})
}

// fileExists reports whether path names an existing regular (non-dir) file.
func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
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

func parseFSListQuery(r *http.Request) (limit int, offset int, includeHidden bool, err error) {
	q := r.URL.Query()
	limit = 100
	offset = 0
	includeHidden = false
	if raw := strings.TrimSpace(q.Get("limit")); raw != "" {
		parsed, parseErr := strconv.Atoi(raw)
		if parseErr != nil || parsed <= 0 || parsed > 500 {
			return 0, 0, false, fmt.Errorf("invalid limit %q (must be 1..500)", raw)
		}
		limit = parsed
	}
	if raw := strings.TrimSpace(q.Get("offset")); raw != "" {
		parsed, parseErr := strconv.Atoi(raw)
		if parseErr != nil || parsed < 0 {
			return 0, 0, false, fmt.Errorf("invalid offset %q (must be >= 0)", raw)
		}
		offset = parsed
	}
	if raw := strings.TrimSpace(q.Get("include_hidden")); raw != "" {
		includeHidden = raw == "1" || strings.EqualFold(raw, "true")
	}
	return limit, offset, includeHidden, nil
}
