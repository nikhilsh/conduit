package ws

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

func TestCapabilitiesEndpoint(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["name"] != "conduit-broker" {
		t.Fatalf("unexpected name: %v", body["name"])
	}
	assistants, _ := body["assistants"].([]any)
	if len(assistants) < 1 {
		t.Fatalf("expected assistants, got %v", body["assistants"])
	}
	// Discovery hasn't run in tests → "models" must be omitted entirely so
	// the apps fall back to their built-in lists.
	if _, present := body["models"]; present {
		t.Fatalf("models should be omitted before discovery, got %v", body["models"])
	}
}

func TestCapabilitiesIncludesDiscoveredModels(t *testing.T) {
	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	m.SetModelCatalog("claude", []session.ModelInfo{
		{ID: "", DisplayName: "Default (recommended)", Description: "Opus 4.8 with 1M context", IsDefault: true, Efforts: []string{"low", "medium", "high", "xhigh", "max"}},
		{ID: "haiku", DisplayName: "Haiku", Description: "Fastest"},
	})
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Models map[string][]struct {
			ID          string   `json:"id"`
			DisplayName string   `json:"display_name"`
			IsDefault   bool     `json:"is_default"`
			Efforts     []string `json:"efforts"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	claude := body.Models["claude"]
	if len(claude) != 2 || !claude[0].IsDefault || claude[0].DisplayName != "Default (recommended)" {
		t.Fatalf("unexpected claude catalog: %+v", claude)
	}
	if len(claude[0].Efforts) != 5 || claude[0].Efforts[3] != "xhigh" {
		t.Fatalf("unexpected efforts: %v", claude[0].Efforts)
	}
	if len(claude[1].Efforts) != 0 {
		t.Fatalf("haiku should carry no efforts, got %v", claude[1].Efforts)
	}
}

// TestCapabilitiesIncludesAgentDescriptors verifies the WS-2.3 per-assistant
// `agents` descriptor map: each structured-backend assistant carries a
// display_name, login_provider, the protocol's supports{} flags (folded with
// the manifest plan-mode rule), and reuses the discovered model catalog. The
// top-level `models` map stays present alongside it for one release.
func TestCapabilitiesIncludesAgentDescriptors(t *testing.T) {
	a := auth.NewStore()
	tok := a.Mint()

	// Build a registry with real protocols set (the production TOMLs do this).
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
command = ["cat"]
workdir = "."
chat_mode = "stream-json"
`)
	writeAdapter(t, dir, "codex.toml", `
name = "codex"
command = ["cat"]
workdir = "."
chat_mode = "codex-exec"
`)
	reg, err := agents.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	m := session.NewManager(reg)
	m.SetModelCatalog("claude", []session.ModelInfo{{ID: "haiku", DisplayName: "Haiku"}})
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Models map[string]json.RawMessage         `json:"models"`
		Agents map[string]session.AgentDescriptor `json:"agents"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	// claude: stream-json backend supports everything incl. plan_mode (claude
	// manifest backfills a plan permission mode); descriptor reuses the catalog.
	claude, ok := body.Agents["claude"]
	if !ok {
		t.Fatalf("agents missing claude: %+v", body.Agents)
	}
	if claude.DisplayName != "Claude" {
		t.Errorf("claude display_name = %q, want Claude", claude.DisplayName)
	}
	if claude.LoginProvider != "anthropic" {
		t.Errorf("claude login_provider = %q, want anthropic", claude.LoginProvider)
	}
	if !claude.Supports.Compact || !claude.Supports.AskUserQuestion || !claude.Supports.Effort ||
		!claude.Supports.PlanMode || !claude.Supports.Usage {
		t.Errorf("claude supports = %+v, want all true", claude.Supports)
	}
	if len(claude.Models) != 1 || claude.Models[0].ID != "haiku" {
		t.Errorf("claude models = %+v, want [haiku]", claude.Models)
	}

	// codex-exec: no /compact, no ask_user_question (the exec fallback path).
	codex, ok := body.Agents["codex"]
	if !ok {
		t.Fatalf("agents missing codex: %+v", body.Agents)
	}
	if codex.LoginProvider != "openai" {
		t.Errorf("codex login_provider = %q, want openai", codex.LoginProvider)
	}
	if codex.Supports.Compact {
		t.Errorf("codex-exec must not support compact")
	}
	if codex.Supports.AskUserQuestion {
		t.Errorf("codex-exec must not support ask_user_question")
	}
	if !codex.Supports.Effort || !codex.Supports.Usage {
		t.Errorf("codex supports = %+v, want effort+usage true", codex.Supports)
	}

	// The legacy top-level models map is still served alongside the descriptors.
	if _, present := body.Models["claude"]; !present {
		t.Errorf("top-level models[claude] must stay present for one release")
	}
}

func TestSessionStartEndpoint(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"assistant":"claude"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST session start: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var out struct {
		SessionID string `json:"session_id"`
		WSPath    string `json:"ws_path"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.SessionID == "" || !strings.HasPrefix(out.WSPath, "/ws/") {
		t.Fatalf("unexpected payload: %+v", out)
	}
}

func TestSessionStartWithOverride(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"assistant":"claude","reasoning_effort":"high","model":"opus"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST session start: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var out struct {
		SessionID       string `json:"session_id"`
		ReasoningEffort string `json:"reasoning_effort"`
		Model           string `json:"model"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.SessionID == "" {
		t.Fatal("no session id")
	}
	if out.ReasoningEffort != "high" {
		t.Fatalf("reasoning_effort echoed = %q, want high", out.ReasoningEffort)
	}
	if out.Model != "opus" {
		t.Fatalf("model echoed = %q, want opus", out.Model)
	}
}

func TestSessionDeleteEndpoint(t *testing.T) {
	srv, tok := newTestServer(t)

	// Create a session so there's something to delete.
	startBody := `{"assistant":"claude"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(startBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST session start: %v", err)
	}
	var start struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatalf("decode start: %v", err)
	}
	_ = resp.Body.Close()
	if start.SessionID == "" {
		t.Fatal("no session id returned")
	}

	// DELETE the session.
	delReq, _ := http.NewRequest(http.MethodDelete, srv.URL+"/api/session/"+start.SessionID+"?token="+url.QueryEscape(tok), nil)
	delResp, err := http.DefaultClient.Do(delReq)
	if err != nil {
		t.Fatalf("DELETE session: %v", err)
	}
	defer delResp.Body.Close()
	if delResp.StatusCode != http.StatusOK {
		t.Fatalf("delete status=%d", delResp.StatusCode)
	}
	var delOut struct {
		SessionID string `json:"session_id"`
		Deleted   bool   `json:"deleted"`
	}
	if err := json.NewDecoder(delResp.Body).Decode(&delOut); err != nil {
		t.Fatalf("decode delete: %v", err)
	}
	if !delOut.Deleted || delOut.SessionID != start.SessionID {
		t.Fatalf("unexpected delete payload: %+v", delOut)
	}

	// Idempotent: deleting again still returns 200.
	delReq2, _ := http.NewRequest(http.MethodDelete, srv.URL+"/api/session/"+start.SessionID+"?token="+url.QueryEscape(tok), nil)
	delResp2, err := http.DefaultClient.Do(delReq2)
	if err != nil {
		t.Fatalf("second DELETE session: %v", err)
	}
	defer delResp2.Body.Close()
	if delResp2.StatusCode != http.StatusOK {
		t.Fatalf("second delete status=%d", delResp2.StatusCode)
	}

	// Wrong method on the same path is rejected.
	getReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/session/"+start.SessionID+"?token="+url.QueryEscape(tok), nil)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET session: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 for GET on delete path, got %d", getResp.StatusCode)
	}
}

func TestFSListMetadataAndPagination(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"beta", "alpha", ".hidden"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}

	srv, tok := newTestServer(t)
	rawURL := srv.URL + "/api/fs/list?token=" + url.QueryEscape(tok) +
		"&path=" + url.QueryEscape(root) + "&limit=1&offset=0"
	resp, err := http.Get(rawURL)
	if err != nil {
		t.Fatalf("GET fs list: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var out struct {
		Count   int  `json:"count"`
		Total   int  `json:"total"`
		HasMore bool `json:"has_more"`
		Entries []struct {
			Name    string `json:"name"`
			Hidden  bool   `json:"hidden"`
			ModTime string `json:"mod_time"`
		} `json:"entries"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Count != 1 || out.Total != 2 || !out.HasMore {
		t.Fatalf("unexpected pagination %+v", out)
	}
	if len(out.Entries) != 1 || out.Entries[0].Hidden || out.Entries[0].ModTime == "" {
		t.Fatalf("unexpected entry %+v", out.Entries)
	}
}

func TestFSHarnessStatus(t *testing.T) {
	srv, tok := newTestServer(t)
	get := func(dir string) fsHarnessStatusResponse {
		t.Helper()
		rawURL := srv.URL + "/api/fs/harness-status?token=" + url.QueryEscape(tok) +
			"&path=" + url.QueryEscape(dir)
		resp, err := http.Get(rawURL)
		if err != nil {
			t.Fatalf("GET harness-status: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status=%d", resp.StatusCode)
		}
		var out fsHarnessStatusResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return out
	}

	t.Run("bare dir has no harness", func(t *testing.T) {
		out := get(t.TempDir())
		if out.HasClaudeMD || out.HasAgentsMD || out.HasHarness {
			t.Fatalf("bare dir should have no harness: %+v", out)
		}
	})

	t.Run("CLAUDE.md present", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "CLAUDE.md"), []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
		out := get(dir)
		if !out.HasClaudeMD || out.HasAgentsMD || !out.HasHarness {
			t.Fatalf("CLAUDE.md should set has_harness: %+v", out)
		}
	})

	t.Run("AGENTS.md present", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "AGENTS.md"), []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
		out := get(dir)
		if out.HasClaudeMD || !out.HasAgentsMD || !out.HasHarness {
			t.Fatalf("AGENTS.md should set has_harness: %+v", out)
		}
	})

	t.Run("missing path 400s", func(t *testing.T) {
		rawURL := srv.URL + "/api/fs/harness-status?token=" + url.QueryEscape(tok) +
			"&path=" + url.QueryEscape(filepath.Join(t.TempDir(), "nope"))
		resp, err := http.Get(rawURL)
		if err != nil {
			t.Fatalf("GET: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("expected 400 for missing path, got %d", resp.StatusCode)
		}
	})
}

func TestRecentProjectsEndpoint(t *testing.T) {
	root := t.TempDir()
	projectDir := filepath.Join(root, "proj")
	if err := os.Mkdir(projectDir, 0o755); err != nil {
		t.Fatalf("mkdir project dir: %v", err)
	}
	srv, tok := newTestServer(t)
	startBody := `{"assistant":"claude","cwd":"` + strings.ReplaceAll(projectDir, `\`, `\\`) + `"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(startBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("session start: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("session start status=%d", resp.StatusCode)
	}

	rpResp, err := http.Get(srv.URL + "/api/recent-projects?token=" + url.QueryEscape(tok) + "&limit=5")
	if err != nil {
		t.Fatalf("recent projects: %v", err)
	}
	defer rpResp.Body.Close()
	if rpResp.StatusCode != http.StatusOK {
		t.Fatalf("recent status=%d", rpResp.StatusCode)
	}
	var out struct {
		Projects []struct {
			Path string `json:"path"`
		} `json:"projects"`
	}
	if err := json.NewDecoder(rpResp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Projects) == 0 || out.Projects[0].Path != projectDir {
		t.Fatalf("unexpected recent projects: %+v", out.Projects)
	}
}

// TestSessionsEndpointListsLiveOnly verifies GET /api/sessions reports the
// broker's in-memory live set — the authoritative "what's running now" list
// a reconnecting client reconciles against. A freshly-started session shows
// up (running, with its assistant); a bogus id never does. Crucially the
// endpoint must NOT resurrect anything from disk just by listing.
func TestSessionsEndpointListsLiveOnly(t *testing.T) {
	srv, tok := newTestServer(t)

	// Start a session so there's a live one to report.
	startBody := `{"assistant":"claude"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(startBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("session start: %v", err)
	}
	var start struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatalf("decode start: %v", err)
	}
	_ = resp.Body.Close()
	if start.SessionID == "" {
		t.Fatal("no session id")
	}

	lsResp, err := http.Get(srv.URL + "/api/sessions?token=" + url.QueryEscape(tok))
	if err != nil {
		t.Fatalf("GET sessions: %v", err)
	}
	defer lsResp.Body.Close()
	if lsResp.StatusCode != http.StatusOK {
		t.Fatalf("sessions status=%d", lsResp.StatusCode)
	}
	var out struct {
		Sessions []struct {
			ID        string `json:"id"`
			Assistant string `json:"assistant"`
			Running   bool   `json:"running"`
		} `json:"sessions"`
	}
	if err := json.NewDecoder(lsResp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	var found bool
	for _, s := range out.Sessions {
		if s.ID == start.SessionID {
			found = true
			if s.Assistant != "claude" {
				t.Fatalf("listed assistant=%q, want claude", s.Assistant)
			}
			if !s.Running {
				t.Fatalf("freshly-started session reported running=false")
			}
		}
		if s.ID == "no-such-session" {
			t.Fatal("endpoint reported a session that was never created")
		}
	}
	if !found {
		t.Fatalf("live session %s missing from /api/sessions: %+v", start.SessionID, out.Sessions)
	}
}

// TestSessionsEndpointRequiresAuth ensures the live-session list is not
// served without a valid token (it leaks session ids / cwds).
func TestSessionsEndpointRequiresAuth(t *testing.T) {
	srv, _ := newTestServer(t)
	resp, err := http.Get(srv.URL + "/api/sessions")
	if err != nil {
		t.Fatalf("GET sessions: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatalf("unauthenticated /api/sessions returned 200")
	}
}
