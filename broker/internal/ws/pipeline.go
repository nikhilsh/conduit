package ws

// pipeline.go — HTTP handlers for the Sequential Agent Pipeline endpoints.
//
// Routes (registered in server.go):
//
//	POST   /api/pipeline               create + start (runs step 0 immediately)
//	GET    /api/pipeline/{id}          full pipeline.json (poll for live state)
//	POST   /api/pipeline/{id}/continue advance past AWAITING_GATE; 409 if not at gate
//	POST   /api/pipeline/{id}/resume   re-spawn failed step; 409 if not failed
//	POST   /api/pipeline/{id}/pick     pick fanout winner; 409 if not awaiting_pick
//	DELETE /api/pipeline/{id}          cancel; kills live child; state → CANCELLED
//	GET    /api/pipelines              list: [{id, title, state, current_step, step_count, steps, result}]
//
//	GET    /api/pipeline-templates        list all templates
//	POST   /api/pipeline-templates        create a template
//	DELETE /api/pipeline-templates/{id}   delete a template

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

func (p *pipelineSessionManager) CreateSession(agentType, cwd, initialPrompt, branch string, ov pipeline.StepOverride) (string, error) {
	id := newSessionID()
	opts := session.CreateOptions{CWD: cwd, Branch: branch, Override: session.SpawnOverride{
		Model:           ov.Model,
		ReasoningEffort: ov.ReasoningEffort,
		PermissionMode:  ov.PermissionMode,
		// ov.Instructions is prompt content, never argv — it is not part of
		// SpawnOverride. See StepOverride's doc comment.
	}}
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

func (p *pipelineSessionManager) TurnComplete(sessionID string) bool {
	sess, ok := p.m.Get(sessionID)
	if !ok {
		return false
	}
	// A turn is "complete" when the structured-chat backend's turn is not
	// active AND the session has produced at least one assistant reply.
	// The assistant-reply guard prevents a false positive in the
	// pre-first-turn window where turn_active is also false before the
	// initial prompt lands.
	if sess.TurnActive() {
		return false
	}
	entries, err := p.m.ConversationLog(sessionID)
	if err != nil {
		return false
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].Role == "assistant" {
			return true
		}
	}
	return false
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

// fanoutStepReq is the optional "fanout" object within a step in the create
// request. Its presence makes the step a fanout step. Models/ReasoningEfforts/
// PermissionModes/Instructions are optional index-aligned parallel arrays
// mirroring AgentTypes — see pipeline.FanoutConfig for the per-run fallback.
type fanoutStepReq struct {
	Count            int      `json:"count"`
	AgentTypes       []string `json:"agent_types,omitempty"`
	Models           []string `json:"models,omitempty"`
	ReasoningEfforts []string `json:"reasoning_efforts,omitempty"`
	PermissionModes  []string `json:"permission_modes,omitempty"`
	Instructions     []string `json:"instructions,omitempty"`
}

type createPipelineStepRequest struct {
	AgentType      string                 `json:"agent_type"`
	Role           string                 `json:"role"`
	PromptTemplate string                 `json:"prompt_template"`
	InputFromPrev  pipeline.InputFromPrev `json:"input_from_prev"`
	GateAfter      bool                   `json:"gate_after"`
	// StepConfig (embedded): model/reasoning_effort/permission_mode/
	// instructions for this block. All optional.
	pipeline.StepConfig
	// Fanout, when present, declares this step as a fanout step.
	Fanout *fanoutStepReq `json:"fanout,omitempty"`
	// Kind discriminates a control-flow step from a normal agent step: ""
	// (default, back-compatible) = agent step; "branch" = Branch must be
	// set; "loop" = Loop must be set. Nested then/else/body steps decode
	// directly as pipeline.Step (same field names as this request, plus
	// their own optional kind/branch/loop) — see pipeline.BranchConfig/
	// pipeline.LoopConfig. pipeline.PrepareSteps validates + normalizes the
	// whole tree (depth <= 2, max_iterations <= 5, well-formed conditions,
	// no fanout nested inside a branch arm or loop body) after this request
	// is decoded into pipeline.Step values, below.
	Kind   string                 `json:"kind,omitempty"`
	Branch *pipeline.BranchConfig `json:"branch,omitempty"`
	Loop   *pipeline.LoopConfig   `json:"loop,omitempty"`
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
		step := pipeline.Step{
			Index:          i,
			AgentType:      strings.TrimSpace(rs.AgentType),
			Role:           strings.TrimSpace(rs.Role),
			PromptTemplate: rs.PromptTemplate,
			InputFromPrev:  rs.InputFromPrev,
			GateAfter:      rs.GateAfter,
			StepConfig: pipeline.StepConfig{
				Model:           strings.TrimSpace(rs.Model),
				ReasoningEffort: strings.TrimSpace(rs.ReasoningEffort),
				PermissionMode:  strings.TrimSpace(rs.PermissionMode),
				Instructions:    rs.Instructions,
			},
			ControlFlow: pipeline.ControlFlow{
				Kind:   strings.TrimSpace(rs.Kind),
				Branch: rs.Branch,
				Loop:   rs.Loop,
			},
		}
		// AgentType defaulting for THIS (top-level) step happens here to
		// preserve existing behavior; pipeline.PrepareSteps (called once
		// below, after this loop) applies the same default recursively to
		// nested branch/loop steps and validates the whole tree.
		if step.AgentType == "" {
			step.AgentType = "claude"
		}
		if rs.Fanout != nil {
			fc := rs.Fanout
			// Infer count from agent_types length when count is omitted.
			count := fc.Count
			if count == 0 && len(fc.AgentTypes) > 0 {
				count = len(fc.AgentTypes)
			}
			if count < 1 || count > 6 {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout count must be between 1 and 6")
				return
			}
			if len(fc.AgentTypes) > 0 && len(fc.AgentTypes) != count {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout agent_types length must equal count")
				return
			}
			if len(fc.Models) > 0 && len(fc.Models) != count {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout models length must equal count")
				return
			}
			if len(fc.ReasoningEfforts) > 0 && len(fc.ReasoningEfforts) != count {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout reasoning_efforts length must equal count")
				return
			}
			if len(fc.PermissionModes) > 0 && len(fc.PermissionModes) != count {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout permission_modes length must equal count")
				return
			}
			if len(fc.Instructions) > 0 && len(fc.Instructions) != count {
				writeAPIError(w, http.StatusBadRequest, "invalid_request",
					"fanout instructions length must equal count")
				return
			}
			step.Fanout = &pipeline.FanoutConfig{
				Count:            count,
				AgentTypes:       fc.AgentTypes,
				Models:           fc.Models,
				ReasoningEfforts: fc.ReasoningEfforts,
				PermissionModes:  fc.PermissionModes,
				Instructions:     fc.Instructions,
			}
		}
		p.Steps[i] = step
	}

	if err := pipeline.PrepareSteps(p.Steps); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
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

// pipelineStepSummary is the mini-topology-strip view of one top-level step,
// carried on each /api/pipelines list item (#920 — the home FlowCard needs a
// per-step glyph strip without a second round-trip to GET /api/pipeline/{id}).
type pipelineStepSummary struct {
	Agent     string `json:"agent"`
	Role      string `json:"role"`
	Status    string `json:"status"`
	GateAfter bool   `json:"gate_after"`
}

// pipelineResultSummary is the diffstat-only slice of pipeline.PipelineResult
// carried on a list item once a pipeline completes — Output is deliberately
// omitted (can be large; the list endpoint is a summary, not a detail view).
type pipelineResultSummary struct {
	FilesChanged int    `json:"files_changed"`
	Insertions   int    `json:"insertions"`
	Deletions    int    `json:"deletions"`
	Finished     string `json:"finished,omitempty"`
}

type pipelineListItem struct {
	ID          string                 `json:"id"`
	Title       string                 `json:"title"`
	State       pipeline.PipelineState `json:"state"`
	CurrentStep int                    `json:"current_step"`
	StepCount   int                    `json:"step_count"`
	Created     string                 `json:"created,omitempty"`
	// Steps is one entry per top-level step, in order. Additive (#920).
	Steps []pipelineStepSummary `json:"steps,omitempty"`
	// Result is populated only once State == pipeline.PipelineComplete.
	// Additive (#920).
	Result *pipelineResultSummary `json:"result,omitempty"`
}

// stepDisplayStatus computes the coarse per-step status shown in the mini
// topology strip: "queued" | "running" | "done" | "failed" | "awaiting_gate"
// | "awaiting_pick". This mirrors PipelineStepDisplayViewModel.state(for:) in
// apps/ios/Sources/ConduitUI/Views/ConduitPipelineMonitorView.swift — the same
// phase+pipeline-context mapping the Monitor already computes client-side
// from the full GET /api/pipeline/{id} payload — just precomputed here so the
// list endpoint can offer it without a second round-trip. Keep the two in
// sync if the mapping changes.
func stepDisplayStatus(step pipeline.Step, state pipeline.PipelineState, currentStep int) string {
	isDonePhase := func(phase string) bool {
		return phase == "exited(0)" || phase == "exited" || phase == "turn_complete"
	}
	isFailedPhase := func(phase string) bool {
		return strings.HasPrefix(phase, "exited") && !isDonePhase(phase)
	}
	isRunningPhase := func(phase string) bool {
		return phase == "running" || phase == "ready"
	}
	isTerminal := state == pipeline.PipelineComplete || state == pipeline.PipelineFailed || state == pipeline.PipelineCancelled

	// fallbackState mirrors PipelineStepStatus.fallbackState(pipeline:) —
	// a display-state guess for a step whose phase doesn't map to a known
	// bucket, inferred from surrounding pipeline context. "" means "no
	// fallback signal applies" (caller renders "queued").
	fallbackState := func() string {
		if step.Ended != "" {
			return "done"
		}
		if state == pipeline.PipelineComplete {
			return "done"
		}
		if step.Index < currentStep {
			return "done"
		}
		if state == pipeline.PipelineFailed && step.Index == currentStep {
			return "failed"
		}
		return ""
	}

	hasFanoutRuns := step.Fanout != nil && len(step.Fanout.Runs) > 0
	if step.SessionID == "" && !hasFanoutRuns {
		if step.Kind == "loop" && step.Index == currentStep && !isTerminal {
			return "running"
		}
		if fb := fallbackState(); fb != "" {
			return fb
		}
		return "queued"
	}
	if isDonePhase(step.Phase) {
		return "done"
	}
	if isFailedPhase(step.Phase) {
		return "failed"
	}
	if state == pipeline.PipelineAwaitingPick && step.Index == currentStep {
		return "awaiting_pick"
	}
	if isRunningPhase(step.Phase) {
		if state == pipeline.PipelineAwaitingGate && step.Index == currentStep {
			return "awaiting_gate"
		}
		return "running"
	}
	if hasFanoutRuns {
		return "running"
	}
	if fb := fallbackState(); fb != "" {
		return fb
	}
	return "queued"
}

// buildPipelineListItems converts on-disk pipelines to their list-endpoint
// summary shape. Split out from serveListPipelines so the additive
// steps/result derivation is directly unit-testable without a live server or
// a resolvable conduit root (see pipeline_test.go).
func buildPipelineListItems(pipelines []*pipeline.Pipeline) []pipelineListItem {
	items := make([]pipelineListItem, 0, len(pipelines))
	for _, p := range pipelines {
		steps := make([]pipelineStepSummary, 0, len(p.Steps))
		for _, st := range p.Steps {
			steps = append(steps, pipelineStepSummary{
				Agent:     st.AgentType,
				Role:      st.Role,
				Status:    stepDisplayStatus(st, p.State, p.CurrentStep),
				GateAfter: st.GateAfter,
			})
		}
		var result *pipelineResultSummary
		if p.Result != nil {
			result = &pipelineResultSummary{
				FilesChanged: p.Result.FilesChanged,
				Insertions:   p.Result.Insertions,
				Deletions:    p.Result.Deletions,
				Finished:     p.Result.Finished,
			}
		}
		items = append(items, pipelineListItem{
			ID:          p.ID,
			Title:       p.Title,
			State:       p.State,
			CurrentStep: p.CurrentStep,
			StepCount:   len(p.Steps),
			Created:     p.Created,
			Steps:       steps,
			Result:      result,
		})
	}
	return items
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
	writeJSON(w, http.StatusOK, map[string]any{"pipelines": buildPipelineListItems(pipelines)})
}

// ── POST /api/pipeline/{id}/resume ──────────────────────────────────────────

// resumeBody is the optional request body for POST /api/pipeline/{id}/resume.
// Absent body or empty prompt = re-run using the original template rendering.
type resumeBody struct {
	Prompt string `json:"prompt"`
}

func (s *Server) serveResumePipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	// Path: /api/pipeline/{id}/resume
	tail := strings.TrimPrefix(r.URL.Path, "/api/pipeline/")
	id := strings.TrimSuffix(tail, "/resume")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid pipeline id")
		return
	}

	// Parse optional prompt override. Never an error if absent or malformed.
	var amendedPrompt string
	if r.Body != nil && r.ContentLength != 0 {
		var body resumeBody
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			amendedPrompt = strings.TrimSpace(body.Prompt)
		}
	}

	p, err := pipeline.Load(s.Sessions.ConduitRoot(), id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "pipeline not found: "+id)
		return
	}
	log.Printf("pipeline: resume %s (state=%s, amended_prompt=%v)", id, p.State, amendedPrompt != "")
	orch := s.pipelineOrchestrator()
	if err := orch.Resume(p, amendedPrompt); err != nil {
		if errors.Is(err, pipeline.ErrNotFailed) {
			writeAPIError(w, http.StatusConflict, "not_failed", "pipeline is not in failed state")
			return
		}
		log.Printf("pipeline: resume %s: %v", id, err)
		writeAPIError(w, http.StatusInternalServerError, "pipeline_resume_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":           p.ID,
		"state":        p.State,
		"current_step": p.CurrentStep,
	})
}

// ── POST /api/pipeline/{id}/pick ────────────────────────────────────────────

// pickBody is the request body for POST /api/pipeline/{id}/pick.
type pickBody struct {
	Run int `json:"run"`
}

func (s *Server) servePickPipeline(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	// Path: /api/pipeline/{id}/pick
	tail := strings.TrimPrefix(r.URL.Path, "/api/pipeline/")
	id := strings.TrimSuffix(tail, "/pick")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid pipeline id")
		return
	}

	var body pickBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}

	p, err := pipeline.Load(s.Sessions.ConduitRoot(), id)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "not_found", "pipeline not found: "+id)
		return
	}
	log.Printf("pipeline: pick %s (state=%s, run=%d)", id, p.State, body.Run)
	orch := s.pipelineOrchestrator()
	if err := orch.Pick(p, body.Run); err != nil {
		if errors.Is(err, pipeline.ErrNotAtPick) {
			writeAPIError(w, http.StatusConflict, "not_at_pick", "pipeline is not awaiting a pick")
			return
		}
		if errors.Is(err, pipeline.ErrRunFailed) {
			writeAPIError(w, http.StatusConflict, "run_failed", "selected run did not succeed")
			return
		}
		log.Printf("pipeline: pick %s: %v", id, err)
		// Check if it's a range error (400) vs internal error.
		writeAPIError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	// Determine winner index for response.
	var winnerIdx *int
	if k := p.CurrentStep; k < len(p.Steps) {
		step := &p.Steps[k]
		if step.IsFanout() && step.Fanout != nil {
			winnerIdx = step.Fanout.Winner
		}
	}

	resp := map[string]any{
		"id":           p.ID,
		"state":        p.State,
		"current_step": p.CurrentStep,
	}
	if winnerIdx != nil {
		resp["winner"] = *winnerIdx
	}
	writeJSON(w, http.StatusOK, resp)
}

// ── Pipeline Templates ───────────────────────────────────────────────────────

// templateStepRequest mirrors TemplateStep for the create body.
type templateStepRequest struct {
	AgentType      string                 `json:"agent_type"`
	Role           string                 `json:"role"`
	PromptTemplate string                 `json:"prompt_template"`
	InputFromPrev  pipeline.InputFromPrev `json:"input_from_prev"`
	GateAfter      bool                   `json:"gate_after"`
	// StepConfig (embedded): model/reasoning_effort/permission_mode/
	// instructions for this block. All optional.
	pipeline.StepConfig
	// Kind/Branch/Loop: same control-flow fields as createPipelineStepRequest
	// (see its doc comment) — templates carry the same shape so a pipeline
	// created FROM a template round-trips its branch/loop blocks too.
	Kind   string                 `json:"kind,omitempty"`
	Branch *pipeline.BranchConfig `json:"branch,omitempty"`
	Loop   *pipeline.LoopConfig   `json:"loop,omitempty"`
}

// createTemplateRequest is the body for POST /api/pipeline-templates.
type createTemplateRequest struct {
	Title string                `json:"title"`
	Task  string                `json:"task"`
	Steps []templateStepRequest `json:"steps"`
}

// serveListTemplates handles GET /api/pipeline-templates.
func (s *Server) serveListTemplates(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET required")
		return
	}
	templates, err := pipeline.ListTemplates(s.Sessions.ConduitRoot())
	if err != nil {
		log.Printf("pipeline-templates: list: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "list_failed", err.Error())
		return
	}
	if templates == nil {
		templates = []*pipeline.Template{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"templates": templates})
}

// serveCreateTemplate handles POST /api/pipeline-templates.
func (s *Server) serveCreateTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req createTemplateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Title = strings.TrimSpace(req.Title)
	if req.Title == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "title is required")
		return
	}
	if len(req.Steps) == 0 {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "at least one step is required")
		return
	}
	tmpl := &pipeline.Template{
		ID:    pipeline.NewTemplateID(),
		Title: req.Title,
		Task:  strings.TrimSpace(req.Task),
		Steps: make([]pipeline.TemplateStep, len(req.Steps)),
	}
	for i, rs := range req.Steps {
		at := strings.TrimSpace(rs.AgentType)
		if at == "" {
			at = "claude"
		}
		cf := pipeline.ControlFlow{Kind: strings.TrimSpace(rs.Kind), Branch: rs.Branch, Loop: rs.Loop}
		// Validate/normalize this step's control-flow content (depth <= 2,
		// max_iterations <= 5, well-formed conditions, no fanout nested
		// inside a branch arm or loop body). TemplateStep has no Fanout
		// field of its own, so a fresh wrapper Step is enough context —
		// nested Then/Else/Body are []pipeline.Step, mutated in place
		// through the SAME pointers stored in cf.Branch/cf.Loop.
		wrapper := pipeline.Step{AgentType: at, ControlFlow: cf}
		if err := pipeline.PrepareSteps([]pipeline.Step{wrapper}); err != nil {
			writeAPIError(w, http.StatusBadRequest, "invalid_request", err.Error())
			return
		}
		tmpl.Steps[i] = pipeline.TemplateStep{
			AgentType:      wrapper.AgentType,
			Role:           strings.TrimSpace(rs.Role),
			PromptTemplate: rs.PromptTemplate,
			InputFromPrev:  rs.InputFromPrev,
			GateAfter:      rs.GateAfter,
			StepConfig: pipeline.StepConfig{
				Model:           strings.TrimSpace(rs.Model),
				ReasoningEffort: strings.TrimSpace(rs.ReasoningEffort),
				PermissionMode:  strings.TrimSpace(rs.PermissionMode),
				Instructions:    rs.Instructions,
			},
			ControlFlow: wrapper.ControlFlow,
		}
	}
	if err := pipeline.SaveTemplate(s.Sessions.ConduitRoot(), tmpl); err != nil {
		log.Printf("pipeline-templates: save: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "save_failed", err.Error())
		return
	}
	log.Printf("pipeline-templates: created %s title=%q steps=%d", tmpl.ID, tmpl.Title, len(tmpl.Steps))
	writeJSON(w, http.StatusOK, map[string]any{"id": tmpl.ID})
}

// serveDeleteTemplate handles DELETE /api/pipeline-templates/{id}.
func (s *Server) serveDeleteTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	if r.Method != http.MethodDelete {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "DELETE required")
		return
	}
	id := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/api/pipeline-templates/"))
	if id == "" || strings.Contains(id, "/") {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "missing or invalid template id")
		return
	}
	if err := pipeline.DeleteTemplate(s.Sessions.ConduitRoot(), id); err != nil {
		if strings.Contains(err.Error(), "not found") {
			writeAPIError(w, http.StatusNotFound, "not_found", "template not found: "+id)
			return
		}
		log.Printf("pipeline-templates: delete %s: %v", id, err)
		writeAPIError(w, http.StatusInternalServerError, "delete_failed", err.Error())
		return
	}
	log.Printf("pipeline-templates: deleted %s", id)
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "deleted": true})
}

// servePipelineTemplateRouter dispatches /api/pipeline-templates and
// /api/pipeline-templates/{id}. Registered separately from servePipelineRouter
// so "templates" is not consumed by the {id} wildcard in /api/pipeline/*.
func (s *Server) servePipelineTemplateRouter(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/api/pipeline-templates" && r.Method == http.MethodGet:
		s.serveListTemplates(w, r)
	case path == "/api/pipeline-templates" && r.Method == http.MethodPost:
		s.serveCreateTemplate(w, r)
	case strings.HasPrefix(path, "/api/pipeline-templates/") && r.Method == http.MethodDelete:
		s.serveDeleteTemplate(w, r)
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "unsupported method for this template endpoint")
	}
}

// ── Router dispatch ──────────────────────────────────────────────────────────

// servePipelineRouter dispatches /api/pipeline/* and /api/pipelines.
// Routes:
//
//	GET    /api/pipelines              → serveListPipelines
//	POST   /api/pipeline               → serveCreatePipeline
//	GET    /api/pipeline/{id}          → serveGetPipeline
//	POST   /api/pipeline/{id}/continue → serveContinuePipeline
//	POST   /api/pipeline/{id}/resume   → serveResumePipeline
//	POST   /api/pipeline/{id}/pick     → servePickPipeline
//	DELETE /api/pipeline/{id}          → serveDeletePipeline
func (s *Server) servePipelineRouter(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/api/pipelines":
		s.serveListPipelines(w, r)
	case path == "/api/pipeline":
		s.serveCreatePipeline(w, r)
	case strings.HasSuffix(path, "/continue"):
		s.serveContinuePipeline(w, r)
	case strings.HasSuffix(path, "/resume"):
		s.serveResumePipeline(w, r)
	case strings.HasSuffix(path, "/pick"):
		s.servePickPipeline(w, r)
	case r.Method == http.MethodDelete:
		s.serveDeletePipeline(w, r)
	case r.Method == http.MethodGet:
		s.serveGetPipeline(w, r)
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "unsupported method for this pipeline endpoint")
	}
}
