package session

import (
	"net"
	"testing"
)

// A stale preview must be withdrawn: the broker only advertises a non-empty
// url while something is actually listening on the dev-server port, so the
// Browser tab disappears when the dev server dies (no live site → no tab).
func TestPreviewPayload(t *testing.T) {
	if pv := previewPayload(0, "s"); pv != nil {
		t.Fatalf("no port should yield nil preview, got %v", pv)
	}

	// Live: a real listener on the port → non-empty url.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	livePort := ln.Addr().(*net.TCPAddr).Port
	pv := previewPayload(livePort, "sid")
	if pv["url"] != "/preview/sid/" {
		t.Fatalf("live port should advertise url, got %v", pv["url"])
	}

	// Dead: bind then close to get a port nothing listens on → empty url.
	ln2, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadPort := ln2.Addr().(*net.TCPAddr).Port
	ln2.Close()
	pv = previewPayload(deadPort, "sid")
	if pv["url"] != "" {
		t.Fatalf("dead port should withdraw url, got %v", pv["url"])
	}
	if pv["port"] != deadPort {
		t.Fatalf("port should still be reported, got %v", pv["port"])
	}
}
