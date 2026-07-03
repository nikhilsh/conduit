package ws

// pipeline.go — HTTP handlers for the Sequential Agent Pipeline endpoints.
//
// Routes (registered in server.go):
//
//	POST   /api/pipeline               create + start (runs step 0 immediately)
//	GET    /api/pipeline/{id}          full pipeline.json (poll for live state)
//	POST   /api/pipeline/{id}/continue advance past AWAITING_GATE; 409 if not at gate
//	DELETE /api/pipeline/{id}          cancel; kills live child; state → CANCELLED
//	GET    /api/pipelines              list: [{id, title, state, current_step, step_count}]

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/pipeline"
	"github.com/nikhilsh/conduit/broker/internal/push"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// pipelineSessionManager adapts *session.Manager to pipeline.SessionManager.
type pipelineSessionManager struct {
	m *session.Manager
}

func (p *pipelineSessionManager) CreateSession(agentType, cwd, initialPrompt, branch string) (string, error) {
	id := newSessionID()
	opts := session.CreateOptions{CWD: cwd, Branch: branch}
	sess, _, err := p.m.GetOrCreateWithOptions(id, agentType, opts)
	if err != nil {
		return "", err
	}
	// Deliver the initial prompt to the session via SendChat.
	// SendChat returns false on the legacy TUI-scrape path; in that case
	// write it to the PTY directly.
	if initialPrompt != "" {
		if !sess.SendChat(initialPrompt) {
			sess.MarkUserChatSent(initialPrompt)
			_, _ = sess.Write([]byte(initialPrompt + "\r"))
		}
	}
	return sess.ID, nil
}

func (p *pipelineSessionManager) GetPhase(sessionID string) string {
	sess, ok := p.m.Get(sessionID)
	if !ok {
		// Session not in memory — try the on-disk metadata via ConversationLog
		// to determine if it exited. For simplicity, return "" (unknown).
		return ""
	}
	st := sess.Status()
	return st.Phase
}

func (p *pipelineSessionManager) GetWorktreeDir(sessionID string) string {
	sess, ok := p.m.Get(sessionID)
	if !ok {
		return ""
	}
	return sess.WorkspaceDir()
}

func (p *pipelineSessionManager) GetLastAssistantText(sessionID string) string {
	entries, err := p.m.ConversationLog(sessionID)
	if err != nil || len(entries) == 0 {
		return ""
	}
	// Walk in reverse order to find the last assistant turn.
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].Role == "assistant" {
			return entries[i].Content
		}
	}
	return ""
}

func (p *pipelineSessionManager) CancelSession(sessionID string) error {
	sess, ok := p.m.Get(sessionID)
	if !ok {
		return nil // already gone
	}
	sess.Close()
	return nil
}

// pipelinePushNotifier adapts *push.Dispatcher to pipeline.PushNotifier.
type pipelinePushNotifier struct {
	d        *push.Dispatcher
	identity string
}

func (n *pipelinePushNotifier) Notify(ctx context.Context, title, body string) error {
	return n.d.Notify(ctx, n.identity, push.Payload{Title: title, Body: body})
}

// pipelineOrchestrator returns the Orchestrator for the given server.
// The notifier is nil-safe — when no Dispatcher is wired, push is silently skipped.
func (s *Server) pipelineOrchestrator() *pipeline.Orchestrator {
	var notifier pipeline.PushNotifier
	if s.Dispatcher != nil {
		notifier = &pipelinePushNotifier{d: s.Dispatcher, identity: pushIdentity}
	}
	sm := &pipelineSessionManager{m: s.Sessions}
	return pipeline.NewOrchestrator(s.Sessions.ConduitRoot(), sm, notifier)
}

// ── POST /api/pipeline ──────────────────────────────────────────────────────

type createPipelineStepRequest struct {
	AgentType      string                 `json:"agent_type"`
	Role           string                 `json:"role"`
	PromptTemplate string                 `json:"prompt_template"`
	InputFromPrev  pipeline.InputFromPrev `json:"input_from_prev"`
	GateAfter      bool                   `json:"gate_after"`
}

type createPipelineRequest struct {
	Title string                      `json:"title"`
	CWD   string                      `json:"cwd"`
	Base  string                      `json:"base"`
	Task  string                      `json:"task"`
	Steps []createPipelineStepRequest `json:"steps"`
}

func (s *Server) serveCreatePipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req createPipelineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Title = strings.TrimSpace(req.Title)
	req.Task = strings.TrimSpace(req.Task)
	req.CWD = strings.TrimSpace(req.CWD)
	if req.Title == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "title is required")
		return
	}
	if req.Task == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "task is required")
		return
	}
	if len(req.Steps) == 0 {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "at least one step is required")
		return
	}

	p := &pipeline.Pipeline{
		ID:      pipeline.NewID(),
		Title:   req.Title,
		Task:    req.Task,
		CWD:     req.CWD,
		Base:    strings.TrimSpace(req.Base),
		State:   pipeline.PipelinePending,
		Created: time.Now().UTC().Format(time.RFC3339),
		Steps:   make([]pipeline.Step, len(req.Steps)),
	}
	for i, rs := range req.Steps {
		p.Steps[i] = pipeline.Step{
			Index:          i,
			AgentType:      strings.TrimSpace(rs.AgentType),
			Role:           strings.TrimSpace(rs.Role),
			PromptTemplate: rs.PromptTemplate,
			InputFromPrev:  rs.InputFromPrev,
			GateAfter:      rs.GateAfter,
		}
		if p.Steps[i].AgentType == "" {
			p.Steps[i].AgentType = "claude"
		}
	}

	log.Printf("pipeline: creating %s title=%q steps=%d", p.ID, p.Title, len(p.Steps))

	orch := s.pipelineOrchestrator()
	if err := orch.Start(p); err != nil {
		log.Printf("pipeline: start %s: %v", p.ID, err)
		writeAPIError(w, http.StatusInternalServerError, "pipeline_start_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"id":           p.ID,
		"state":        p.State,
		"current_step": p.CurrentStep,
	})
}

// ── GET /api/pipeline/{id} ──────────────────────────────────────────────────

func (s *Server) serveGetPipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/pipeline/")
	// Strip any trailing path components (e.g. "/continue") — the router
	// dispatches exact paths, so this should be the bare id.
	if idx := strings.Index(id, "/"); idx != -1 {
		id = id[:idx]
	}
	id = strings.TrimSpace(id)
	if id == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing pipeline id")
		return
	}
	p, err := pipeline.Load(s.Sessions.ConduitRoot(), id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "pipeline not found: "+id)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// ── POST /api/pipeline/{id}/continue ────────────────────────────────────────

// continueBody is the optional request body for POST /api/pipeline/{id}/continue.
// Old clients send no body; new clients may send {"prev": "amended text"}.
// Missing body, empty body, or any parse error all produce "" (never an error).
type continueBody struct {
	Prev string `json:"prev"`
}

func (s *Server) serveContinuePipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	// Path: /api/pipeline/{id}/continue
	tail := strings.TrimPrefix(r.URL.Path, "/api/pipeline/")
	id := strings.TrimSuffix(tail, "/continue")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid pipeline id")
		return
	}

	// Parse optional body for the amended prev. Never an error if absent or malformed.
	var amendedPrev string
	if r.Body != nil && r.ContentLength != 0 {
		var body continueBody
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			amendedPrev = body.Prev
		}
		// parse failure → amendedPrev stays ""
	}

	p, err := pipeline.Load(s.Sessions.ConduitRoot(), id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "pipeline not found: "+id)
		return
	}
	log.Printf("pipeline: continue %s (state=%s, amended_prev=%v)", id, p.State, amendedPrev != "")
	orch := s.pipelineOrchestrator()
	if err := orch.Continue(p, amendedPrev); err != nil {
		if errors.Is(err, pipeline.ErrNotAtGate) {
			writeAPIError(w, http.StatusConflict, "not_at_gate", "pipeline is not awaiting a gate")
			return
		}
		log.Printf("pipeline: continue %s: %v", id, err)
		writeAPIError(w, http.StatusInternalServerError, "pipeline_continue_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":           p.ID,
		"state":        p.State,
		"current_step": p.CurrentStep,
	})
}

// ── DELETE /api/pipeline/{id} ───────────────────────────────────────────────

func (s *Server) serveDeletePipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodDelete {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "DELETE required")
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/pipeline/"))
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid pipeline id")
		return
	}
	p, err := pipeline.Load(s.Sessions.ConduitRoot(), id)
	if err != nil {
		// Idempotent: already gone is a 200.
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "cancelled": true})
		return
	}
	log.Printf("pipeline: delete %s (state=%s)", id, p.State)
	orch := s.pipelineOrchestrator()
	if err := orch.Cancel(p); err != nil {
		log.Printf("pipeline: cancel %s: %v", id, err)
		writeAPIError(w, http.StatusInternalServerError, "pipeline_cancel_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "cancelled": true})
}

// ── GET /api/pipelines ───────────────────────────────────────────────────────

type pipelineListItem struct {
	ID          string                 `json:"id"`
	Title       string                 `json:"title"`
	State       pipeline.PipelineState `json:"state"`
	CurrentStep int                    `json:"current_step"`
	StepCount   int                    `json:"step_count"`
	Created     string                 `json:"created,omitempty"`
}

func (s *Server) serveListPipelines(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	pipelines, err := pipeline.List(s.Sessions.ConduitRoot())
	if err != nil {
		log.Printf("pipeline: list: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "list_failed", err.Error())
		return
	}
	items := make([]pipelineListItem, 0, len(pipelines))
	for _, p := range pipelines {
		items = append(items, pipelineListItem{
			ID:          p.ID,
			Title:       p.Title,
			State:       p.State,
			CurrentStep: p.CurrentStep,
			StepCount:   len(p.Steps),
			Created:     p.Created,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"pipelines": items})
}

// ── Router dispatch ──────────────────────────────────────────────────────────

// servePipelineRouter dispatches /api/pipeline/* and /api/pipelines.
// Routes:
//
//	GET  /api/pipelines              → serveListPipelines
//	POST /api/pipeline               → serveCreatePipeline
//	GET  /api/pipeline/{id}          → serveGetPipeline
//	POST /api/pipeline/{id}/continue → serveContinuePipeline
//	DELETE /api/pipeline/{id}        → serveDeletePipeline
func (s *Server) servePipelineRouter(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/api/pipelines":
		s.serveListPipelines(w, r)
	case path == "/api/pipeline":
		s.serveCreatePipeline(w, r)
	case strings.HasSuffix(path, "/continue"):
		s.serveContinuePipeline(w, r)
	case r.Method == http.MethodDelete:
		s.serveDeletePipeline(w, r)
	case r.Method == http.MethodGet:
		s.serveGetPipeline(w, r)
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "unsupported method for this pipeline endpoint")
	}
}
