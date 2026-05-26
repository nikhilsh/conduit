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
	// ReasoningEffort / Model are optional per-session overrides for the
	// fork-onto-a-different-model path. Empty = adapter defaults. Honored
	// only on create; an existing session keeps the effort/model it was
	// spawned with.
	ReasoningEffort string `json:"reasoning_effort"`
	Model           string `json:"model"`
}

type startSessionResponse struct {
	SessionID       string `json:"session_id"`
	Assistant       string `json:"assistant"`
	CWD             string `json:"cwd"`
	ReasoningEffort string `json:"reasoning_effort,omitempty"`
	Model           string `json:"model,omitempty"`
	Created         bool   `json:"created"`
	WSPath          string `json:"ws_path"`
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
	override := session.SpawnOverride{
		ReasoningEffort: strings.TrimSpace(req.ReasoningEffort),
		Model:           strings.TrimSpace(req.Model),
	}
	sess, created, err := s.Sessions.GetOrCreateWithOptions(id, assistant, session.CreateOptions{CWD: cwd, Override: override})
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
		SessionID:       sess.ID,
		Assistant:       sess.Assistant,
		CWD:             cwd,
		ReasoningEffort: sess.ReasoningEffort(),
		Model:           override.Model,
		Created:         created,
		WSPath:          fmt.Sprintf("/ws/%s?assistant=%s", sess.ID, sess.Assistant),
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

// sessionConversationResponse is the body of GET
// /api/session/conversation/<id>. `items` is the persisted transcript in
// chronological order — the same `{role, content, ts, files}` shape the
// clients already render for live chat.
type sessionConversationResponse struct {
	Items []session.ConvEntry `json:"items"`
}

// serveSessionConversation returns a session's persisted conversation
// transcript by id. Works for live AND exited sessions (the broker
// appends both sides to a per-session conversation.jsonl that survives
// reap), so the app can reopen a past session read-only.
func (s *Server) serveSessionConversation(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/session/conversation/"))
	if id == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing session id")
		return
	}
	items, err := s.Sessions.ConversationLog(id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "no conversation for session")
		return
	}
	writeJSON(w, http.StatusOK, sessionConversationResponse{Items: items})
}

// serveSessionDelete terminates and archives a session by id. It is the
// server side of the app's swipe-to-delete: it stops the agent process +
// PTY, kills the per-session tmux session, drops the session from the
// live Manager map, and archives the on-disk session dir out of the
// active set (conversation.jsonl + work/ are preserved under
// `archived-sessions/<id>`, reachable via GET
// /api/session/conversation/<id>).
//
// Idempotent: deleting an already-gone session returns 200. Only DELETE
// is accepted; the WS `exit` control still merely kills the process and
// leaves the session recoverable, which is why the broker accumulated
// stale sessions — this is the endpoint that actually removes them.
func (s *Server) serveSessionDelete(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodDelete {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "DELETE required")
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/session/"))
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid session id")
		return
	}
	if err := s.Sessions.DeleteSession(id); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "session_delete_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": id,
		"deleted":    true,
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
