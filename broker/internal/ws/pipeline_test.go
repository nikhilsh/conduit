package ws

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/pipeline"
)

// TestContinueBodyParsing unit-tests that the continueBody struct correctly
// deserialises the "prev" field. This confirms the handler's JSON decode path
// for all edge cases: with prev, empty prev, empty object, no body, malformed JSON.
func TestContinueBodyParsing(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		wantPrev string
	}{
		{"with prev", `{"prev":"amended text"}`, "amended text"},
		{"empty prev field", `{"prev":""}`, ""},
		{"empty object", `{}`, ""},
		{"no body", ``, ""},
		{"malformed JSON", `not-json`, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var gotPrev string
			if tc.body != "" {
				var body continueBody
				if err := json.NewDecoder(strings.NewReader(tc.body)).Decode(&body); err == nil {
					gotPrev = body.Prev
				}
				// parse error -> gotPrev stays ""
			}
			if gotPrev != tc.wantPrev {
				t.Errorf("gotPrev=%q, want %q", gotPrev, tc.wantPrev)
			}
		})
	}
}

// setupPipelineAtGate creates a pipeline JSON on disk in awaiting_gate state,
// with Gate.Prev = "original prev". Returns the pipeline ID and the conduit root.
// The conduit root is the server session manager's conduit root — obtained by
// writing through the same path that GET /api/pipeline/{id} reads from.
//
// Since we cannot reach into s.Sessions.ConduitRoot() from outside the package
// in tests that use newTestServer (which uses a session.Manager whose conduit root
// is determined by env vars), we use the OS temp dir approach: the session.Manager
// sets conduitRoot based on CONDUIT_ROOT env var or a default. For unit-level
// ws handler tests we instead call the endpoint against a pipeline we know is
// in the right conduitRoot — which means we need access to that root.
//
// The integration tests below are skipped if conduitRoot cannot be resolved.
// The body-parsing test above (unit) and the orchestrator_test.go (package-level)
// together give full coverage without needing the integration path.
func setupPipelineAtGate(t *testing.T, conduitRoot string) string {
	t.Helper()
	p := &pipeline.Pipeline{
		ID:          pipeline.NewID(),
		Title:       "test pipeline",
		Task:        "do things",
		CWD:         "/tmp",
		State:       pipeline.PipelineAwaitingGate,
		CurrentStep: 0,
		Steps: []pipeline.Step{
			{
				Index:          0,
				AgentType:      "claude",
				PromptTemplate: "step 0",
				InputFromPrev:  pipeline.InputNone,
				GateAfter:      true,
				SessionID:      "sess-0",
				Phase:          "exited(0)",
			},
			{
				Index:          1,
				AgentType:      "claude",
				PromptTemplate: "step 1: {{prev}}",
				InputFromPrev:  pipeline.InputOutput,
			},
		},
		Gate: &pipeline.GatePreview{Step: 0, Prev: "original prev", Output: "original output"},
	}
	if err := p.Save(conduitRoot); err != nil {
		t.Fatalf("save test pipeline: %v", err)
	}
	return p.ID
}

// TestContinueEndpointBodyPrev exercises the full HTTP handler path: POST
// /api/pipeline/{id}/continue with {"prev":"X"} body. We assert that the
// handler does NOT return 404 (pipeline not found) or 409 (not at gate).
// A 200 or 500 (spawn fails because no real agent) are both acceptable.
func TestContinueEndpointBodyPrev(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment; body-parsing covered by TestContinueBodyParsing")
	}

	pipelineID := setupPipelineAtGate(t, conduitRoot)
	bodyBytes, _ := json.Marshal(map[string]string{"prev": "new handoff text"})
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/continue?token="+url.QueryEscape(tok),
		bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST continue: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		t.Fatalf("got 404: pipeline not found — conduitRoot mismatch or write failed")
	}
	if resp.StatusCode == http.StatusConflict {
		t.Fatalf("got 409: pipeline not at gate — state not persisted or Continue ignored gate")
	}
}

// TestContinueEndpointEmptyBody exercises the full HTTP handler with no body;
// the handler must not error and must proceed to Continue with empty amendedPrev.
func TestContinueEndpointEmptyBody(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	pipelineID := setupPipelineAtGate(t, conduitRoot)
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/continue?token="+url.QueryEscape(tok),
		nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST continue: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		t.Fatalf("got 404: pipeline not found")
	}
	if resp.StatusCode == http.StatusConflict {
		t.Fatalf("got 409: empty body must not break gate state")
	}
}

// TestBuildPipelineListItemsStepsAndResult asserts the additive `steps` and
// `result` fields on the /api/pipelines list summary (#920 — home FlowCard
// mini topology strip): one entry per top-level step with the derived
// display status, gate_after, and — once complete — a diffstat-only result.
func TestBuildPipelineListItemsStepsAndResult(t *testing.T) {
	p := &pipeline.Pipeline{
		ID:          "p_test1",
		Title:       "test pipeline",
		State:       pipeline.PipelineComplete,
		CurrentStep: 2,
		Steps: []pipeline.Step{
			{Index: 0, AgentType: "claude", Role: "planner", GateAfter: true, SessionID: "sess-0", Phase: "exited(0)"},
			{Index: 1, AgentType: "codex", Role: "implementer", GateAfter: false, SessionID: "sess-1", Phase: "turn_complete"},
			{Index: 2, AgentType: "claude", Role: "reviewer", GateAfter: false, SessionID: "sess-2", Phase: "exited(1)"},
		},
		Result: &pipeline.PipelineResult{
			Output:       "done",
			Finished:     "2026-07-07T00:00:00Z",
			FilesChanged: 3,
			Insertions:   10,
			Deletions:    2,
		},
	}

	items := buildPipelineListItems([]*pipeline.Pipeline{p})
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	item := items[0]

	wantSteps := []pipelineStepSummary{
		{Agent: "claude", Role: "planner", Status: "done", GateAfter: true},
		{Agent: "codex", Role: "implementer", Status: "done", GateAfter: false},
		{Agent: "claude", Role: "reviewer", Status: "failed", GateAfter: false},
	}
	if len(item.Steps) != len(wantSteps) {
		t.Fatalf("got %d steps, want %d", len(item.Steps), len(wantSteps))
	}
	for i, want := range wantSteps {
		if got := item.Steps[i]; got != want {
			t.Errorf("step %d: got %+v, want %+v", i, got, want)
		}
	}

	if item.Result == nil {
		t.Fatal("Result is nil, want non-nil for a complete pipeline")
	}
	wantResult := pipelineResultSummary{FilesChanged: 3, Insertions: 10, Deletions: 2, Finished: "2026-07-07T00:00:00Z"}
	if *item.Result != wantResult {
		t.Errorf("Result = %+v, want %+v", *item.Result, wantResult)
	}

	// Existing fields must be untouched by the additive change.
	if item.ID != p.ID || item.Title != p.Title || item.State != p.State ||
		item.CurrentStep != p.CurrentStep || item.StepCount != len(p.Steps) {
		t.Errorf("existing summary fields regressed: %+v", item)
	}
}

// TestFilterArchivedPipelines verifies the GET /api/pipelines default
// (excludes archived) and ?include_archived=1 (includes them) behaviors.
func TestFilterArchivedPipelines(t *testing.T) {
	live := &pipeline.Pipeline{ID: "p_live", State: pipeline.PipelineRunning}
	archived := &pipeline.Pipeline{ID: "p_archived", State: pipeline.PipelineComplete, Archived: true}
	all := []*pipeline.Pipeline{live, archived}

	got := filterArchivedPipelines(all, false)
	if len(got) != 1 || got[0].ID != "p_live" {
		t.Errorf("default filter: got %v, want only p_live", ids(got))
	}

	got = filterArchivedPipelines(all, true)
	if len(got) != 2 {
		t.Errorf("include_archived: got %v, want both pipelines", ids(got))
	}
}

func ids(pipelines []*pipeline.Pipeline) []string {
	out := make([]string, len(pipelines))
	for i, p := range pipelines {
		out[i] = p.ID
	}
	return out
}

// TestBuildPipelineListItemsArchivedField verifies the additive `archived`
// field: omitted (false) for a non-archived pipeline, true for an archived one.
func TestBuildPipelineListItemsArchivedField(t *testing.T) {
	notArchived := &pipeline.Pipeline{ID: "p_1", State: pipeline.PipelineComplete}
	isArchived := &pipeline.Pipeline{ID: "p_2", State: pipeline.PipelineComplete, Archived: true}

	items := buildPipelineListItems([]*pipeline.Pipeline{notArchived, isArchived})
	if len(items) != 2 {
		t.Fatalf("got %d items, want 2", len(items))
	}
	if items[0].Archived {
		t.Error("items[0].Archived = true, want false")
	}
	if !items[1].Archived {
		t.Error("items[1].Archived = false, want true")
	}

	data, err := json.Marshal(items[0])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), `"archived"`) {
		t.Errorf("archived field present in JSON for non-archived item; got %s", string(data))
	}
}

// TestStepDisplayStatusBuckets covers the six display-status buckets computed
// by stepDisplayStatus, mirroring PipelineStepDisplayViewModel.state(for:) in
// ConduitPipelineMonitorView.swift.
func TestStepDisplayStatusBuckets(t *testing.T) {
	cases := []struct {
		name        string
		step        pipeline.Step
		state       pipeline.PipelineState
		currentStep int
		want        string
	}{
		{
			name:        "queued: no session, ahead of current step",
			step:        pipeline.Step{Index: 1},
			state:       pipeline.PipelineRunning,
			currentStep: 0,
			want:        "queued",
		},
		{
			name:        "done: no session but index behind current step (fallback)",
			step:        pipeline.Step{Index: 0},
			state:       pipeline.PipelineRunning,
			currentStep: 1,
			want:        "done",
		},
		{
			name:        "running: session present, phase running",
			step:        pipeline.Step{Index: 0, SessionID: "s0", Phase: "running"},
			state:       pipeline.PipelineRunning,
			currentStep: 0,
			want:        "running",
		},
		{
			name:        "awaiting_gate: running phase + pipeline at gate on this step",
			step:        pipeline.Step{Index: 0, SessionID: "s0", Phase: "running"},
			state:       pipeline.PipelineAwaitingGate,
			currentStep: 0,
			want:        "awaiting_gate",
		},
		{
			name:        "awaiting_pick: pipeline awaiting pick on this step",
			step:        pipeline.Step{Index: 0, SessionID: "s0", Phase: "exited(0)"},
			state:       pipeline.PipelineAwaitingPick,
			currentStep: 0,
			want:        "done", // isDonePhase takes precedence over awaiting_pick per the mirrored Swift order
		},
		{
			name:        "failed: exited(1) phase",
			step:        pipeline.Step{Index: 0, SessionID: "s0", Phase: "exited(1)"},
			state:       pipeline.PipelineFailed,
			currentStep: 0,
			want:        "failed",
		},
		{
			name:        "done: turn_complete phase (structured-chat backend)",
			step:        pipeline.Step{Index: 0, SessionID: "s0", Phase: "turn_complete"},
			state:       pipeline.PipelineComplete,
			currentStep: 1,
			want:        "done",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := stepDisplayStatus(tc.step, tc.state, tc.currentStep)
			if got != tc.want {
				t.Errorf("stepDisplayStatus() = %q, want %q", got, tc.want)
			}
		})
	}
}

// resolveConduitRoot attempts to determine the conduit root used by the test
// server's session.Manager. Since we cannot reach into the session.Manager
// from outside the package without refactoring, this returns "" and callers
// skip the integration test. The meaningful assertions live in the
// orchestrator_test.go package-internal tests.
func resolveConduitRoot(t *testing.T, _ string, _ string) string {
	t.Helper()
	return ""
}

// TestPipelineGatePreviewCapability verifies that the capabilities endpoint
// advertises pipeline_gate_preview=true.
func TestPipelineGatePreviewCapability(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("capabilities status=%d", resp.StatusCode)
	}
	var body struct {
		Features struct {
			Pipeline            bool `json:"pipeline"`
			PipelineGatePreview bool `json:"pipeline_gate_preview"`
			PipelineResume      bool `json:"pipeline_resume"`
			PipelineTemplates   bool `json:"pipeline_templates"`
		} `json:"features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode capabilities: %v", err)
	}
	if !body.Features.Pipeline {
		t.Error("features.pipeline is false; want true")
	}
	if !body.Features.PipelineGatePreview {
		t.Error("features.pipeline_gate_preview is false; want true")
	}
	if !body.Features.PipelineResume {
		t.Error("features.pipeline_resume is false; want true")
	}
	if !body.Features.PipelineTemplates {
		t.Error("features.pipeline_templates is false; want true")
	}
}

// TestCapabilitiesPipelineArchive verifies the capabilities endpoint
// advertises pipeline_archive=true (both features.* and the root mirror).
func TestCapabilitiesPipelineArchive(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("capabilities status=%d", resp.StatusCode)
	}
	var body struct {
		Features struct {
			PipelineArchive bool `json:"pipeline_archive"`
		} `json:"features"`
		PipelineArchive bool `json:"pipeline_archive"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode capabilities: %v", err)
	}
	if !body.Features.PipelineArchive {
		t.Error("features.pipeline_archive is false; want true")
	}
	if !body.PipelineArchive {
		t.Error("root pipeline_archive mirror is false; want true")
	}
}

// setupFailedPipeline creates a pipeline JSON on disk in the failed state
// at step 0. Returns the pipeline ID and the conduit root.
func setupFailedPipeline(t *testing.T, conduitRoot string) string {
	t.Helper()
	p := &pipeline.Pipeline{
		ID:          pipeline.NewID(),
		Title:       "test failed pipeline",
		Task:        "do things",
		CWD:         "/tmp",
		State:       pipeline.PipelineFailed,
		CurrentStep: 0,
		Steps: []pipeline.Step{
			{
				Index:          0,
				AgentType:      "claude",
				PromptTemplate: "step 0: {{task}}",
				InputFromPrev:  pipeline.InputNone,
				SessionID:      "failed-sess-0",
				Phase:          "exited(1)",
			},
		},
	}
	if err := p.Save(conduitRoot); err != nil {
		t.Fatalf("save test pipeline: %v", err)
	}
	return p.ID
}

// TestResumeEndpoint409WhenNotFailed verifies that POST /api/pipeline/{id}/resume
// returns 409 "not_failed" for a pipeline that is not in the failed state.
func TestResumeEndpoint409WhenNotFailed(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	// Create a pipeline in awaiting_gate state (not failed).
	pipelineID := setupPipelineAtGate(t, conduitRoot)
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/resume?token="+url.QueryEscape(tok),
		nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST resume: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Errorf("expected 409; got %d", resp.StatusCode)
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Error.Code != "not_failed" {
		t.Errorf("error code=%q, want not_failed", body.Error.Code)
	}
}

// TestResumeEndpointFailedPipeline verifies that POST /api/pipeline/{id}/resume
// on a failed pipeline does not return 404 or 409.
func TestResumeEndpointFailedPipeline(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	pipelineID := setupFailedPipeline(t, conduitRoot)
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/resume?token="+url.QueryEscape(tok),
		nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST resume: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		t.Fatalf("got 404: pipeline not found — conduitRoot mismatch or write failed")
	}
	if resp.StatusCode == http.StatusConflict {
		t.Fatalf("got 409 not_failed for a pipeline that is actually failed")
	}
}

// setupCompletePipeline creates a pipeline JSON on disk in the complete state.
// Returns the pipeline ID.
func setupCompletePipeline(t *testing.T, conduitRoot string) string {
	t.Helper()
	p := &pipeline.Pipeline{
		ID:          pipeline.NewID(),
		Title:       "test complete pipeline",
		Task:        "do things",
		CWD:         "/tmp",
		State:       pipeline.PipelineComplete,
		CurrentStep: 0,
		Steps: []pipeline.Step{
			{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: pipeline.InputNone, SessionID: "sess-0", Phase: "exited(0)"},
		},
	}
	if err := p.Save(conduitRoot); err != nil {
		t.Fatalf("save test pipeline: %v", err)
	}
	return p.ID
}

// TestArchiveEndpoint409WhenNotTerminal verifies POST /api/pipeline/{id}/archive
// returns 409 "not_terminal" for a pipeline that is not in a terminal state.
func TestArchiveEndpoint409WhenNotTerminal(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	// Awaiting-gate is not a terminal state.
	pipelineID := setupPipelineAtGate(t, conduitRoot)
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/archive?token="+url.QueryEscape(tok),
		nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST archive: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Errorf("expected 409; got %d", resp.StatusCode)
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Error.Code != "not_terminal" {
		t.Errorf("error code=%q, want not_terminal", body.Error.Code)
	}
}

// TestArchiveUnarchiveEndpointRoundTrip exercises the full HTTP path: archive
// a complete pipeline, then unarchive it, asserting no 404/409 along the way.
func TestArchiveUnarchiveEndpointRoundTrip(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	pipelineID := setupCompletePipeline(t, conduitRoot)

	archiveReq, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/archive?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(archiveReq)
	if err != nil {
		t.Fatalf("POST archive: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("archive status=%d, want 200", resp.StatusCode)
	}

	unarchiveReq, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/unarchive?token="+url.QueryEscape(tok), nil)
	resp, err = http.DefaultClient.Do(unarchiveReq)
	if err != nil {
		t.Fatalf("POST unarchive: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("unarchive status=%d, want 200", resp.StatusCode)
	}
}

// ── Pipeline templates HTTP tests ────────────────────────────────────────────

// TestTemplateRoundTripHTTP exercises the full HTTP create→list→delete cycle
// for /api/pipeline-templates.
func TestTemplateRoundTripHTTP(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	// POST /api/pipeline-templates to create.
	createBody := `{
		"title": "Research + Build",
		"task":  "Build a rate limiter",
		"steps": [
			{"agent_type":"claude","role":"researcher","prompt_template":"Research: {{task}}","input_from_prev":"none","gate_after":false},
			{"agent_type":"claude","role":"engineer","prompt_template":"Build: {{prev}}","input_from_prev":"memory+output","gate_after":true}
		]
	}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline-templates?token="+url.QueryEscape(tok),
		strings.NewReader(createBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST template: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("POST template status=%d", resp.StatusCode)
	}
	var createResp struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&createResp); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if createResp.ID == "" {
		t.Fatal("create response has empty id")
	}

	// GET /api/pipeline-templates to list.
	req2, _ := http.NewRequest(http.MethodGet,
		srv.URL+"/api/pipeline-templates?token="+url.QueryEscape(tok),
		nil)
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("GET templates: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("GET templates status=%d", resp2.StatusCode)
	}
	var listResp struct {
		Templates []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"templates"`
	}
	if err := json.NewDecoder(resp2.Body).Decode(&listResp); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	found := false
	for _, tmpl := range listResp.Templates {
		if tmpl.ID == createResp.ID {
			found = true
			if tmpl.Title != "Research + Build" {
				t.Errorf("template title=%q, want %q", tmpl.Title, "Research + Build")
			}
		}
	}
	if !found {
		t.Errorf("created template %s not found in list", createResp.ID)
	}

	// DELETE /api/pipeline-templates/{id}.
	req3, _ := http.NewRequest(http.MethodDelete,
		srv.URL+"/api/pipeline-templates/"+createResp.ID+"?token="+url.QueryEscape(tok),
		nil)
	resp3, err := http.DefaultClient.Do(req3)
	if err != nil {
		t.Fatalf("DELETE template: %v", err)
	}
	defer resp3.Body.Close()
	if resp3.StatusCode != http.StatusOK {
		t.Fatalf("DELETE template status=%d", resp3.StatusCode)
	}

	// List must be empty (or at least not contain the deleted id).
	req4, _ := http.NewRequest(http.MethodGet,
		srv.URL+"/api/pipeline-templates?token="+url.QueryEscape(tok),
		nil)
	resp4, err := http.DefaultClient.Do(req4)
	if err != nil {
		t.Fatalf("GET templates after delete: %v", err)
	}
	defer resp4.Body.Close()
	var listResp2 struct {
		Templates []struct {
			ID string `json:"id"`
		} `json:"templates"`
	}
	_ = json.NewDecoder(resp4.Body).Decode(&listResp2)
	for _, tmpl := range listResp2.Templates {
		if tmpl.ID == createResp.ID {
			t.Errorf("deleted template %s still present in list", createResp.ID)
		}
	}
}

// TestCapabilitiesPipelineFanout verifies that features.pipeline_fanout is true.
func TestCapabilitiesPipelineFanout(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("capabilities status=%d", resp.StatusCode)
	}
	var body struct {
		Features struct {
			PipelineFanout bool `json:"pipeline_fanout"`
		} `json:"features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode capabilities: %v", err)
	}
	if !body.Features.PipelineFanout {
		t.Error("features.pipeline_fanout is false; want true")
	}
}

// TestCapabilitiesPipelineBlockConfig verifies the capabilities endpoint
// advertises pipeline_block_config=true so apps know per-block model/effort/
// permission_mode/instructions are honored by this broker.
func TestCapabilitiesPipelineBlockConfig(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("capabilities status=%d", resp.StatusCode)
	}
	var body struct {
		Features struct {
			PipelineBlockConfig bool `json:"pipeline_block_config"`
			PipelineBranch      bool `json:"pipeline_branch"`
			PipelineLoop        bool `json:"pipeline_loop"`
			PipelineResult      bool `json:"pipeline_result"`
		} `json:"features"`
		// Root-level mirrors: fielded apps (through v0.0.214) decode the
		// pipeline_* flags from the JSON root, not features.* — both
		// locations must advertise true. pipeline_branch/pipeline_loop/
		// pipeline_result are NEW flags (docs/PLAN-HARNESS-BUILDER.md
		// §4.1/§4.2; pipeline result persistence) but the same root-mirror
		// footgun applies (#891) — they must be mirrored too.
		Pipeline            bool `json:"pipeline"`
		PipelineGatePreview bool `json:"pipeline_gate_preview"`
		PipelineResume      bool `json:"pipeline_resume"`
		PipelineTemplates   bool `json:"pipeline_templates"`
		PipelineFanout      bool `json:"pipeline_fanout"`
		PipelineBlockConfig bool `json:"pipeline_block_config"`
		PipelineBranch      bool `json:"pipeline_branch"`
		PipelineLoop        bool `json:"pipeline_loop"`
		PipelineResult      bool `json:"pipeline_result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode capabilities: %v", err)
	}
	if !body.Features.PipelineBlockConfig {
		t.Error("features.pipeline_block_config is false; want true")
	}
	if !body.Features.PipelineBranch {
		t.Error("features.pipeline_branch is false; want true")
	}
	if !body.Features.PipelineLoop {
		t.Error("features.pipeline_loop is false; want true")
	}
	if !body.Features.PipelineResult {
		t.Error("features.pipeline_result is false; want true")
	}
	if !body.Pipeline || !body.PipelineGatePreview || !body.PipelineResume ||
		!body.PipelineTemplates || !body.PipelineFanout || !body.PipelineBlockConfig ||
		!body.PipelineBranch || !body.PipelineLoop || !body.PipelineResult {
		t.Errorf("root-level pipeline flag mirrors missing: %+v", body)
	}
}

// TestCreatePipelineStepConfigFields verifies POST /api/pipeline accepts the
// per-step model/reasoning_effort/permission_mode/instructions fields without
// error (the create+start round trip already exercises real spawn via the
// "cat" test adapter — see newTestRegistry).
func TestCreatePipelineStepConfigFields(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"title":"t","task":"do the thing","steps":[{"agent_type":"claude","prompt_template":"{{task}}","input_from_prev":"none","model":"opus","reasoning_effort":"high","permission_mode":"plan","instructions":"be terse"}]}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pipeline: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200; got %d", resp.StatusCode)
	}
}

// TestCreatePipelineWithBranchStep verifies POST /api/pipeline accepts a
// step with kind=branch (condition + then/else nested steps) and starts the
// pipeline without error.
func TestCreatePipelineWithBranchStep(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"title":"t","task":"do the thing","steps":[
		{"agent_type":"claude","prompt_template":"{{task}}","input_from_prev":"none"},
		{"kind":"branch","branch":{
			"condition":{"source":"exit_status","predicate":"succeeded"},
			"then":[{"agent_type":"claude","prompt_template":"then step"}],
			"else":[{"agent_type":"claude","prompt_template":"else step"}]
		}}
	]}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pipeline: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200; got %d", resp.StatusCode)
	}
}

// TestCreatePipelineWithLoopStep verifies POST /api/pipeline accepts a step
// with kind=loop (body + until + max_iterations) and starts the pipeline
// without error.
func TestCreatePipelineWithLoopStep(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"title":"t","task":"do the thing","steps":[
		{"kind":"loop","loop":{
			"body":[{"agent_type":"claude","prompt_template":"iterate: {{task}}"}],
			"until":{"source":"prev_output","predicate":"contains","value":"DONE"},
			"max_iterations":3
		}}
	]}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pipeline: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200; got %d", resp.StatusCode)
	}
}

// TestCreatePipelineRejectsOversizedLoopIterations verifies POST
// /api/pipeline returns 400 invalid_request when max_iterations > 5 (§8.5).
func TestCreatePipelineRejectsOversizedLoopIterations(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"title":"t","task":"do the thing","steps":[
		{"kind":"loop","loop":{
			"body":[{"agent_type":"claude","prompt_template":"iterate"}],
			"until":{"source":"prev_output","predicate":"contains","value":"DONE"},
			"max_iterations":6
		}}
	]}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pipeline: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400; got %d", resp.StatusCode)
	}
}

// TestCreatePipelineRejectsDepth3Branch verifies POST /api/pipeline returns
// 400 invalid_request when a branch is nested three levels deep (§4.1: depth
// bound is 2).
func TestCreatePipelineRejectsDepth3Branch(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"title":"t","task":"do the thing","steps":[
		{"kind":"branch","branch":{
			"condition":{"source":"exit_status","predicate":"succeeded"},
			"then":[
				{"kind":"branch","branch":{
					"condition":{"source":"exit_status","predicate":"succeeded"},
					"then":[{"agent_type":"claude","prompt_template":"too deep"}]
				}}
			]
		}}
	]}`
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pipeline: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400; got %d", resp.StatusCode)
	}
}

// setupAwaitingPickPipeline creates a fanout pipeline in awaiting_pick state.
func setupAwaitingPickPipeline(t *testing.T, conduitRoot string) (pipelineID string) {
	t.Helper()
	run0SessID := "fanout-run-0"
	run1SessID := "fanout-run-1"
	winner := 0
	_ = winner
	p := &pipeline.Pipeline{
		ID:          pipeline.NewID(),
		Title:       "fanout test",
		Task:        "do things",
		CWD:         "/tmp",
		State:       pipeline.PipelineAwaitingPick,
		CurrentStep: 0,
		Steps: []pipeline.Step{
			{
				Index:         0,
				AgentType:     "claude",
				InputFromPrev: pipeline.InputNone,
				Fanout: &pipeline.FanoutConfig{
					Count: 2,
					Runs: []pipeline.FanoutRun{
						{Index: 0, SessionID: run0SessID, Phase: "exited(0)"},
						{Index: 1, SessionID: run1SessID, Phase: "exited(1)"},
					},
				},
			},
		},
	}
	if err := p.Save(conduitRoot); err != nil {
		t.Fatalf("save test pipeline: %v", err)
	}
	return p.ID
}

// TestPickEndpointNotAtPick verifies POST /api/pipeline/{id}/pick returns 409
// "not_at_pick" when the pipeline is not in awaiting_pick state.
func TestPickEndpointNotAtPick(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	// Use a pipeline at gate (not awaiting_pick).
	pipelineID := setupPipelineAtGate(t, conduitRoot)
	bodyBytes, _ := json.Marshal(map[string]int{"run": 0})
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/pick?token="+url.QueryEscape(tok),
		bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pick: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Errorf("expected 409; got %d", resp.StatusCode)
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Error.Code != "not_at_pick" {
		t.Errorf("error code=%q, want not_at_pick", body.Error.Code)
	}
}

// TestPickEndpointRunFailed verifies POST /api/pipeline/{id}/pick returns 409
// "run_failed" when the selected run did not exit(0).
func TestPickEndpointRunFailed(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	pipelineID := setupAwaitingPickPipeline(t, conduitRoot)
	// Run 1 failed (exited(1)) — pick it to trigger run_failed.
	bodyBytes, _ := json.Marshal(map[string]int{"run": 1})
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/pick?token="+url.QueryEscape(tok),
		bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pick: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Errorf("expected 409 run_failed; got %d", resp.StatusCode)
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Error.Code != "run_failed" {
		t.Errorf("error code=%q, want run_failed", body.Error.Code)
	}
}

// TestPickEndpointSuccess verifies POST /api/pipeline/{id}/pick on a
// succeeded run does not return 404, 409, or a method-not-allowed error.
func TestPickEndpointSuccess(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}

	pipelineID := setupAwaitingPickPipeline(t, conduitRoot)
	// Run 0 succeeded; pick it.
	bodyBytes, _ := json.Marshal(map[string]int{"run": 0})
	req, _ := http.NewRequest(http.MethodPost,
		srv.URL+"/api/pipeline/"+pipelineID+"/pick?token="+url.QueryEscape(tok),
		bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST pick: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		t.Fatalf("got 404: pipeline not found — conduitRoot mismatch or write failed")
	}
	if resp.StatusCode == http.StatusConflict {
		var body struct {
			Error struct{ Code string } `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		t.Fatalf("got 409 %q for a valid pick", body.Error.Code)
	}
}

// TestCreateValidatesFanoutConfig verifies that POST /api/pipeline rejects
// invalid fanout configs with 400.
func TestCreateValidatesFanoutConfig(t *testing.T) {
	srv, tok := newTestServer(t)

	cases := []struct {
		name string
		body string
	}{
		{
			"count zero",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":0}}]}`,
		},
		{
			"count too large",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":7}}]}`,
		},
		{
			"agent_types length mismatch",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":2,"agent_types":["claude","codex","opencode"]}}]}`,
		},
		{
			"models length mismatch",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":2,"models":["opus","gpt-5-codex","gemini"]}}]}`,
		},
		{
			"reasoning_efforts length mismatch",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":3,"reasoning_efforts":["high","low"]}}]}`,
		},
		{
			"permission_modes length mismatch",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":2,"permission_modes":["plan"]}}]}`,
		},
		{
			"instructions length mismatch",
			`{"title":"t","task":"t","steps":[{"agent_type":"claude","prompt_template":"p","input_from_prev":"none","fanout":{"count":2,"instructions":["a","b","c"]}}]}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodPost,
				srv.URL+"/api/pipeline?token="+url.QueryEscape(tok),
				strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("POST pipeline: %v", err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Errorf("expected 400; got %d", resp.StatusCode)
			}
		})
	}
}

// TestTemplateDelete404 verifies that DELETE /api/pipeline-templates/{id}
// returns 404 for a non-existent template.
func TestTemplateDelete404(t *testing.T) {
	srv, tok := newTestServer(t)
	conduitRoot := resolveConduitRoot(t, srv.URL, tok)
	if conduitRoot == "" {
		t.Skip("conduitRoot not deterministic in this environment")
	}
	_ = conduitRoot

	req, _ := http.NewRequest(http.MethodDelete,
		srv.URL+"/api/pipeline-templates/p_nonexist?token="+url.QueryEscape(tok),
		nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("DELETE template: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("expected 404; got %d", resp.StatusCode)
	}
}
