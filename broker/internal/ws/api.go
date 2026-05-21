package ws

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/nikhilsh/swe-kitty/broker/internal/session"
)

type apiErrorEnvelope struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, apiErrorEnvelope{
		Error: apiError{
			Code:    code,
			Message: message,
		},
	})
}

func (s *Server) requireAuth(w http.ResponseWriter, r *http.Request) bool {
	if s.Auth.Check(r) {
		return true
	}
	writeAPIError(w, http.StatusUnauthorized, "auth_expired", "unauthorized")
	return false
}

type capabilitiesResponse struct {
	Name       string   `json:"name"`
	Protocol   string   `json:"protocol"`
	Assistants []string `json:"assistants"`
	Endpoints  struct {
		Capabilities   bool `json:"capabilities"`
		FSList         bool `json:"fs_list"`
		SessionStart   bool `json:"session_start"`
		RecentProjects bool `json:"recent_projects"`
	} `json:"endpoints"`
	Features struct {
		WSCreateWithCWD   bool `json:"ws_create_with_cwd"`
		FSMetadata        bool `json:"fs_metadata"`
		FSPagination      bool `json:"fs_pagination"`
		SwitchAgent       bool `json:"switch_agent"`
		StructuredErrors  bool `json:"structured_errors"`
		TokenInQueryParam bool `json:"token_in_query_param"`
	} `json:"features"`
}

func (s *Server) serveCapabilities(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	resp := capabilitiesResponse{
		Name:       "swe-kitty-broker",
		Protocol:   "2026-05-18",
		Assistants: s.Sessions.AssistantNames(),
	}
	resp.Endpoints.Capabilities = true
	resp.Endpoints.FSList = true
	resp.Endpoints.SessionStart = true
	resp.Endpoints.RecentProjects = true
	resp.Features.WSCreateWithCWD = true
	resp.Features.FSMetadata = true
	resp.Features.FSPagination = true
	resp.Features.SwitchAgent = true
	resp.Features.StructuredErrors = true
	resp.Features.TokenInQueryParam = true
	writeJSON(w, http.StatusOK, resp)
}

type startSessionRequest struct {
	SessionID string `json:"session_id"`
	Assistant string `json:"assistant"`
	CWD       string `json:"cwd"`
}

type startSessionResponse struct {
	SessionID string `json:"session_id"`
	Assistant string `json:"assistant"`
	CWD       string `json:"cwd"`
	Created   bool   `json:"created"`
	WSPath    string `json:"ws_path"`
}

func (s *Server) serveSessionStart(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req startSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	id := strings.TrimSpace(req.SessionID)
	if id == "" {
		id = newSessionID()
	}
	assistant := strings.TrimSpace(req.Assistant)
	if assistant == "" {
		assistant = "claude"
	}
	cwd := strings.TrimSpace(req.CWD)
	if cwd != "" {
		if !filepath.IsAbs(cwd) {
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", "cwd must be an absolute path")
			return
		}
	}
	sess, created, err := s.Sessions.GetOrCreateWithOptions(id, assistant, session.CreateOptions{CWD: cwd})
	if err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "unknown assistant"):
			writeAPIError(w, http.StatusBadRequest, "assistant_unknown", msg)
		case strings.Contains(msg, "invalid cwd"):
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", msg)
		default:
			writeAPIError(w, http.StatusInternalServerError, "session_start_failed", msg)
		}
		return
	}
	resp := startSessionResponse{
		SessionID: sess.ID,
		Assistant: sess.Assistant,
		CWD:       cwd,
		Created:   created,
		WSPath:    fmt.Sprintf("/ws/%s?assistant=%s", sess.ID, sess.Assistant),
	}
	s.Sessions.RecordRecentProject(sess.WorkspaceDir(), sess.Assistant, sess.ID)
	writeJSON(w, http.StatusOK, resp)
}

type recentProjectsResponse struct {
	Projects []session.RecentProject `json:"projects"`
}

func (s *Server) serveRecentProjects(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	limit := 20
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 || n > 100 {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid limit (must be 1..100)")
			return
		}
		limit = n
	}
	writeJSON(w, http.StatusOK, recentProjectsResponse{
		Projects: s.Sessions.RecentProjects(limit),
	})
}

func newSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	// Set UUIDv4/version bits and render canonical form without extra deps.
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexed[0:8], hexed[8:12], hexed[12:16], hexed[16:20], hexed[20:32])
}
