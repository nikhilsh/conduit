//go:build linux

package session

import (
	"net"
	"os"
	"os/exec"
	"slices"
	"testing"
)

// ownedBySelf builds a Session whose "agent process" is the test process, so a
// listener opened by the test is found in the session's own tree by detection.
func ownedBySelf(id string, port int) *Session {
	return &Session{ID: id, previewPort: port, cmd: &exec.Cmd{Process: &os.Process{Pid: os.Getpid()}}}
}

// Auto-detect surfaces a port the session's own tree is listening on. Here the
// listener IS the pooled $PORT, so detection picks it (exact match) and the
// preview is advertised.
func TestPreviewPayload_DetectsOwnedPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	pv := ownedBySelf("sid", port).previewPayload()
	if pv["url"] != "/preview/sid/" {
		t.Fatalf("owned live port should advertise url, got %v", pv["url"])
	}
	if pv["port"] != port {
		t.Fatalf("detected port should be reported, got %v", pv["port"])
	}
}

// The phantom-tab fix: a live listener the session does NOT own must not be
// advertised. We open a listener in the test process, but root the session at
// an unrelated child (`sleep`, which holds nothing) — the listener is outside
// that subtree, so detection finds nothing and the preview is withdrawn (the
// pooled port is still reported with an empty url).
func TestPreviewPayload_RejectsUnownedListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	stranger := exec.Command("sleep", "30")
	if err := stranger.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stranger.Process.Kill(); _, _ = stranger.Process.Wait() }()

	s := &Session{ID: "sid", previewPort: 3000, cmd: stranger}
	pv := s.previewPayload()
	if pv["url"] != "" {
		t.Fatalf("listener outside the session tree must be withdrawn, got url %v", pv["url"])
	}
	if pv["port"] != 3000 {
		t.Fatalf("pooled port should still be reported, got %v", pv["port"])
	}
}

// listeningPortsForTree finds a port the current process is listening on, and
// returns nothing for an unrelated subtree (the sleep child holds no sockets).
func TestListeningPortsForTree(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	if got := listeningPortsForTree(os.Getpid()); !slices.Contains(got, port) {
		t.Errorf("expected own tree to include listener %d, got %v", port, got)
	}

	stranger := exec.Command("sleep", "30")
	if err := stranger.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stranger.Process.Kill(); _, _ = stranger.Process.Wait() }()
	if got := listeningPortsForTree(stranger.Process.Pid); slices.Contains(got, port) {
		t.Errorf("unrelated subtree must not include listener %d, got %v", port, got)
	}
	if got := listeningPortsForTree(0); got != nil {
		t.Errorf("rootPID 0 must yield no ports, got %v", got)
	}
}
