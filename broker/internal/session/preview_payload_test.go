package session

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// No pooled port, no declaration, no detected server → no preview at all.
func TestPreviewPayload_NoAllocation(t *testing.T) {
	if pv := (&Session{ID: "s"}).previewPayload(); pv != nil {
		t.Fatalf("no port should yield nil preview, got %v", pv)
	}
}

// A `.conduit/preview.json` declaring an absolute URL is advertised verbatim
// (the app loads it directly, bypassing the proxy) — no port probe at all, and
// the proxy target resolves to 0 (unused).
func TestPreviewPayload_DeclaredURL(t *testing.T) {
	s := &Session{ID: "sid", previewPort: 3000, workspaceDir: t.TempDir()}
	writePreviewConfig(t, s.workspaceDir, `{"url":"https://tunnel.example.dev"}`)

	pv := s.previewPayload()
	if pv["url"] != "https://tunnel.example.dev" {
		t.Fatalf("declared url should be advertised verbatim, got %v", pv["url"])
	}
	if got := s.EffectivePreviewPort(); got != 0 {
		t.Fatalf("absolute-url preview should not proxy a port, got %d", got)
	}
}

// A declared port overrides the pool $PORT for both the probe and the proxy,
// and is trusted on liveness alone (no process-tree ownership requirement) —
// the escape hatch for servers the broker didn't hand the port to (or that
// detach from its process tree).
func TestPreviewPayload_DeclaredPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	dir := t.TempDir()
	writePreviewConfig(t, dir, `{"port":`+strconv.Itoa(port)+`}`)
	// previewPort (pool) deliberately different; the declared port wins.
	s := &Session{ID: "sid", previewPort: 3000, workspaceDir: dir}

	pv := s.previewPayload()
	if pv["port"] != port {
		t.Fatalf("declared port should be reported, got %v", pv["port"])
	}
	if pv["url"] != "/preview/sid/" {
		t.Fatalf("declared live port should advertise url, got %v", pv["url"])
	}
	if got := s.EffectivePreviewPort(); got != port {
		t.Fatalf("proxy should target declared port %d, got %d", port, got)
	}
}

// A declared port whose server isn't up yet is still probed → url withheld
// (port reported so the wire shape stays {port,url}).
func TestPreviewPayload_DeclaredPortDead(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadPort := ln.Addr().(*net.TCPAddr).Port
	ln.Close()

	dir := t.TempDir()
	writePreviewConfig(t, dir, `{"port":`+strconv.Itoa(deadPort)+`}`)
	s := &Session{ID: "sid", previewPort: 3000, workspaceDir: dir}

	pv := s.previewPayload()
	if pv["url"] != "" {
		t.Fatalf("dead declared port should withhold url, got %v", pv["url"])
	}
	if pv["port"] != deadPort {
		t.Fatalf("declared port should still be reported, got %v", pv["port"])
	}
}

// choosePreviewPort policy: prefer the pooled $PORT, else the lowest non-chat
// port; skip the $AGENT_CHAT_PORT bridge; 0 when there's nothing to surface.
func TestChoosePreviewPort(t *testing.T) {
	cases := []struct {
		name       string
		ports      []int
		pref, chat int
		want       int
	}{
		{"exact pool match wins", []int{5000, 3007, 4007}, 3007, 4007, 3007},
		{"skip chat, take other", []int{4007, 5000}, 3007, 4007, 5000},
		{"lowest non-chat", []int{8080, 5173}, 3007, 4007, 5173},
		{"only chat → none", []int{4007}, 3007, 4007, 0},
		{"empty → none", nil, 3007, 4007, 0},
		{"no pool preference", []int{5173}, 0, 1000, 5173},
	}
	for _, c := range cases {
		if got := choosePreviewPort(c.ports, c.pref, c.chat); got != c.want {
			t.Errorf("%s: choosePreviewPort(%v,%d,%d) = %d, want %d", c.name, c.ports, c.pref, c.chat, got, c.want)
		}
	}
}

func writePreviewConfig(t *testing.T, dir, body string) {
	t.Helper()
	cdir := filepath.Join(dir, ".conduit")
	if err := os.MkdirAll(cdir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cdir, "preview.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
