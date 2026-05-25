package ws

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	if body["name"] != "swe-kitty-broker" {
		t.Fatalf("unexpected name: %v", body["name"])
	}
	assistants, _ := body["assistants"].([]any)
	if len(assistants) < 1 {
		t.Fatalf("expected assistants, got %v", body["assistants"])
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
