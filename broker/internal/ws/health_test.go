package ws

import (
	"encoding/json"
	"net/http"
	"testing"
)

// /health is the soft probe — 200 + "ok" body, always.
func TestHealthEndpointReturnsOK(t *testing.T) {
	srv, _ := newTestServer(t)
	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
}

// /healthz is the strict probe — returns JSON with per-component
// detail. Forces no-sidecar mode via SWE_KITTY_DISABLE_SIDECAR so the
// test is independent of whether node + @xterm/headless are installed
// in the local dev / CI environment. In that mode the broker is
// live, the sidecar is not expected, and the response is 200 + a
// JSON body with all three fields.
func TestHealthzReportsSidecarAbsent(t *testing.T) {
	t.Setenv("SWE_KITTY_DISABLE_SIDECAR", "1")
	srv, _ := newTestServer(t)
	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type=%q, want application/json", ct)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["live"] != true {
		t.Errorf("live = %v, want true", body["live"])
	}
	if body["sidecar_expected"] != false {
		t.Errorf("sidecar_expected = %v, want false (DISABLE_SIDECAR=1)", body["sidecar_expected"])
	}
	if body["sidecar_healthy"] != false {
		t.Errorf("sidecar_healthy = %v, want false (no sidecar)", body["sidecar_healthy"])
	}
}
